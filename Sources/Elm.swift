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
}
