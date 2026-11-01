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
        switch self {
        case .transmission:
            return "После K-Line приложение также пробует VW TP 1.6 по CAN 500 кбит/с. Некоторые клоны ELM327 не поддерживают CAN USER1 (AT PB / протокол B)."
        case .absEsp:
            return "После K-Line проверяются VW TP 1.6 и TP 2.0 по CAN на 500/250 кбит/с. TP 2.0 и CAN 250 кбит/с здесь экспериментальные варианты; клоны ELM327 могут не поддерживать CAN USER1 (AT PB / протокол B)."
        case .suspension:
            return "На части Cayenne 955 блок подвески работает по VW TP 1.6; если KWP2000 не отвечает, проверь поддержку этого режима адаптером."
        case .engine:
            return nil
        }
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

/// Known Porsche 955 systems and common VAG diagnostic addresses to probe.
/// Several addresses are equipment-dependent or aliases used by different generations.
struct BlockScanTarget: Identifiable, Hashable {
    let address: Int
    let title: String
    var id: Int { address }
    var addressText: String { String(format: "%02X", address) }

    static let cayenne955: [BlockScanTarget] = [
        .init(address: 0x01, title: "Двигатель"),
        .init(address: 0x02, title: "АКПП Tiptronic"),
        .init(address: 0x03, title: "ABS / ESP (PSM)"),
        .init(address: 0x05, title: "KESSY / доступ и запуск"),
        .init(address: 0x06, title: "Память пассажирского сиденья"),
        .init(address: 0x07, title: "PCM / передний инфоблок"),
        .init(address: 0x08, title: "Климат-контроль"),
        .init(address: 0x09, title: "Центральная электрика (VES)"),
        .init(address: 0x10, title: "Парковочная система · вариант 2"),
        .init(address: 0x14, title: "Подвеска · вариант адреса"),
        .init(address: 0x15, title: "Airbag / SRS"),
        .init(address: 0x16, title: "Электроника рулевой колонки"),
        .init(address: 0x17, title: "Приборная панель"),
        .init(address: 0x18, title: "Дополнительный отопитель"),
        .init(address: 0x19, title: "CAN-шлюз"),
        .init(address: 0x20, title: "Дальний свет / ассистент света"),
        .init(address: 0x22, title: "Раздаточная коробка / AWD"),
        .init(address: 0x25, title: "Иммобилайзер · вариант KESSY"),
        .init(address: 0x26, title: "Панорамная крыша"),
        .init(address: 0x29, title: "Левая фара"),
        .init(address: 0x31, title: "Диагностический интерфейс / шлюз"),
        .init(address: 0x34, title: "Пневмоподвеска / уровень"),
        .init(address: 0x35, title: "Центральный замок"),
        .init(address: 0x36, title: "Память водительского сиденья"),
        .init(address: 0x37, title: "Навигация / PCM"),
        .init(address: 0x39, title: "Правая фара"),
        .init(address: 0x42, title: "Дверь водителя"),
        .init(address: 0x44, title: "Усилитель руля"),
        .init(address: 0x45, title: "Контроль салона / наклона"),
        .init(address: 0x46, title: "Комфорт / центральный замок"),
        .init(address: 0x47, title: "Усилитель аудиосистемы"),
        .init(address: 0x52, title: "Дверь пассажира"),
        .init(address: 0x53, title: "Стояночный тормоз"),
        .init(address: 0x55, title: "Управление фарами"),
        .init(address: 0x56, title: "Радио / PCM"),
        .init(address: 0x57, title: "ТВ-тюнер"),
        .init(address: 0x61, title: "Электропитание / аккумулятор"),
        .init(address: 0x62, title: "Задняя левая дверь"),
        .init(address: 0x64, title: "Активные стабилизаторы"),
        .init(address: 0x65, title: "Контроль давления шин"),
        .init(address: 0x66, title: "Память заднего сиденья"),
        .init(address: 0x68, title: "Стеклоочистители"),
        .init(address: 0x69, title: "Фаркоп / прицеп"),
        .init(address: 0x6D, title: "Электропривод задней двери"),
        .init(address: 0x72, title: "Задняя правая дверь"),
        .init(address: 0x76, title: "Парктроники ParkAssist"),
        .init(address: 0x77, title: "Телефон"),
        .init(address: 0x82, title: "MOST-шлюз"),
    ]
}

enum BlockScanAttemptState: Equatable {
    case responded
    case channelOnly
    case noResponse
}

struct BlockScanAttempt: Identifiable, Equatable {
    let mode: String
    let state: BlockScanAttemptState
    let detail: String
    var id: String { mode }
}

struct BlockScanResult: Identifiable, Equatable {
    let target: BlockScanTarget
    var attempts: [BlockScanAttempt] = []
    var id: Int { target.address }
    var responded: Bool { attempts.contains { $0.state == .responded } }
    var transportOpened: Bool { attempts.contains { $0.state == .channelOnly } }
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
