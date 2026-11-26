import Foundation

enum SweepRate: Int, CaseIterable {
    case standard = 10400, low = 9600, legacy = 4800, high = 12500, highest = 15625

    var command: String {
        switch self {
        case .standard: return "ATIB10"
        case .low: return "ATIB96"
        case .legacy: return "ATIB48"
        case .high: return "ATIB12"
        case .highest: return "ATIB15"
        }
    }
}

struct SweepRoute: Hashable {
    enum Mode: Hashable {
        case fast(SweepRate), slow(SweepRate, initByte: Int), tp20, tp16
    }
    let address: Int
    let mode: Mode
    static let addresses = 0...Int(UInt8.max)
    static let kLineTester = 0xF1
    static let tpTester = 0x00

    var rate: SweepRate? {
        switch mode {
        case .fast(let rate), .slow(let rate, _): return rate
        case .tp20, .tp16: return nil
        }
    }
    var header: String { "81\(hx(address))\(hx(Self.kLineTester))" }
    var label: String {
        switch mode {
        case .fast(let rate): return "K-line fast · 0x\(hx(address)) · \(rate.rawValue) бод"
        case .slow(let rate, let initByte): return "K-line 5 бод · init 0x\(hx(initByte)) → 0x\(hx(address)) · \(rate.rawValue) бод"
        case .tp20: return "CAN TP2.0 · 0x\(hx(address))"
        case .tp16: return "CAN TP1.6 · 0x\(hx(address))"
        }
    }

    // ELM sends ATIIA verbatim, including the high bit. The KWP target header is independent.
    static func slowRoutes(logical: Int, physical: [Int], rate: SweepRate) -> [SweepRoute] {
        guard addresses.contains(logical) else { return [] }
        let low = logical & 0x7F
        let odd = low.nonzeroBitCount.isMultiple(of: 2) ? low | 0x80 : low
        var initBytes = [logical]
        for byte in [odd, low] where !initBytes.contains(byte) { initBytes.append(byte) }
        return physical.flatMap { target in
            initBytes.map { SweepRoute(address: target, mode: .slow(rate, initByte: $0)) }
        }
    }

    static let plan: [SweepRoute] = {
        var routes: [SweepRoute] = []
        var seen: Set<SweepRoute> = []
        func add(_ route: SweepRoute) {
            // These are the actual source addresses of our diagnostic tester.
            if route.address == (route.rate == nil ? tpTester : kLineTester) { return }
            if seen.insert(route).inserted { routes.append(route) }
        }
        let priority: [DtcModule] = [.kessy, .onboardSupply, .comfort]
        for module in priority {
            for target in module.fastInitTargets {
                add(SweepRoute(address: target, mode: .fast(.standard)))
            }
            slowRoutes(logical: module.address, physical: module.fastInitTargets, rate: .standard).forEach(add)
            add(SweepRoute(address: module.address, mode: .tp20))
            add(SweepRoute(address: module.address, mode: .tp16))
        }
        for rate in SweepRate.allCases {
            for address in addresses {
                add(SweepRoute(address: address, mode: .fast(rate)))
            }
            if rate == .standard {
                for address in addresses {
                    add(SweepRoute(address: address, mode: .tp20))
                    add(SweepRoute(address: address, mode: .tp16))
                }
            }
            for module in DtcModule.allCases {
                slowRoutes(logical: module.address, physical: module.fastInitTargets, rate: rate).forEach(add)
            }
            for address in addresses {
                slowRoutes(logical: address, physical: [address], rate: rate).forEach(add)
            }
        }
        return routes
    }()
}

struct SweepReply {
    var payload: [Int]?
    var identifier: String?
    var evidence: String?
    var unsupportedRate: SweepRate?
    var unsupportedCAN = false
    var setupIssue: String?
    var attempted = false
    var module: DtcModule? { payload.flatMap(Dtc.identifyModule) }

    // ATH1 includes the checksum. Check both addresses, the encoded length and checksum
    // before attributing K-line data to this route. Ignore request echoes and unrelated ECUs.
    static func kwpData(_ bytes: [Int], from address: Int) -> [Int]? {
        guard bytes.count >= 5, bytes[0] & 0xC0 == 0x80,
              bytes[1] == SweepRoute.kLineTester, bytes[2] == address else { return nil }
        let shortLength = bytes[0] & 0x3F
        let start = shortLength == 0 ? 4 : 3
        let length = shortLength == 0 ? bytes[3] : shortLength
        guard length > 0, bytes.count == start + length + 1,
              bytes.dropLast().reduce(0, +) & 0xFF == bytes.last else { return nil }
        return Array(bytes[start..<(start + length)])
    }

    mutating func inspect(_ frames: [Response], option: Int) {
        let prefix = [0x5A, option]
        for (index, frame) in frames.enumerated() where frame.errors.isEmpty {
            if frame.bytes.starts(with: [0x7F, 0x1A]), frame.bytes.count >= 3 {
                evidence = "ответ на 1A\(hx(option)) · \(frame)"
            }
            guard frame.bytes.starts(with: prefix), frame.bytes.count > 2 else { continue }
            var data = Array(frame.bytes.dropFirst(2))
            // The 955 can split its component name across two 5A lines before the ELM prompt.
            for tail in frames.dropFirst(index + 1) {
                guard tail.errors.isEmpty, tail.isPositive(0x1A), tail.bytes.count > 1,
                      !(0x80...0x9F).contains(tail.bytes[1]) else { break }
                data += tail.bytes.dropFirst()
            }
            let text = Dtc.identificationText(data)
            let normalized = text.uppercased().filter { $0.isLetter || $0.isNumber }
            guard data.contains(where: { $0 != 0 && $0 != 0xFF }), !normalized.isEmpty,
                  normalized != "HARDWARENO" else {
                evidence = "общий ответ на 1A\(hx(option))"; continue
            }
            if payload == nil || (module == nil && Dtc.identifyModule(data) != nil) {
                payload = data
                identifier = "1A\(hx(option)) · \(text)"
            }
            return
        }
    }
}
