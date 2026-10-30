import Foundation

/// VAG KWP2000 returns manufacturer-specific 16-bit DTCs plus one status byte.
enum Dtc {
    static func describe(_ hi: Int, _ lo: Int, _ st: Int) -> String {
        let vag = hx(hi) + hx(lo)
        let raw = String(format: "статус 0x%02X", st)
        if let code = vagCodes[vag] {
            return "\(code.obd) — \(code.description)\n   VAG \(vag) · \(raw)"
        }
        return "VAG DTC \(vag)\n   Нет проверенной привязки к P-коду · \(raw)"
    }

    private struct Code {
        let obd: String
        let description: String
    }

    /// Verified VAG hexadecimal DTC word → standardized P-code mappings seen in the supplied ECU trace.
    private static let vagCodes: [String: Code] = [
        "40E6": Code(obd: "P0230", description: "реле топливного насоса J17: неисправность электрической цепи"),
        "41B9": Code(obd: "P0441", description: "система вентиляции топливного бака: неверная пропускная способность"),
        "4919": Code(obd: "P2281", description: "утечка воздуха между ДМРВ и дроссельной заслонкой"),
    ]
}
