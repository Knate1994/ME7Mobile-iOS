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
    private struct TP20Channel {
        let testerCanId: Int
        let ecuCanId: Int
        let blockSize: Int
        var txSequence: Int
        var rxSequence: Int
    }
    private var tp16Channel: TP16Channel?
    private var tp20Channel: TP20Channel?
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
        tp20Channel = nil
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
        if tp20Channel != nil, let payload = hexBytes(hex) {
            return try requestTP20(payload, timeout: timeout)
        }
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

    /// Block-scan-only variant that keeps each ELM response line separate. Some ECUs
    /// first return KWP NRC 0x78 (response pending), then the actual positive answer;
    /// combining those lines makes the pending response hide the positive one.
    func requestFramesForBlockScan(_ hex: String, timeout: Double = 3) throws -> [Response] {
        if tp20Channel != nil || tp16Channel != nil {
            return [try request(hex, timeout: timeout)]
        }
        let text = try cmd(hex, timeout: timeout)
        var frames: [Response] = []
        for line in text.split(separator: "\n").map(String.init) {
            let upper = line.uppercased()
            if upper.hasPrefix("BUS INIT") || upper.hasPrefix("SEARCHING") || upper == "OK" { continue }
            if let bytes = hexBytes(line) {
                frames.append(Response(bytes: bytes, errors: []))
            } else {
                frames.append(Response(bytes: [], errors: [line]))
            }
        }
        return frames
    }

    /// Test Blocks uses this setup to avoid sending ATCRA, which many ELM clones
    /// reject and which is not needed for K-Line KWP requests.
    func prepareBlockScanKwpMode() throws {
        tp16Channel = nil
        tp20Channel = nil
        _ = try cmd("ATPC")
        for command in ["ATCAF1", "ATCFC1", "ATH0", "ATS0", "ATAT1", "ATST64"] {
            _ = try cmd(command)
        }
    }

    /// Opens VW TP 1.6 over the ELM327's user-defined 11-bit, variable-DLC CAN mode.
    /// Target is the vehicle's diagnostic address (for example 0x03 for PSM).
    func connectTP16(target: Int, baudDivisor: Int = 1) throws -> (connected: Bool, reason: String) {
        tp16Channel = nil
        tp20Channel = nil
        guard (0x00...0xFF).contains(target) else { return (false, "адрес TP 1.6 вне диапазона") }

        _ = try cmd("ATPC")
        let options = try cmd("ATPB C0 \(hx(baudDivisor))")
        guard options.uppercased().contains("OK") else {
            let reason = options.isEmpty ? "ELM не подтвердил настройку CAN USER1" : "ELM не поддержал настройку CAN USER1: \(options)"
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

        let baud = baudDivisor == 1 ? 500 : 500 / max(1, baudDivisor)
        let label = "TP1.6 / CAN \(baud) кбит/с"

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
                trace(String(format: "\(label) ChS: CAN 200 → %02X C0 %02X, ответа нет", target, channelId))
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
            trace(String(format: "\(label) канал открыт: tester CAN %03X, ECU CAN %03X", testerDataId, ecuDataId))

            // Use a one-frame block to keep acknowledgements manageable over the ELM TCP bridge.
            // T1/T2/T4 are 1008 ms; T3 is 10.08 ms (the TP 1.6 time encoding).
            let connectFrames = try sendCAN(id: testerDataId, receiveId: ecuDataId,
                                            data: [0xA0, 0x01, 0xD0, 0xD0, 0x50, 0xD0], timeout: 0.30,
                                            protocolLabel: label)
            guard let ack = connectFrames.first(where: { $0.id == ecuDataId && $0.data.count >= 6 && $0.data[0] == 0xA1 }) else {
                lastReason = "канал создан, но ECU не подтвердил соединение TPDU"
                trace("\(label): \(lastReason)")
                continue
            }
            let ecuBlockSize = max(1, Int(ack.data[1] & 0x0F))
            tp16Channel = TP16Channel(testerCanId: testerDataId, ecuCanId: ecuDataId,
                                      blockSize: min(1, ecuBlockSize))
            trace(String(format: "\(label) соединение подтверждено: CAN %03X → %03X, блок %d", testerDataId, ecuDataId, ecuBlockSize))
            return (true, "соединение TP 1.6 установлено")
        }

        _ = try cmd("ATPC")
        restoreKwpMode()
        return (false, lastReason)
    }

    /// Opens the dynamic VW TP 2.0 channel used by some older VAG ECUs for KWP2000.
    /// Logical destination 0x03 is the PSM/ABS-ESP address used by this Cayenne profile.
    func connectTP20(target: Int, baudDivisor: Int = 1) throws -> (connected: Bool, reason: String) {
        tp16Channel = nil
        tp20Channel = nil
        guard (0x00...0xFF).contains(target) else { return (false, "адрес TP 2.0 вне диапазона") }

        _ = try cmd("ATPC")
        let options = try cmd("ATPB C0 \(hx(baudDivisor))")
        guard options.uppercased().contains("OK") else {
            let reason = options.isEmpty ? "ELM не подтвердил настройку CAN USER1" : "ELM не поддержал настройку CAN USER1: \(options)"
            trace("TP2.0: \(reason)")
            restoreKwpMode()
            return (false, reason)
        }
        let protocolReply = try cmd("ATSPB")
        guard protocolReply.uppercased().contains("OK") else {
            let reason = protocolReply.isEmpty ? "ELM не подтвердил протокол B" : "ELM не включил протокол B: \(protocolReply)"
            trace("TP2.0: \(reason)")
            restoreKwpMode()
            return (false, reason)
        }

        let baud = baudDivisor == 1 ? 500 : 500 / max(1, baudDivisor)
        let label = "VW TP2.0 / CAN \(baud) кбит/с"
        for command in ["ATCAF0", "ATCFC0", "ATH1", "ATS1", "ATAT0", "ATST64", "ATCRA"] {
            _ = try cmd(command)
        }

        let setupId = 0x200 + target
        let setup = try sendCAN(id: 0x200, receiveId: setupId,
                                data: [UInt8(target), 0xC0, 0x00, 0x10, 0x00, 0x03, 0x01],
                                timeout: 0.60, protocolLabel: label)
        guard let reply = setup.first(where: { $0.id == setupId && $0.data.count >= 7 }),
              reply.data[1] == 0xD0 else {
            let detail = setup.first(where: { $0.id == setupId })?.data.map { hx(Int($0)) }.joined(separator: " ")
            let reason = detail.map { "нет положительного Channel Setup ответа (\($0))" } ?? "блок не ответил на Channel Setup CAN 200"
            trace("\(label): \(reason)")
            _ = try cmd("ATPC")
            restoreKwpMode()
            return (false, reason)
        }

        guard reply.data[0] == 0x00, reply.data[6] == 0x01,
              (reply.data[3] & 0xF0) == 0, (reply.data[5] & 0xF0) == 0 else {
            let reason = "неожиданные параметры Channel Setup: \(reply.data.map { hx(Int($0)) }.joined(separator: " "))"
            trace("\(label): \(reason)")
            _ = try cmd("ATPC")
            restoreKwpMode()
            return (false, reason)
        }

        let ecuCanId = Int(reply.data[2]) | ((Int(reply.data[3] & 0x0F)) << 8)
        let testerCanId = Int(reply.data[4]) | ((Int(reply.data[5] & 0x0F)) << 8)
        guard (0x100...0x7FF).contains(ecuCanId), (0x100...0x7FF).contains(testerCanId) else {
            let reason = String(format: "ECU вернул некорректные CAN-ID: tester %03X, ECU %03X", testerCanId, ecuCanId)
            trace("\(label): \(reason)")
            _ = try cmd("ATPC")
            restoreKwpMode()
            return (false, reason)
        }
        trace(String(format: "\(label): динамический канал открыт, tester CAN %03X, ECU CAN %03X", testerCanId, ecuCanId))

        let parameterFrames = try sendCAN(id: testerCanId, receiveId: ecuCanId,
                                          data: [0xA0, 0x01, 0x8A, 0xFF, 0x4A, 0xFF],
                                          timeout: 0.60, protocolLabel: label)
        guard let parameters = parameterFrames.first(where: {
            $0.id == ecuCanId && $0.data.count >= 6 && $0.data[0] == 0xA1
        }), parameters.data[1] > 0 else {
            let reason = "канал открыт, но согласование TPDU (A0/A1) не завершилось"
            trace("\(label): \(reason)")
            _ = try? sendCAN(id: testerCanId, receiveId: ecuCanId, data: [0xA8], timeout: 0.20, protocolLabel: label)
            _ = try cmd("ATPC")
            restoreKwpMode()
            return (false, reason)
        }

        let blockSize = min(1, Int(parameters.data[1]))
        tp20Channel = TP20Channel(testerCanId: testerCanId, ecuCanId: ecuCanId,
                                  blockSize: max(1, blockSize), txSequence: 0, rxSequence: 0)
        trace("\(label): параметры согласованы, подтверждение через 1 кадр")
        return (true, "соединение VW TP2.0 установлено")
    }

    func disconnectTP16() {
        if let channel = tp20Channel {
            _ = try? sendCAN(id: channel.testerCanId, receiveId: channel.ecuCanId,
                             data: [0xA8], timeout: 0.20, protocolLabel: "VW TP2.0")
        }
        tp16Channel = nil
        tp20Channel = nil
        _ = try? cmd("ATPC")
        restoreKwpMode()
    }

    func prepareKwpMode() throws {
        tp16Channel = nil
        tp20Channel = nil
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

    private func sendCAN(id: Int, receiveId: Int, data: [UInt8], timeout: Double,
                         protocolLabel: String = "TP1.6") throws -> [CANFrame] {
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
            trace("\(protocolLabel) CAN \(hx(id, 3)) → \(data.map { hx(Int($0)) }.joined(separator: " ")): \(response.isEmpty ? "нет ответа" : response)")
        } else {
            for frame in frames {
                trace("\(protocolLabel) CAN \(hx(id, 3)) → \(data.map { hx(Int($0)) }.joined(separator: " ")); ← \(hx(frame.id, 3)) \(frame.data.map { hx(Int($0)) }.joined(separator: " "))")
            }
        }
        return frames
    }

    private func requestTP20(_ payload: [Int], timeout: Double) throws -> Response {
        guard var channel = tp20Channel else { return Response(bytes: [], errors: ["TP2.0: канал не открыт"]) }
        guard !payload.isEmpty, payload.count <= 2048 else {
            return Response(bytes: [], errors: ["TP2.0: некорректная длина KWP-запроса"])
        }

        let length = payload.count
        var stream: [UInt8] = [UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        stream += payload.map { UInt8(clamping: $0) }
        var pending: [CANFrame] = []
        let label = "VW TP2.0"

        while !stream.isEmpty {
            // The CAN frame has one TP header byte; the first frame also carries
            // the two-byte KWP length, leaving five payload bytes in total.
            let capacity = 7
            let count = min(capacity, stream.count)
            let chunk = Array(stream.prefix(count))
            stream.removeFirst(count)
            let isLast = stream.isEmpty
            let sequence = channel.txSequence
            let opcode: UInt8 = isLast ? 0x10 : 0x00 // block size 1: acknowledge every frame
            var frame: [UInt8] = [opcode | UInt8(sequence)]
            frame += chunk
            let replies = try sendCAN(id: channel.testerCanId, receiveId: channel.ecuCanId,
                                      data: frame, timeout: max(0.40, min(timeout, 1.0)), protocolLabel: label)
            channel.txSequence = (channel.txSequence + 1) & 0x0F
            var sawAck = false
            for reply in replies where reply.id == channel.ecuCanId && !reply.data.isEmpty {
                let replyOpcode = Int(reply.data[0] >> 4)
                if replyOpcode == 0xB {
                    if Int(reply.data[0] & 0x0F) == channel.txSequence { sawAck = true }
                } else {
                    pending.append(reply)
                }
            }
            guard sawAck else {
                tp20Channel = channel
                return Response(bytes: [], errors: ["TP2.0: ECU не подтвердил кадр запроса"])
            }
        }

        var result: [Int] = []
        var expectedLength: Int?
        var frameCount = 0
        var index = 0
        while index < pending.count && frameCount < 512 {
            let frame = pending[index]
            index += 1
            guard frame.id == channel.ecuCanId, !frame.data.isEmpty else { continue }
            let opcode = Int(frame.data[0] >> 4)
            let sequence = Int(frame.data[0] & 0x0F)
            if opcode == 0xB || opcode == 0x9 { continue }
            guard (0...3).contains(opcode), frame.data.count >= 2 else { continue }
            guard sequence == channel.rxSequence else {
                tp20Channel = channel
                return Response(bytes: result, errors: [String(format: "TP2.0: неверный номер кадра ответа, ожидался %X, получен %X", channel.rxSequence, sequence)])
            }
            frameCount += 1
            channel.rxSequence = (sequence + 1) & 0x0F
            if expectedLength == nil {
                guard frame.data.count >= 4 else {
                    tp20Channel = channel
                    return Response(bytes: [], errors: ["TP2.0: в первом кадре ответа нет длины сообщения"])
                }
                expectedLength = (Int(frame.data[1]) << 8) | Int(frame.data[2])
                result += frame.data.dropFirst(3).map(Int.init)
            } else {
                result += frame.data.dropFirst().map(Int.init)
            }

            if opcode == 0x0 || opcode == 0x1 {
                let ack = try sendCAN(id: channel.testerCanId, receiveId: channel.ecuCanId,
                                      data: [0xB0 | UInt8(channel.rxSequence)], timeout: 0.40,
                                      protocolLabel: label)
                pending += ack
            }
            if opcode == 0x1 || opcode == 0x3 {
                let count = min(expectedLength ?? result.count, result.count)
                tp20Channel = channel
                return Response(bytes: Array(result.prefix(count)), errors: [])
            }
        }

        tp20Channel = channel
        return Response(bytes: [], errors: ["TP2.0: нет полного KWP-ответа от ECU"])
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
