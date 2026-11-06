import Foundation

enum DtcModule: String, CaseIterable, Identifiable, Hashable {
    case engine
    case transmission
    case absEsp
    case suspension
    case kessy
    case seatPassenger
    case climate
    case onboardSupply
    case cruiseControl
    case distanceControl
    case airbag
    case steeringColumn
    case cluster
    case auxHeater
    case gateway
    case transferCase
    case awdControl
    case leftHeadlight
    case diffLock
    case seatDriver
    case navigation
    case rightHeadlight
    case laneAssist
    case comfort
    case amplifier
    case headlightRange
    case radio
    case tvTuner
    case steeringAngle
    case tirePressure
    case wipers
    case towBar
    case rearCamera
    case tailgate
    case seatPassengerAlt
    case telematics
    case parkAssist
    case phone
    case mostGateway

    var id: String { rawValue }

    private struct Info {
        let title: String
        let symbol: String
        let address: Int
        var subtitle: String? = nil
        var fastInit: [Int]? = nil
        var hint: String? = nil
    }

    private var info: Info {
        switch self {
        case .engine:
            return Info(title: "Двигатель", symbol: "fuelpump.fill", address: 0x01,
                        subtitle: "Bosch ME7.1.1 · адрес 01", fastInit: [0x10, 0x01])
        case .transmission:
            return Info(title: "АКПП", symbol: "gearshape.fill", address: 0x02,
                        subtitle: "Tiptronic · адрес 02",
                        hint: "После K-Line приложение также пробует VW TP 1.6 по CAN 500 кбит/с. Некоторые клоны ELM327 не поддерживают CAN USER1 (AT PB / протокол B).")
        case .absEsp:
            return Info(title: "ABS / ESP (PSM)", symbol: "car.fill", address: 0x03,
                        subtitle: "Стабилизация PSM · адрес 03",
                        hint: "После K-Line проверяются VW TP 1.6 и TP 2.0 по CAN на 500/250 кбит/с. TP 2.0 и CAN 250 кбит/с здесь экспериментальные варианты; клоны ELM327 могут не поддерживать CAN USER1 (AT PB / протокол B).")
        case .suspension:
            return Info(title: "Пневмоподвеска", symbol: "arrow.up.and.down", address: 0x34,
                        subtitle: "Регулировка уровня · адрес 34",
                        hint: "На части Cayenne 955 блок подвески работает по VW TP 1.6; если KWP2000 не отвечает, проверь поддержку этого режима адаптером.")
        case .cluster:
            return Info(title: "Приборная панель", symbol: "speedometer", address: 0x17,
                        subtitle: "KOMBI · адрес 17, физический 61", fastInit: [0x61, 0x17])
        case .transferCase:
            return Info(title: "Раздаточная коробка", symbol: "gear", address: 0x1C,
                        subtitle: "TRANSFERCASE · адрес 1C", fastInit: [0x1C, 0x22])
        case .kessy: return Info(title: "KESSY · доступ и запуск", symbol: "key.fill", address: 0x05)
        case .seatPassenger: return Info(title: "Память пассажирского сиденья", symbol: "person.fill", address: 0x06)
        case .climate: return Info(title: "Климат-контроль", symbol: "fan.fill", address: 0x08)
        case .onboardSupply: return Info(title: "Бортовая электрика", symbol: "bolt.fill", address: 0x09)
        case .cruiseControl: return Info(title: "Круиз-контроль", symbol: "timer", address: 0x11)
        case .distanceControl: return Info(title: "Контроль дистанции", symbol: "dot.radiowaves.left.and.right", address: 0x13)
        case .airbag: return Info(title: "Airbag / SRS", symbol: "shield.fill", address: 0x15)
        case .steeringColumn: return Info(title: "Электроника рулевой колонки", symbol: "steeringwheel", address: 0x16)
        case .auxHeater: return Info(title: "Дополнительный отопитель", symbol: "flame.fill", address: 0x18)
        case .gateway: return Info(title: "CAN-шлюз", symbol: "arrow.triangle.branch", address: 0x19)
        case .awdControl: return Info(title: "Раздаточная коробка / AWD (0x22)", symbol: "arrow.triangle.swap", address: 0x22)
        case .leftHeadlight: return Info(title: "Левая фара", symbol: "headlight.high.beam.fill", address: 0x29)
        case .diffLock: return Info(title: "Блокировка дифференциала", symbol: "lock.rotation", address: 0x32)
        case .seatDriver: return Info(title: "Память водительского сиденья", symbol: "person.fill", address: 0x36)
        case .navigation: return Info(title: "Навигация / PCM", symbol: "map.fill", address: 0x37)
        case .rightHeadlight: return Info(title: "Правая фара", symbol: "headlight.high.beam.fill", address: 0x39)
        case .laneAssist: return Info(title: "Ассистент перестроения", symbol: "road.lanes", address: 0x3C)
        case .comfort: return Info(title: "Комфорт / центральный замок", symbol: "house.fill", address: 0x46)
        case .amplifier: return Info(title: "Усилитель аудиосистемы", symbol: "speaker.wave.3.fill", address: 0x47)
        case .headlightRange: return Info(title: "Корректор фар", symbol: "flashlight.on.fill", address: 0x55)
        case .radio: return Info(title: "Радио", symbol: "antenna.radiowaves.left.and.right", address: 0x56)
        case .tvTuner: return Info(title: "ТВ-тюнер", symbol: "tv.fill", address: 0x57)
        case .steeringAngle: return Info(title: "Датчик угла поворота руля", symbol: "rotate.right.fill", address: 0x64)
        case .tirePressure: return Info(title: "Контроль давления шин", symbol: "exclamationmark.circle", address: 0x65)
        case .wipers: return Info(title: "Стеклоочистители", symbol: "drop.fill", address: 0x68)
        case .towBar: return Info(title: "Фаркоп / прицеп", symbol: "link", address: 0x69)
        case .rearCamera: return Info(title: "Камера заднего вида", symbol: "camera.fill", address: 0x6C)
        case .tailgate: return Info(title: "Электропривод задней двери", symbol: "rectangle.portrait.and.arrow.forward", address: 0x6D)
        case .seatPassengerAlt: return Info(title: "Память пассажирского сиденья (0x6E)", symbol: "person.fill", address: 0x6E)
        case .telematics: return Info(title: "Телематика", symbol: "network", address: 0x75)
        case .parkAssist: return Info(title: "Парктроники ParkAssist", symbol: "parkingsign.circle.fill", address: 0x76)
        case .phone: return Info(title: "Телефон", symbol: "phone.fill", address: 0x77)
        case .mostGateway: return Info(title: "MOST-шлюз · Cayenne", symbol: "point.3.connected.trianglepath.dotted", address: 0x82)
        }
    }

