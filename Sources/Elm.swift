import Foundation
import Network

enum ElmError: Error, CustomStringConvertible {
    case closed
    case connect(String)

    var description: String {
        switch self {
        case .closed: return "адаптер закрыл соединение"
        case .connect(let m): return m
        }
    }
}

/// Uppercase hex with leading zeros.
func hx(_ v: Int, _ width: Int = 2) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
}

/// "58 02 22 81" / "58022281" -> [0x58, 0x02, 0x22, 0x81]; nil if the line is not pure hex.
func hexBytes(_ line: String) -> [Int]? {
    let h = line.replacingOccurrences(of: " ", with: "").uppercased()
    guard !h.isEmpty, h.count % 2 == 0, h.range(of: "^[0-9A-F]+$", options: .regularExpression) != nil else { return nil }
    var out: [Int] = []
    var i = h.startIndex
    while i < h.endIndex {
        let j = h.index(i, offsetBy: 2)
        out.append(Int(h[i..<j], radix: 16) ?? 0)
        i = j
    }
    return out
}

struct Response: CustomStringConvertible {
    let bytes: [Int]
    let errors: [String]

    var ok: Bool { !bytes.isEmpty }
    var negative: Bool { bytes.count >= 3 && bytes[0] == 0x7F }
    func isPositive(_ service: Int) -> Bool { !bytes.isEmpty && bytes[0] == service + 0x40 }

    var description: String {
        let hex = bytes.map { hx($0) }.joined(separator: " ")
        return (hex + (errors.isEmpty ? "" : " [\(errors.joined(separator: "; "))]")).trimmingCharacters(in: .whitespaces)
    }
}

/// ELM327 over TCP (Wi-Fi adapters: 192.168.0.10:35000). Blocking calls, meant for one worker queue.
/// Every exchange goes to `trace`.
final class Elm {
    private let trace: (String) -> Void
    private var conn: NWConnection?
    private struct TP16Channel {
        let testerCanId: Int
        let ecuCanId: Int
        let blockSize: Int
    }
    private var tp16Channel: TP16Channel?
    private let nwQueue = DispatchQueue(label: "me7.elm.nw")
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private let dataSignal = DispatchSemaphore(value: 0)

    init(trace: @escaping (String) -> Void) { self.trace = trace }

