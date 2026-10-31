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

    var displayName: String {
        if let familyName = Self.channelName(for: name) { return familyName }
        if let localized = Self.russianNames[name] { return localized }
        if !alias.isEmpty, let localized = Self.russianAliases[alias] { return localized }
        return alias.isEmpty ? name : alias
    }

    /// Human-readable names for the measurements most often used in live logging.
    /// The ME7Logger identifiers stay visible in the picker so every label can be
    /// checked against the ECU definition and the exported CSV.
    private static let russianNames: [String: String] = [
        "abo": "Количество запусков с попаданием бензина в масло",
        "nmot": "Обороты двигателя",
        "nmot_w": "Обороты двигателя · точное значение",
        "gangi": "Включённая передача",
        "wped": "Положение педали газа",
        "wped_w": "Положение педали газа",
        "wdkba": "Фактическое открытие дросселя",
        "wdks": "Заданное открытие дросселя",
        "rl": "Фактическая нагрузка двигателя",
        "rl_w": "Фактическая нагрузка двигателя",
        "rlsol_w": "Заданная нагрузка двигателя",
        "rlmax_w": "Максимально допустимая нагрузка двигателя",
        "rlmx_w": "Расчётный предел нагрузки двигателя",
        "plsol": "Заданный наддув · абсолютное давление",
        "plsol_w": "Заданный наддув · абсолютное давление",
        "pvdkds_w": "Фактическое давление перед дросселем · абсолютное",
        "pvdks_w": "Фактическое давление перед дросселем · без подмены при ошибке датчика",
        "pu": "Атмосферное давление",
        "pu_w": "Атмосферное давление",
        "pus_w": "Атмосферное давление · без подмены при ошибке датчика",
        "ldtvm": "Клапан N75 · итоговая скважность управления турбиной",
        "ldtvr_w": "Клапан N75 · команда регулятора до коррекции",
        "ldtv": "Клапан N75 · команда после линеаризации",
        "ldptv": "Управление наддувом · P-составляющая регулятора",
        "lditv_w": "Управление наддувом · I-составляющая регулятора",
        "ldrdtv": "Управление наддувом · D-составляющая регулятора",
        "ldrlms_w": "Ограничение наддува по защите двигателя",
        "ldrlts_w": "Ограничение наддува по защите турбины",
        "ldob": "Активно ограничение избыточного наддува",
        "B_ldsua": "Клапан байпаса турбины · открыт",
        "B_ldsuad": "Клапан байпаса турбины · динамическое управление активно",
        "B_ldsuas": "Клапан байпаса турбины · установившееся управление активно",
        "B_ldob": "Активно ограничение избыточного наддува",
        "B_lambts": "Активна защита двигателя по лямбде",
        "tateout": "Клапан продувки адсорбера · скважность управления",
        "mshfm_w": "Расход воздуха по ДМРВ (HFM)",
        "msdk_w": "Расход воздуха через дроссель",
        "uhfm_w": "Сигнал напряжения ДМРВ",
        "lamsoni_w": "Фактическая лямбда · ряд 1 · широкополосный зонд до катализатора",
        "lamsoni2_w": "Фактическая лямбда · ряд 2 · широкополосный зонд до катализатора",
        "lamsbg_w": "Заданная лямбда после ограничителей · ряд 1",
        "lamsbg2_w": "Заданная лямбда после ограничителей · ряд 2",
        "lamfa_w": "Запрошенная водителем целевая лямбда",
        "lambts_w": "Целевая лямбда для защиты двигателя и турбины",
        "fr_w": "Краткосрочная коррекция смеси лямбда-регулятором · ряд 1",
        "fr2_w": "Краткосрочная коррекция смеси лямбда-регулятором · ряд 2",
        "frm_w": "Усреднённая коррекция смеси лямбда-регулятором · ряд 1",
        "frm2_w": "Усреднённая коррекция смеси лямбда-регулятором · ряд 2",
        "fra_w": "Долгосрочная топливная коррекция · ряд 1",
        "fra2_w": "Долгосрочная топливная коррекция · ряд 2",
        "wkrm": "Средний откат угла зажигания из-за детонации",
        "wkrma": "Средний откат угла зажигания из-за детонации",
        "zwist": "Текущий угол зажигания",
        "zwout": "Итоговый угол зажигания",
        "tans": "Температура воздуха на впуске",
        "tanslin": "Температура воздуха на впуске · фильтрованное значение",
        "tmot": "Температура охлаждающей жидкости",
        "tmotlin": "Температура охлаждающей жидкости · фильтрованное значение",
        "tmotsoll": "Заданная температура охлаждающей жидкости",
        "ub": "Напряжение бортовой сети",
        "wub": "Напряжение бортовой сети",
        "wubr": "Напряжение питания ЭБУ",
        "vfil_w": "Скорость автомобиля",
        "vfzg": "Скорость автомобиля",
        "vfil": "Скорость автомобиля",
        "nmotll": "Обороты двигателя на холостом ходу",
        "nsol": "Заданные обороты холостого хода",
        "ti_b1": "Время открытия форсунок · ряд 1",
        "ti_b2": "Время открытия форсунок · ряд 2",
        "te_w": "Расчётное эффективное время впрыска · ряд 1",
        "te2_w": "Расчётное эффективное время впрыска · ряд 2",
        "timx_w": "Максимальное время впрыска",
        "tabgbts_w": "Температура выхлопа для защиты двигателя",
        "tabgm": "Расчётная температура выхлопа перед катализатором · ряд 1",
        "tabgm_w": "Расчётная температура выхлопа перед катализатором · ряд 1",
        "tabgm2": "Расчётная температура выхлопа перед катализатором · ряд 2",
        "tkatm": "Расчётная температура катализатора · ряд 1",
        "tkatm2": "Расчётная температура катализатора · ряд 2",
        "tikatm_w": "Расчётная температура внутри катализатора",
        "rmslt": "Расход воздуха через систему вторичного воздуха · ряд 1",
        "rmslt2": "Расход воздуха через систему вторичного воздуха · ряд 2",
        "ushk": "Напряжение лямбда-зонда после катализатора · ряд 1",
        "ushk2": "Напряжение лямбда-зонда после катализатора · ряд 2",
        "uulsuv_w": "Сигнал широкополосной лямбды до катализатора · ряд 1",
        "uulsuv2_w": "Сигнал широкополосной лямбды до катализатора · ряд 2",
        "rinh_w": "Сопротивление лямбда-зонда после катализатора · ряд 1",
        "rinh2_w": "Сопротивление лямбда-зонда после катализатора · ряд 2",
        "wnwi_w": "Угол положения распределительного вала · ряд 1",
        "wnwi2_w": "Угол положения распределительного вала · ряд 2",
        "wnwise_w": "Угол впускного распредвала · ряд 1",
        "wnwis2e_w": "Угол впускного распредвала · ряд 2",
        "upwg1_w": "Сигнал датчика педали газа G79",
        "upwg2_w": "Сигнал датчика педали газа G185",
        "udkp1_w": "Сигнал датчика положения дросселя G187",
        "udkp2_w": "Сигнал датчика положения дросселя G188",
        "udknlp1r": "Сигнал аварийного датчика зазора дросселя G187",
        "udknlp2r": "Сигнал аварийного датчика зазора дросселя G188",
        "fzabgs_w": "Общее количество пропусков воспламенения по всем цилиндрам",
        "ready": "Готовность диагностических тестов двигателя",
        "fcmEnd": "Количество ошибок в памяти ЭБУ"
    ]

    /// The profile's aliases are English, so translate the useful generic ones too.
    private static let russianAliases: [String: String] = [
        "CountStartsWithOilInFuel": "Запуски двигателя с попаданием топлива в масло",
        "LambdaPID-I_Bank2": "Лямбда-регулятор · интегральная коррекция · ряд 2",
        "LambdaPID-I": "Лямбда-регулятор · интегральная коррекция · ряд 1",
        "LambdaPID-P_Bank2": "Лямбда-регулятор · пропорциональная коррекция · ряд 2",
        "LambdaPID-P": "Лямбда-регулятор · пропорциональная коррекция · ряд 1",
        "IdleSpeedPID-I": "Регулятор холостого хода · интегральная коррекция",
        "DynamicFactorO2SBank2": "Динамика широкополосного лямбда-зонда · ряд 2",
        "DynamicFactorO2S": "Динамика широкополосного лямбда-зонда · ряд 1",
        "EtaIgnitionAngleAvg": "Средняя эффективность угла зажигания",
        "Inj-Cut-Mask": "Маска отключения форсунок",
        "NumberFaults": "Количество ошибок ЭБУ",
        "AltitudeCorrectionFactor": "Поправка на высоту над уровнем моря",
        "LambdaControlBank2": "Выход лямбда-регулятора · ряд 2",
        "LambdaControl": "Выход лямбда-регулятора · ряд 1",
        "AdaptationPartialBank2": "Топливная адаптация · ряд 2",
        "AdaptationPartial": "Топливная адаптация · ряд 1",
        "LambdaControlAvgBank2": "Средний выход лямбда-регулятора · ряд 2",
        "LambdaControlAvg": "Средний выход лямбда-регулятора · ряд 1",
        "LoadCorrectFactorCoolantTemp": "Поправка нагрузки по температуре охлаждающей жидкости",
        "LoadCorrectFactorIntakeTemp": "Поправка нагрузки по температуре воздуха на впуске",
        "CountMisfireTotal": "Общее количество пропусков воспламенения",
        "SelectedGear": "Включённая передача",
        "LambdaPartProtection": "Целевая лямбда для защиты двигателя",
        "TargetAFRDriverRequest": "Целевая лямбда по запросу водителя",
        "AirFuelRatioDesiredBank2": "Целевая лямбда · ряд 2",
        "AirFuelRatioDesired": "Целевая лямбда · ряд 1",
        "AirFuelRatioCurrentBank2": "Фактическая лямбда · ряд 2",
        "AirFuelRatioCurrent": "Фактическая лямбда · ряд 1",
        "BoostPID-I-Min": "Регулятор наддува · нижний предел I-составляющей",
        "BoostPID-I-Max": "Регулятор наддува · верхний предел I-составляющей",
        "ChargeLimitPID-I": "Ограничитель наддува · I-составляющая",
        "BoostPID-I-Result": "Регулятор наддува · результат I-составляющей",
        "BoostPID-P-Result": "Регулятор наддува · результат P-составляющей",
        "BoostPID-D-Result": "Регулятор наддува · результат D-составляющей",
        "ChargeLimitEngineProtection": "Ограничение наддува по защите двигателя",
        "ChargeLimitTurboProtection": "Ограничение наддува по защите турбины",
        "WastegateDutyCycleAfterLin": "N75 · скважность после линеаризации",
        "WastegateDutyCycle": "N75 · итоговая скважность",
        "WastegateDutyCycleBeforeLin": "N75 · команда регулятора до коррекции",
        "EngineLossTorque": "Расчётный крутящий момент потерь двигателя",
        "RequestedTorqueTractionControl": "Запрос момента системы стабилизации",
        "DriverRequestedRelTorque": "Запрошенный водителем крутящий момент",
        "MassAirFlowAtThrottlePlate": "Расход воздуха через дроссель",
        "MassAirFlow": "Расход воздуха по ДМРВ",
        "EngineSpeed": "Обороты двигателя",
        "EngineIdlingSpeed": "Обороты двигателя на холостом ходу",
        "RequestedEngineIdlingSpeed": "Заданные обороты холостого хода",
        "EngineLoad": "Нагрузка двигателя",
        "EngineLoadCorrected": "Скорректированная нагрузка двигателя",
        "EngineLoadSpecified": "Предельная нагрузка двигателя",
        "EngineLoadRequested": "Заданная нагрузка двигателя",
        "BoostPressureDesired": "Заданный наддув · абсолютное давление",
        "BoostPressureActual": "Фактическое давление перед дросселем · абсолютное",
        "BaroPressure": "Атмосферное давление",
        "Inj-Reduction": "Снижение подачи топлива",
        "O2SVoltageSensor2": "Напряжение лямбда-зонда после катализатора · ряд 1",
        "O2SVoltageSensor2Bank2": "Напряжение лямбда-зонда после катализатора · ряд 2",
        "ThrottlePlateAngle": "Фактическое открытие дросселя",
        "ThrottlePlateAngleRequested": "Заданное открытие дросселя",
        "IgnRetardKnockControlCyl1": "Откат угла зажигания по детонации · цилиндр 1",
        "AvgIgnitionRetardKnockControl": "Средний откат угла зажигания из-за детонации",
        "IgnitionTimingAngle": "Угол зажигания",
        "IgnitionTimingAngleOverall": "Итоговый угол зажигания",
        "AccelPedalPosition": "Положение педали газа",
        "BatteryVoltage": "Напряжение бортовой сети",
        "VehicleSpeed": "Скорость автомобиля",
        "MAFSensorVoltage": "Сигнал напряжения ДМРВ",
        "O2SVoltageWidebandBank2": "Сигнал широкополосной лямбды до катализатора · ряд 2",
        "O2SVoltageWideband": "Сигнал широкополосной лямбды до катализатора · ряд 1"
    ]

    private static func channelName(for name: String) -> String? {
        let families: [(String, String)] = [
            ("dwkrz_", "Откат угла зажигания по детонации · канал "),
            ("wkr_", "Коррекция угла зажигания по детонации · канал "),
            ("fzabg_w_", "Счётчик пропусков воспламенения · канал "),
            ("fzmd_", "Счётчик пропусков воспламенения · канал "),
            ("rkrn_w_", "Сигнал датчика детонации · канал ")
        ]
        for (prefix, label) in families where name.hasPrefix(prefix) {
            guard let channel = Int(name.dropFirst(prefix.count)) else { continue }
            return label + String(channel + 1)
        }
        return nil
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
        ("Наддув", ["nmot", "gangi", "wped_w", "wdkba", "rl_w", "rlsol_w", "rlmax_w", "plsol_w",
                    "pvdkds_w", "pus_w", "ldtvm", "ldtvr_w", "ldrlts_w", "mshfm_w", "B_ldsua", "B_ldsuad",
                    "B_ldsuas", "zwout", "dwkrz_0", "dwkrz_1", "dwkrz_2", "dwkrz_3", "dwkrz_4", "dwkrz_5",
                    "dwkrz_6", "dwkrz_7", "tans", "tmot", "lamsoni_w", "lamsoni2_w"]),
        ("Детонация", ["nmot", "rl_w", "zwout", "dwkrz_0", "dwkrz_1", "dwkrz_2", "dwkrz_3",
                       "dwkrz_4", "dwkrz_5", "dwkrz_6", "dwkrz_7", "wkrm", "tans"]),
        ("Лямбда", ["nmot", "rl_w", "lamsbg_w", "lamfa_w", "lambts_w", "lamsoni_w", "lamsoni2_w",
                    "fr_w", "fr2_w", "ti_b1", "ti_b2", "mshfm_w"]),
        ("Базовый", ["nmot", "vfzg", "gangi", "wped_w", "wdkba", "rl_w", "zwout", "tmot", "tans", "ub"]),
    ]
}