    var title: String { info.title }
    var subtitle: String { info.subtitle ?? "KWP2000 · адрес \(target)" }
    var symbol: String { info.symbol }
    /// VAG/KWP logical diagnostic address.
    var address: Int { info.address }
    /// VAG/KWP target address used in physical ECU requests.
    var target: String { hx(info.address) }
    /// Physical fast-init addresses tried before the 5-baud init on the logical address.
    var fastInitTargets: [Int] { info.fastInit ?? [info.address] }
    var sessions: [String] { ["1089", "1086", "1003", "-"] }
    var protocolHint: String? { info.hint }

    /// The four blocks always shown on the errors screen; the rest appear once discovered.
    var isBase: Bool { self == .engine || self == .transmission || self == .absEsp || self == .suspension }

    /// Module that owns this logical address in the Cayenne 955 scan profile.
    static func module(forAddress address: Int) -> DtcModule? {
        DtcModule.allCases.first { $0.address == address }
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
    /// Physical KWP fast-init targets used by some ECUs for this logical module.
    let fastInitTargets: [Int]
    /// Whether this module is documented/reasonable to probe with VW TP 1.6 on this car.
    let supportsTP16: Bool

    init(address: Int, title: String, fastInitTargets: [Int]? = nil, supportsTP16: Bool = false) {
        self.address = address
        self.title = title
        self.fastInitTargets = fastInitTargets ?? [address]
        self.supportsTP16 = supportsTP16
    }

    var id: Int { address }
    var addressText: String { String(format: "%02X", address) }

    /// Curated from the Touareg 7L scan profile, with the two address aliases confirmed
    /// by the supplied Cayenne traces and the Cayenne MOST gateway added separately.
    static let cayenne955: [BlockScanTarget] = [
        .init(address: 0x01, title: "Двигатель", fastInitTargets: [0x10, 0x01]),
        .init(address: 0x02, title: "АКПП Tiptronic"),
        .init(address: 0x03, title: "ABS / ESP (PSM)", supportsTP16: true),
        .init(address: 0x05, title: "KESSY · доступ и запуск"),
        .init(address: 0x06, title: "Память пассажирского сиденья"),
        .init(address: 0x08, title: "Климат-контроль"),
        .init(address: 0x09, title: "Бортовая электрика"),
        .init(address: 0x11, title: "Круиз-контроль · дополнительный ЭБУ"),
        .init(address: 0x13, title: "Контроль дистанции"),
        .init(address: 0x15, title: "Airbag / SRS"),
        .init(address: 0x16, title: "Электроника рулевой колонки"),
        .init(address: 0x17, title: "Приборная панель", fastInitTargets: [0x61, 0x17]),
        .init(address: 0x18, title: "Дополнительный отопитель"),
        .init(address: 0x19, title: "CAN-шлюз"),
        .init(address: 0x1C, title: "Раздаточная коробка (VTG) · по трассе Cayenne"),
        .init(address: 0x22, title: "Раздаточная коробка / AWD"),
        .init(address: 0x29, title: "Левая фара"),
        .init(address: 0x32, title: "Блокировка дифференциала"),
        .init(address: 0x34, title: "Пневмоподвеска / регулировка уровня", supportsTP16: true),
        .init(address: 0x36, title: "Память водительского сиденья"),
        .init(address: 0x37, title: "Навигация / PCM"),
        .init(address: 0x39, title: "Правая фара"),
        .init(address: 0x3C, title: "Ассистент перестроения"),
        .init(address: 0x46, title: "Комфорт / центральный замок"),
        .init(address: 0x47, title: "Усилитель аудиосистемы"),
        .init(address: 0x55, title: "Корректор фар"),
        .init(address: 0x56, title: "Радио"),
        .init(address: 0x57, title: "ТВ-тюнер"),
        .init(address: 0x64, title: "Датчик угла поворота руля"),
        .init(address: 0x65, title: "Контроль давления шин"),
        .init(address: 0x68, title: "Стеклоочистители"),
        .init(address: 0x69, title: "Фаркоп / прицеп"),
        .init(address: 0x6C, title: "Камера заднего вида"),
        .init(address: 0x6D, title: "Электропривод задней двери"),
        .init(address: 0x6E, title: "Память пассажирского сиденья"),
        .init(address: 0x75, title: "Телематика"),
        .init(address: 0x76, title: "Парктроники ParkAssist"),
        .init(address: 0x77, title: "Телефон"),
        .init(address: 0x82, title: "MOST-шлюз · Cayenne"),
    ]
}

enum BlockScanAttemptState: Equatable {
    case responded
    case unverifiedResponse
    case negativeResponse
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
    var hasUnverifiedResponse: Bool { attempts.contains { $0.state == .unverifiedResponse } }
    var receivedNegativeResponse: Bool { attempts.contains { $0.state == .negativeResponse } }
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