    func open(host: String, port: Int, timeout: Double) throws {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw ElmError.connect("неверный порт") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .wifi           // adapter Wi-Fi has no internet: never go over cellular
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        let ready = DispatchSemaphore(value: 0)
        var result: String? = "таймаут \(Int(timeout)) с"
        var signalled = false
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !signalled { signalled = true; result = nil; ready.signal() }
            case .waiting(let e), .failed(let e):
                if !signalled { signalled = true; result = "\(e)"; ready.signal() } else { self?.markClosed() }
            case .cancelled:
                self?.markClosed()
            default:
                break
            }
        }
        c.start(queue: nwQueue)
        _ = ready.wait(timeout: .now() + timeout)
        let err: String? = nwQueue.sync { signalled = true; return result }
        if let err = err { c.cancel(); throw ElmError.connect(err) }
        conn = c
        receive(c)
    }

    private func markClosed() {
        lock.lock(); closed = true; lock.unlock()
        dataSignal.signal()
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lock.lock(); self.buffer.append(data); self.lock.unlock()
                self.dataSignal.signal()
            }
            if isComplete || error != nil { self.markClosed(); return }
            self.receive(c)
        }
    }

    func close() {
        tp16Channel = nil
        conn?.cancel()
        conn = nil
        markClosed()
    }

    /// Sends a command, returns everything up to the '>' prompt (without it).
    func cmd(_ c: String, timeout: Double = 2) throws -> String {
        guard let conn = conn else { throw ElmError.closed }
        lock.lock(); buffer.removeAll(); let wasClosed = closed; lock.unlock()   // drop stale bytes
        if wasClosed { throw ElmError.closed }
        conn.send(content: Data((c + "\r").utf8), completion: .contentProcessed { _ in })
        let start = Date()
        var raw = Data()
        while true {
            lock.lock()
            if let i = buffer.firstIndex(of: UInt8(ascii: ">")) {
                raw = buffer.subdata(in: buffer.startIndex..<i)
                buffer.removeAll()
                lock.unlock()
                break
            }
            let isClosed = closed
            lock.unlock()
            if isClosed { throw ElmError.closed }
            let left = timeout - Date().timeIntervalSince(start)
            if left <= 0 {
                lock.lock(); raw = buffer; buffer.removeAll(); lock.unlock()
                break
            }
            _ = dataSignal.wait(timeout: .now() + min(left, 0.1))
        }
        let r = String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        trace("> \(c)\n< \(r.isEmpty ? "(нет ответа)" : r)  [\(ms) мс]")
        return r
    }

    /// Sends a KWP request (hex without spaces), returns the response data bytes (header stripped by ELM, ATH0).
    func request(_ hex: String, timeout: Double = 3) throws -> Response {
        if let channel = tp16Channel, let payload = hexBytes(hex) {
            return try requestTP16(payload, channel: channel, timeout: timeout)
        }
        let text = try cmd(hex, timeout: timeout)
        var bytes: [Int] = []
        var errors: [String] = []
        for line in text.split(separator: "\n").map(String.init) {
            let l = line.uppercased()
            if l.hasPrefix("BUS INIT") { if l.contains("ERROR") { errors.append(line) }; continue }
            if l.hasPrefix("SEARCHING") || l == "OK" { continue }
            if let b = hexBytes(line) { bytes += b } else { errors.append(line) }
        }
        return Response(bytes: bytes, errors: errors)
    }

    /// Opens VW TP 1.6 over the ELM327's user-defined 11-bit, variable-DLC CAN mode.
    /// Target is the vehicle's diagnostic address (for example 0x03 for PSM).
    func connectTP16(target: Int) throws -> (connected: Bool, reason: String) {
        tp16Channel = nil
        guard (0x00...0x1F).contains(target) else { return (false, "адрес TP 1.6 вне диапазона") }

        _ = try cmd("ATPC")
        let options = try cmd("ATPB C0 01")
        guard options.uppercased().contains("OK") else {
            let reason = options.isEmpty ? "ELM не подтвердил AT PB C0 01" : "ELM не поддержал AT PB C0 01: \(options)"
            trace("TP1.6: \(reason)")
            restoreKwpMode()
            return (false, reason)
        }
        let protocolReply = try cmd("ATSPB")
        guard protocolReply.uppercased().contains("OK") else {
            let reason = protocolReply.isEmpty ? "ELM не подтвердил протокол B" : "ELM не включил протокол B: \(protocolReply)"
            trace("TP1.6: \(reason)")
            restoreKwpMode()
            return (false, reason)
        }

        for command in ["ATCAF0", "ATCFC0", "ATH1", "ATS1", "ATAT0", "ATST20", "ATCRA"] {
            _ = try cmd(command)
        }

        let ecuSetupId = 0x200 + target
        var lastReason = "блок не ответил на Channel Setup"
        // Drive ECU tester channels: 0x40, 0x60, 0x80 and 0xA0 + tester address (0).
        for channelId in [0x40, 0x60, 0x80, 0xA0] {
            let frames = try sendCAN(id: 0x200, receiveId: ecuSetupId,
                                     data: [UInt8(target), 0xC0, UInt8(channelId)], timeout: 0.30)
            guard let reply = frames.first(where: { $0.id == ecuSetupId && $0.data.count >= 3 }) else {
                trace(String(format: "TP1.6 ChS: CAN 200 → %02X C0 %02X, ответа нет", target, channelId))
                continue
            }
            guard reply.data[0] == 0x00, reply.data[1] == 0xD0 else {
                lastReason = String(format: "неожиданный Channel Acknowledge: CAN %03X %@", reply.id, reply.data.map { hx(Int($0)) }.joined(separator: " "))
                trace("TP1.6: \(lastReason)")
                continue
            }

            guard (0x40...0xBF).contains(Int(reply.data[2])) else {
                lastReason = String(format: "ECU вернул недопустимый Channel ID 0x%02X", reply.data[2])
                trace("TP1.6: \(lastReason)")
                continue
            }
            let testerDataId = 0x700 + channelId
            let ecuDataId = 0x700 + Int(reply.data[2])
            trace(String(format: "TP1.6 канал открыт: tester CAN %03X, ECU CAN %03X", testerDataId, ecuDataId))

            // Use a one-frame block to keep acknowledgements manageable over the ELM TCP bridge.
            // T1/T2/T4 are 1008 ms; T3 is 10.08 ms (the TP 1.6 time encoding).
            let connectFrames = try sendCAN(id: testerDataId, receiveId: ecuDataId,
                                            data: [0xA0, 0x01, 0xD0, 0xD0, 0x50, 0xD0], timeout: 0.30)
            guard let ack = connectFrames.first(where: { $0.id == ecuDataId && $0.data.count >= 6 && $0.data[0] == 0xA1 }) else {
                lastReason = "канал создан, но ECU не подтвердил соединение TPDU"
                trace("TP1.6: \(lastReason)")
                continue
            }
            let ecuBlockSize = max(1, Int(ack.data[1] & 0x0F))
            tp16Channel = TP16Channel(testerCanId: testerDataId, ecuCanId: ecuDataId,
                                      blockSize: min(1, ecuBlockSize))
            trace(String(format: "TP1.6 соединение подтверждено: CAN %03X → %03X, блок %d", testerDataId, ecuDataId, ecuBlockSize))
            return (true, "соединение TP 1.6 установлено")
        }

        _ = try cmd("ATPC")
        restoreKwpMode()
        return (false, lastReason)
    }

    func disconnectTP16() {
        tp16Channel = nil
        _ = try? cmd("ATPC")
        restoreKwpMode()
    }

    func prepareKwpMode() throws {
        tp16Channel = nil
        _ = try cmd("ATPC")
        for command in ["ATCAF1", "ATCFC1", "ATH0", "ATS0", "ATAT1", "ATST64", "ATCRA"] {
            _ = try cmd(command)
        }
    }

    private func restoreKwpMode() {
        for command in ["ATCAF1", "ATCFC1", "ATH0", "ATS0", "ATAT1", "ATST64", "ATCRA"] {
            _ = try? cmd(command)
        }
    }

    private struct CANFrame {
        let id: Int
        let data: [UInt8]
    }

    private func sendCAN(id: Int, receiveId: Int, data: [UInt8], timeout: Double) throws -> [CANFrame] {
        guard !data.isEmpty, data.count <= 8 else { return [] }
        _ = try cmd("ATCRA \(hx(receiveId, 3))")
        _ = try cmd("ATSH \(hx(id, 3))")
        let response = try cmd(data.map { hx(Int($0)) }.joined(), timeout: timeout)
        var frames: [CANFrame] = []
        for line in response.split(separator: "\n").map(String.init) {
            let compact = line.replacingOccurrences(of: " ", with: "").uppercased()
            guard compact.count >= 5, compact.count % 2 == 1,
                  compact.range(of: "^[0-9A-F]+$", options: .regularExpression) != nil,
                  let id = Int(compact.prefix(3), radix: 16) else { continue }
            let payloadText = String(compact.dropFirst(3))
            guard let bytes = hexBytes(payloadText) else { continue }
            frames.append(CANFrame(id: id, data: bytes.map { UInt8(clamping: $0) }))
        }
        if frames.isEmpty {
            trace("TP1.6 CAN \(hx(id, 3)) → \(data.map { hx(Int($0)) }.joined(separator: " ")): \(response.isEmpty ? "нет ответа" : response)")
        } else {
            for frame in frames {
                trace("TP1.6 CAN \(hx(id, 3)) → \(data.map { hx(Int($0)) }.joined(separator: " ")); ← \(hx(frame.id, 3)) \(frame.data.map { hx(Int($0)) }.joined(separator: " "))")
            }
        }
        return frames
    }

    private func requestTP16(_ payload: [Int], channel: TP16Channel, timeout: Double) throws -> Response {
        guard !payload.isEmpty, payload.count <= 7 else {
            return Response(bytes: [], errors: ["TP1.6: запрос длиннее одного кадра пока не поддержан"])
        }
        let frame = try sendCAN(id: channel.testerCanId, receiveId: channel.ecuCanId,
                                data: [0x30] + payload.map { UInt8(clamping: $0) },
                                timeout: max(0.15, min(timeout, 1.0)))
        var pending = frame
        var result: [Int] = []
        var expectedSequence = 0
        var receivedCount = 0
        var attempts = 0

        while attempts < 32 {
            attempts += 1
            guard let index = pending.firstIndex(where: { $0.id == channel.ecuCanId && !$0.data.isEmpty }) else {
                if result.isEmpty { return Response(bytes: [], errors: ["TP1.6: ECU не ответил на KWP-запрос"]) }
                return Response(bytes: result, errors: [])
            }
            let next = pending.remove(at: index)
            let tpci = next.data[0]
            if (tpci & 0xC0) == 0x80 { continue } // Ack/control frame
            guard (tpci & 0xC0) == 0, next.data.count >= 2 else { continue }

            let sequence = Int(tpci & 0x0F)
            if sequence != expectedSequence {
                trace("TP1.6: неверный номер кадра ECU, ждал \(expectedSequence), получил \(sequence)")
                return Response(bytes: result, errors: ["TP1.6: нарушена последовательность CAN-кадров"])
            }
            expectedSequence = (expectedSequence + 1) & 0x0F
            receivedCount += 1
            result += next.data.dropFirst().map(Int.init)

            let endOfMessage = (tpci & 0x10) != 0
            let ackRequested = (tpci & 0x20) == 0
            let needsAck = ackRequested && (receivedCount >= channel.blockSize || endOfMessage)
            if needsAck {
                let ack = try sendCAN(id: channel.testerCanId, receiveId: channel.ecuCanId,
                                      data: [0xB0 | UInt8(expectedSequence)], timeout: 0.30)
                pending += ack
                receivedCount = 0
            }
            if endOfMessage { return Response(bytes: result, errors: []) }

            if pending.isEmpty && !ackRequested {
                return Response(bytes: result, errors: ["TP1.6: ECU не завершил ответ после кадра без подтверждения"])
            }
        }
        return Response(bytes: result, errors: ["TP1.6: превышен предел кадров ответа"])
    }
}
