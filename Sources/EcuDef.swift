import Foundation

/// One RAM variable from a ME7Logger .ecu file ([Measurements] section).
struct Measurement: Identifiable, Hashable {
    let name: String
    let alias: String
    let address: Int
    let size: Int
    let bitmask: Int
    let unit: String
    let signed: Bool
    let inverse: Bool
    let factor: Double
    let offset: Double
    let comment: String

    var id: String { name }

    /// ME7Logger conversion: phys = A*raw - B  (inverse: phys = A/(raw - B)); bit variables give 0/1.
    func convert(_ bytes: [UInt8], _ pos: Int) -> Double {
        var raw: Int64 = 0
        for i in 0..<size { raw |= Int64(bytes[pos + i]) << (8 * i) }    // C167: little endian
        if bitmask != 0 { return (raw & Int64(bitmask)) != 0 ? 1 : 0 }
        if signed {
            let bits = 8 * size
            if raw >= (Int64(1) << (bits - 1)) { raw -= Int64(1) << bits }
        }
        if inverse {
            let d = Double(raw) - offset
            return d == 0 ? 0 : factor / d
        }
        return factor * Double(raw) - offset
    }
}

enum EcuDef {
    /// kai.ecu from the app bundle, parsed once.
    static let all: [Measurement] = load()

    private static func load() -> [Measurement] {
        guard let url = Bundle.main.url(forResource: "kai", withExtension: "ecu"),
              let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return [] }
        let pattern = #"^\s*([A-Za-z_]\w*)\s*,\s*\{([^}]*)\}\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*(\d+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*\{([^}]*)\}\s*,\s*(\d)\s*,\s*(\d)\s*,\s*([-0-9.eE]+)\s*,\s*([-0-9.eE]+)\s*,\s*\{([^}]*)\}"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [Measurement] = []
        text.enumerateLines { line, _ in
            let ns = line as NSString
            guard let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return }
            func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces) }
            out.append(Measurement(
                name: g(1), alias: g(2), address: Int(g(3), radix: 16) ?? 0, size: Int(g(4)) ?? 1,
                bitmask: Int(g(5), radix: 16) ?? 0, unit: g(6), signed: g(7) == "1", inverse: g(8) == "1",
                factor: Double(g(9)) ?? 1, offset: Double(g(10)) ?? 0, comment: g(11)))
        }
        return out
    }

    /// Ready-made variable sets (names that exist in kai.ecu).
    static let presets: [(String, [String])] = [
        ("Наддув", ["nmot", "wped_w", "wdkba", "rl_w", "rlsol_w", "rlmax_w", "plsol", "pvdkds_w", "pu_w",
                    "ldtvm", "ldrlts_w", "B_ldsua", "zwout", "tans", "lamsoni_w", "lamsoni2_w"]),
        ("Детонация", ["nmot", "rl_w", "zwout", "dwkrz_0", "dwkrz_1", "dwkrz_2", "dwkrz_3",
                       "dwkrz_4", "dwkrz_5", "dwkrz_6", "dwkrz_7", "wkrm", "tans"]),
        ("Лямбда", ["nmot", "rl_w", "lamsbg_w", "lamfa_w", "lambts_w", "lamsoni_w", "lamsoni2_w",
                    "fr_w", "fr2_w", "ti_b1", "ti_b2", "mshfm_w"]),
        ("Базовый", ["nmot", "vfzg", "gangi", "wped_w", "wdkba", "rl_w", "zwout", "tmot", "tans", "ub"]),
    ]
}
