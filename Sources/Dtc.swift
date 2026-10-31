import Foundation

enum DtcModule: String, CaseIterable, Identifiable, Hashable {
    case engine
    case transmission
    case absEsp
    case suspension

    var id: String { rawValue }
    var title: String {
        switch self {
        case .engine: return "Двигатель"
        case .transmission: return "АКПП"
        case .absEsp: return "ABS / ESP (PSM)"
        case .suspension: return "Пневмоподвеска"
        }
    }
    var subtitle: String {
        switch self {
        case .engine: return "Bosch ME7.1.1 · адрес 01"
        case .transmission: return "Tiptronic · адрес 02"
        case .absEsp: return "Стабилизация PSM · адрес 03"
        case .suspension: return "Регулировка уровня · адрес 34"
        }
    }
    var symbol: String {
        switch self {
        case .engine: return "fuelpump.fill"
        case .transmission: return "gearshape.fill"
        case .absEsp: return "car.fill"
        case .suspension: return "arrow.up.and.down"
        }
    }
    /// VAG/KWP target address used in physical ECU requests.
    var target: String {
        switch self {
        case .engine: return "01"
        case .transmission: return "02"
        case .absEsp: return "03"
        case .suspension: return "34"
        }
    }
    var sessions: [String] { ["1089", "1086", "1003", "-"] }
    var protocolHint: String? {
        self == .suspension
            ? "На части Cayenne 955 блок подвески работает по VW TP 1.6; этот режим пока не поддерживается."
            : nil
    }
}

struct DtcEntry: Identifiable, Hashable {
    let code: String
    let description: String
    let rawWord: String
    let status: Int
    var id: String { "\(rawWord)-\(String(format: "%02X", status))" }
    var statusText: String { String(format: "Статус 0x%02X", status) }
}

struct ModuleDiagnostic {
    var connectionState: LinkState = .idle
    var connectionText = "Не подключено"
    var softwareNumber = "Не прочитан"
    var dtcState: LinkState = .idle
    var dtcText = "Ошибки не прочитаны"
    var codes: [DtcEntry] = []
}

/// KWP DTC words are ECU/manufacturer specific. Only verified mappings are decoded;
/// all other values stay visible in their original hexadecimal form.
enum Dtc {
    static func describe(_ hi: Int, _ lo: Int, _ status: Int) -> String {
        let word = hx(hi) + hx(lo)
        let decoded = decode(word, module: .engine)
        return "\(decoded.code) — \(decoded.description) · статус 0x\(hx(status))"
    }

    static func entries(from bytes: [Int], module: DtcModule) -> [DtcEntry]? {
        guard bytes.count >= 2, bytes[0] == 0x58 else { return nil }
        let count = bytes[1]
        guard bytes.count >= 2 + count * 3 else { return nil }
        return (0..<count).map { index in
            let i = 2 + index * 3
            let word = hx(bytes[i]) + hx(bytes[i + 1])
            let status = bytes[i + 2]
            let decoded = decode(word, module: module)
            return DtcEntry(code: decoded.code, description: decoded.description, rawWord: word, status: status)
        }
    }

    static func identificationText(_ bytes: [Int]) -> String {
        let payload = bytes.filter { $0 != 0x00 && $0 != 0xFF }
        guard !payload.isEmpty else { return "Ответ пустой" }
        let printable = payload.filter { (0x20...0x7E).contains($0) }.count
        if printable * 4 >= payload.count * 3 {
            let text = String(bytes: payload.map { UInt8($0) }, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        return payload.map { hx($0) }.joined(separator: " ")
    }

    private static func decode(_ word: String, module: DtcModule) -> (code: String, description: String) {
        if module == .engine, let known = engineCodes[word] {
            return (known.code, known.description)
        }
        let prefix = module == .engine ? "VAG" : "Код блока"
        return ("\(prefix) \(word)", "Для этого кода пока нет проверенной расшифровки")
    }

    private struct Code {
        let code: String
        let description: String
    }

    private static let engineCodes: [String: Code] = [
        "40E6": Code(code: "P0230", description: "Реле топливного насоса J17: неисправность электрической цепи"),
        "41B9": Code(code: "P0441", description: "Система вентиляции топливного бака: неверная пропускная способность"),
        "4919": Code(code: "P2281", description: "Утечка воздуха между ДМРВ и дроссельной заслонкой"),
    ]
}
