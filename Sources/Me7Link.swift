import Foundation

struct Settings {
    var host = "192.168.0.10"
    var port = 35000
    var proto = "4"                 // ELM: 4 = ISO 14230-4 KWP slow (5 baud) init, 5 = fast init
    var initAddress = "01"          // ME7 engine ECU (kai.ecu: Connect = SLOW-0x01)
    var header = "8101F1"           // KWP format/target/source; ELM fills in the length
    var sessions = "1089,1086,-"    // tried in order; "-" = continue without a session request
    var lid = "F0"                  // dynamically defined local identifier
    var maxBytes = 64               // max data bytes in one 0x21 answer
}

enum LinkState: Equatable { case idle, busy, ok, fail }

struct LiveValue: Identifiable {
    let id: String
    let label: String
    let value: Double
    let unit: String
}

/// ATAL: K-line messages longer than 7 data bytes (0x21 block, DTC list).
private let baseSetup = ["ATE0", "ATL0", "ATS0", "ATH0", "ATAL", "ATAT1", "ATST64", "ATKW0"]

/// ME7 over ELM327 K-line, in three separate steps so it is clear which one fails:
///  1. connectElm  TCP to the Wi-Fi adapter + AT setup
///  2. connectEcu  5-baud init to 0x01 (or fast init) -> diagnostic session
///  3. startLog    0x2C define LID by memory address -> loop 0x21 LID
///                 (falls back to 0x23 readMemoryByAddress per variable if 0x2C is refused)
/// All steps run one after another on a single worker queue; every failure reason goes to the trace.
final class Me7Link: ObservableObject {
    @Published var elmState = LinkState.idle
    @Published var elmText = "НЕ ПОДКЛЮЧЕНО"
    @Published var ecuState = LinkState.idle
    @Published var ecuText = "НЕ ПОДКЛЮЧЕНО"
    @Published var dtcState = LinkState.idle
    @Published var dtcText = "Не прочитаны"
    @Published var moduleDiagnostics: [DtcModule: ModuleDiagnostic] = Dictionary(
        uniqueKeysWithValues: DtcModule.allCases.map { ($0, ModuleDiagnostic()) }
    )
    @Published var clearAllState = LinkState.idle
    @Published var clearAllText = ""
    @Published var blockScanState = LinkState.idle
    @Published var blockScanStatus = "Полный опрос ещё не запускался"
    @Published var blockScanProgress = 0
    @Published var blockScanTotal = 0
    @Published var blockScanResults: [BlockScanResult] = []
    @Published var traceFileURL: URL?
    @Published var logging = false
    @Published var logText = ""
    @Published var live: [LiveValue] = []
    @Published var hz = 0.0
    @Published var trace: [String] = []

    private let worker = DispatchQueue(label: "me7.link")
    private let traceFileLock = NSLock()
    private var elm: Elm?
    private var traceFile: FileHandle?
    private var ecuOk = false
    private var activeModule: DtcModule?
    private let flagLock = NSLock()
    private let clearAllLock = NSLock()
    private let blockScanLock = NSLock()
    private var clearAllIsQueuedOrRunning = false
    private var blockScanIsQueuedOrRunning = false
    private var blockScanStopRequested = false
    private var blockScanBridgeState = "Не указано"
    private var runFlag = false
    private var running: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return runFlag }
        set { flagLock.lock(); runFlag = newValue; flagLock.unlock() }
    }
    private static let traceTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    // ---------- plumbing ----------

    private func ui(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
    private func setElm(_ s: LinkState, _ text: String) { ui { self.elmState = s; self.elmText = text } }
    private func setEcu(_ s: LinkState, _ text: String) { ui { self.ecuState = s; self.ecuText = text } }
    private func setDtc(_ s: LinkState, _ text: String) { ui { self.dtcState = s; self.dtcText = text } }
    private func setLog(_ r: Bool, _ text: String) { ui { self.logging = r; self.logText = text } }
    private func setClearAll(_ state: LinkState, _ text: String) {
        ui { self.clearAllState = state; self.clearAllText = text }
    }
    private func beginClearAll() -> Bool {
        clearAllLock.lock()
        defer { clearAllLock.unlock() }
        guard !clearAllIsQueuedOrRunning else { return false }
        clearAllIsQueuedOrRunning = true
        return true
    }

    private func endClearAll() {
        clearAllLock.lock()
        clearAllIsQueuedOrRunning = false
        clearAllLock.unlock()
    }

    private func beginBlockScan() -> Bool {
        blockScanLock.lock()
        defer { blockScanLock.unlock() }
        guard !blockScanIsQueuedOrRunning else { return false }
        blockScanIsQueuedOrRunning = true
        blockScanStopRequested = false
        return true
    }

    private func endBlockScan() {
        blockScanLock.lock()
        blockScanIsQueuedOrRunning = false
        blockScanStopRequested = false
        blockScanLock.unlock()
    }

    private var shouldStopBlockScan: Bool {
        blockScanLock.lock()
        defer { blockScanLock.unlock() }
        return blockScanStopRequested
    }

    private var currentBlockScanBridgeState: String {
        blockScanLock.lock()
        defer { blockScanLock.unlock() }
        return blockScanBridgeState
    }

    private func setBlockScanBridgeState(_ state: String) {
        blockScanLock.lock()
        blockScanBridgeState = state
        blockScanLock.unlock()
    }
    private func updateModule(_ module: DtcModule, _ change: @escaping (inout ModuleDiagnostic) -> Void) {
        ui {
            var value = self.moduleDiagnostics[module] ?? ModuleDiagnostic()
            change(&value)
            self.moduleDiagnostics[module] = value
        }
    }

    private func resetModules(_ text: String) {
        ui {
            self.moduleDiagnostics = Dictionary(uniqueKeysWithValues: DtcModule.allCases.map {
                var value = ModuleDiagnostic()
                value.connectionText = text
                return ($0, value)
            })
        }
    }

    private func t(_ s: String) {
        let timestamp = Self.traceTimestampFormatter.string(from: Date())
        let stamped = s.components(separatedBy: "\n").map { "[\(timestamp)] \($0)" }.joined(separator: "\n")
        ui {
            self.trace.append(stamped)
            if self.trace.count > 60 { self.trace.removeFirst(self.trace.count - 60) }
        }
        if let data = (stamped + "\n").data(using: .utf8) {
            traceFileLock.lock()
            traceFile?.write(data)
            traceFileLock.unlock()
        }
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    /// Documents/ME7Logs/<name> — visible in the Files app under "На iPhone > ME7Mobile".
    private func openOutput(_ name: String) -> FileHandle? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("ME7Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: url)
        ui { self.traceFileURL = handle == nil ? nil : url }
        return handle
    }

    func flushTraceFile() {
        traceFileLock.lock()
        try? traceFile?.synchronize()
        traceFileLock.unlock()
    }

    func prepareTraceExport() {
        t("=== Пользователь запросил экспорт полной трассы ===")
        flushTraceFile()
    }

    /// Runs `block` on the worker; a dead adapter connection turns step 1 red, anything else is reported by `onError`.
    private func job(_ onError: @escaping (String) -> Void, _ block: @escaping () throws -> Void) {
        worker.async {
            do { try block() }
            catch ElmError.closed {
                self.blockScanLock.lock()
                let scanActive = self.blockScanIsQueuedOrRunning
                self.blockScanLock.unlock()
                if scanActive {
                    self.ui {
                        self.blockScanState = .fail
                        self.blockScanStatus = "Сканирование прервано: связь с адаптером потеряна"
                    }
                }
                self.elmFail("связь с адаптером потеряна")
                self.flushTraceFile()
            }
            catch { self.t("EXCEPTION \(error)"); self.flushTraceFile(); onError("\(error)") }
        }
    }

    // ---------- 1. adapter ----------

    /// One button starts the adapter connection and queues the ECU connection right after it.
    /// Both jobs share the serial worker, so the ECU is attempted only after ELM setup completes.
    func connectAll(_ s: Settings) {
        connectElm(s)
        connectEcu(s)
    }

    func connectElm(_ s: Settings) {
        ui { self.trace.removeAll() }
        job({ self.elmFail($0) }) {
            self.closeAll()
            self.resetModules("Ожидание подключения")
            self.setEcu(.idle, "НЕ ПОДКЛЮЧЕНО")
            self.setElm(.busy, "Подключение к \(s.host):\(s.port)…")
            self.traceFile = self.openOutput("me7_\(self.stamp())_trace.txt")
            self.t("=== ELM \(s.host):\(s.port) ===")
            let e = Elm(trace: { [weak self] in self?.t($0) })
            do {
                try e.open(host: s.host, port: s.port, timeout: 5)
            } catch {
                self.elmFail("нет соединения с \(s.host):\(s.port) — iPhone подключён к Wi-Fi адаптера? Разрешена «Локальная сеть» для ME7Mobile? (\(error))")
                return
            }
            self.elm = e
            _ = try e.cmd("ATZ", timeout: 4)
            Thread.sleep(forTimeInterval: 0.8)
            let ver = try e.cmd("ATI")
            if !ver.uppercased().contains("ELM") {
                self.elmFail("адаптер не ответил на ATI (ответ: \(ver.isEmpty ? "пусто" : ver))")
                return
            }
            for c in baseSetup {
                let r = try e.cmd(c)
                if !r.uppercased().contains("OK") { self.t("предупреждение: \(c) → \(r.isEmpty ? "нет ответа" : r)") }
            }
            let volt = try e.cmd("ATRV")
            self.t("ELM подключён: \(ver), \(volt)")
            self.setElm(.ok, "ПОДКЛЮЧЕНО · \(ver) · \(volt)")
        }
    }

    private func elmFail(_ msg: String) {
        t("ОШИБКА ELM: \(msg)")
        closeSocket()
        setElm(.fail, "НЕ ПОДКЛЮЧЕНО\n\(msg)")
        setEcu(.idle, "НЕ ПОДКЛЮЧЕНО")
        activeModule = nil
        resetModules("Нет соединения с адаптером")
    }

    func disconnect() {
        running = false
        worker.async {
            self.closeAll()
            self.setElm(.idle, "НЕ ПОДКЛЮЧЕНО")
            self.setEcu(.idle, "НЕ ПОДКЛЮЧЕНО")
            self.activeModule = nil
            self.resetModules("Не подключено")
        }
    }

    private func closeSocket() {
        ecuOk = false
        activeModule = nil
        elm?.close()
        elm = nil
    }

    private func closeAll() {
        closeSocket()
        traceFileLock.lock()
        try? traceFile?.close()
        traceFile = nil
        traceFileLock.unlock()
    }

    // ---------- 2. engine ECU ----------

    /// How the ELM wakes up the ECU: protocol 3/4 = 5-baud init to initAddress, 5 = fast init (target taken from header).
    private struct Link {
        let proto: String
        let initAddress: String
        let header: String
        var label: String { proto == "5" ? "fast init \(header.dropFirst(2).prefix(2))" : "5 бод 0x\(initAddress)" }
    }

    /// User settings first, then fast init variants (kai.ecu alternative: FAST-0x10).
    func connectEcu(_ s: Settings) {
        job({ self.ecuFail($0) }) {
            guard let e = self.elm else { self.ecuFail("сначала подключи ELM"); return }
            _ = try self.connectEngineOnWorker(e, s)
        }
    }

    @discardableResult
    private func connectEngineOnWorker(_ e: Elm, _ s: Settings) throws -> Bool {
        ecuOk = false
        if let previous = activeModule, previous != .engine {
            updateModule(previous) { $0.connectionState = .idle; $0.connectionText = "Сеанс закрыт при выборе двигателя" }
        }
        activeModule = nil
        updateModule(.engine) { $0.connectionState = .busy; $0.connectionText = "Инициализация блока двигателя…" }
        setEcu(.busy, "Инициализация блока…")
        t("=== ЭБУ ===")
        var links = [Link(proto: s.proto, initAddress: s.initAddress, header: s.header)]
        for link in [Link(proto: "5", initAddress: "", header: "8110F1"), Link(proto: "5", initAddress: "", header: "8101F1")]
        where !links.contains(where: { $0.proto == link.proto && $0.header == link.header }) {
            links.append(link)
        }
        var results: [String] = []
        for link in links {
            setEcu(.busy, (["Инициализация: \(link.label)…"] + results).joined(separator: "\n"))
            t("--- попытка: \(link.label), заголовок \(link.header) ---")
            try e.prepareKwpMode()
            _ = try e.cmd("ATSP\(link.proto)")
            if link.proto == "3" || link.proto == "4" { _ = try e.cmd("ATIIA\(link.initAddress)") }
            _ = try e.cmd("ATSH\(link.header)")
            _ = try e.cmd("ATWM\(link.header)3E")
            let (session, error) = try startSession(e, s)
            if let session = session {
                ecuOk = true
                activeModule = .engine
                t("ЭБУ подключён: \(link.label), сессия \(session)")
                setEcu(.ok, "ПОДКЛЮЧЕНО · \(link.label) · сессия \(session)")
                updateModule(.engine) { $0.connectionState = .ok; $0.connectionText = "Подключено · \(link.label) · сессия \(session)" }
                try readSoftwareNumber(e, module: .engine)
                return true
            }
            results.append("\(link.label) ✗ \(error)")
        }
        updateModule(.engine) { $0.connectionState = .fail; $0.connectionText = results.joined(separator: "\n") }
        ecuFail(results.joined(separator: "\n"))
        return false
    }

    /// Connect to one selected KWP2000 controller. Other modules are explicitly reinitialized
    /// because the ELM adapter can hold only one active physical K-line session at a time.
    func connectModule(_ module: DtcModule, _ s: Settings) {
        job({ self.moduleConnectionFail(module, $0) }) {
            guard let e = self.elm else { self.moduleConnectionFail(module, "сначала подключи ELM"); return }
            _ = try self.connectModuleOnWorker(module, e, s)
        }
    }

    @discardableResult
    private func connectModuleOnWorker(_ module: DtcModule, _ e: Elm, _ s: Settings) throws -> Bool {
        if module == .engine { return try connectEngineOnWorker(e, s) }
        ecuOk = false
        if let previous = activeModule {
            updateModule(previous) { $0.connectionState = .idle; $0.connectionText = "Сеанс закрыт при выборе другого блока" }
        }
        activeModule = nil
        setEcu(.idle, "Двигатель не выбран для текущей диагностики")
        updateModule(module) {
            $0.connectionState = .busy
            $0.connectionText = "Подключение к блоку \(module.target)…"
            $0.softwareNumber = "Чтение…"
            $0.dtcState = .idle
            $0.dtcText = "Ошибки не прочитаны"
            $0.codes = []
        }
        t("=== подключение: \(module.title), адрес 0x\(module.target) ===")

        let target = module.target
        let links = [
            Link(proto: "5", initAddress: "", header: "81\(target)F1"),
            Link(proto: "4", initAddress: target, header: "C1\(target)F1"),
        ]
        var failures: [String] = []
        for link in links {
            t("--- \(link.label), заголовок \(link.header) ---")
            try e.prepareKwpMode()
            _ = try e.cmd("ATSP\(link.proto)")
            if link.proto == "3" || link.proto == "4" { _ = try e.cmd("ATIIA\(link.initAddress)") }
            _ = try e.cmd("ATSH\(link.header)")
            _ = try e.cmd("ATWM\(link.header)3E")
            let (session, error) = try startSession(e, module.sessions)
            if let session = session {
                activeModule = module
                let status = "Подключено · \(link.label) · сессия \(session)"
                updateModule(module) { $0.connectionState = .ok; $0.connectionText = status }
                t("\(module.title): подключено, \(status)")
                try readSoftwareNumber(e, module: module)
                return true
            }
            failures.append("\(link.label): \(error)")
            _ = try e.cmd("ATPC")
        }

        if module == .transmission || module == .absEsp {
            let targetAddress = Int(target, radix: 16) ?? 0
            let tp16Rates = module == .absEsp ? [1, 2] : [1]
            for divisor in tp16Rates {
                let baud = divisor == 1 ? 500 : 500 / divisor
                let label = "VW TP1.6 / CAN \(baud) кбит/с"
                t("--- альтернативная попытка: \(label) ---")
                let setup = try e.connectTP16(target: targetAddress, baudDivisor: divisor)
                if setup.connected {
                    let (session, error) = try startSession(e, module.sessions)
                    if let session = session {
                        activeModule = module
                        let status = "Подключено · \(label) · сессия \(session)"
                        updateModule(module) { $0.connectionState = .ok; $0.connectionText = status }
                        t("\(module.title): подключено через \(label), сессия \(session)")
                        try readSoftwareNumber(e, module: module)
                        return true
                    }
                    failures.append("\(label): канал открыт, но KWP-сессия не ответила (\(error))")
                    e.disconnectTP16()
                } else {
                    failures.append("\(label): \(setup.reason)")
                }
            }

            if module == .absEsp {
                for divisor in [1, 2] {
                    let baud = divisor == 1 ? 500 : 500 / divisor
                    let label = "VW TP2.0 / CAN \(baud) кбит/с"
                    t("--- альтернативная попытка: \(label) ---")
                    let setup = try e.connectTP20(target: targetAddress, baudDivisor: divisor)
                    if setup.connected {
                        let (session, error) = try startSession(e, module.sessions)
                        if let session = session {
                            activeModule = module
                            let status = "Подключено · \(label) · сессия \(session)"
                            updateModule(module) { $0.connectionState = .ok; $0.connectionText = status }
                            t("\(module.title): подключено через \(label), сессия \(session)")
                            try readSoftwareNumber(e, module: module)
                            return true
                        }
                        failures.append("\(label): канал открыт, но KWP-сессия не ответила (\(error))")
                        e.disconnectTP16()
                    } else {
                        failures.append("\(label): \(setup.reason)")
                    }
                }
            }
        }

        var message = failures.joined(separator: "\n")
        if let hint = module.protocolHint { message += "\n\(hint)" }
        message += "\nПроверь питание блока, диагностическую линию (OBD 3/7) и CAN на контактах 6/14."
        moduleConnectionFail(module, message)
        return false
    }

    /// Probe the known Cayenne 955/VAG address table over each transport supported by this ELM path.
    /// No DTC erase, coding, actuator or write service is sent; only identification and session probes.
    func noteBlockScanScreenOpened(bridgeState: String) {
        setBlockScanBridgeState(bridgeState)
        t("=== открыт экран теста блоков; перемычка 3–7 отмечена как: \(bridgeState) ===")
    }

    func noteBlockScanBridgeStateChanged(_ state: String) {
        setBlockScanBridgeState(state)
        t("=== пользователь отметил новое положение перемычки 3–7: \(state) ===")
        flushTraceFile()
    }

    func scanAllBlocks(_ s: Settings, bridgeState: String) {
        guard beginBlockScan() else { return }
        setBlockScanBridgeState(bridgeState)
        ui {
            self.blockScanState = .busy
            self.blockScanStatus = "Подготовка полного опроса…"
            self.blockScanProgress = 0
            self.blockScanTotal = BlockScanTarget.cayenne955.count * 6
            self.blockScanResults = BlockScanTarget.cayenne955.map { BlockScanResult(target: $0) }
        }
        job({ message in
            self.ui {
                self.blockScanState = .fail
                self.blockScanStatus = "Сканирование прервано: \(message)"
            }
        }) {
            defer { self.endBlockScan() }
            self.t("=== ПОЛНЫЙ ОПРОС БЛОКОВ Cayenne 955 ===")
            self.t("ELM: \(s.host):\(s.port)")
            self.t("Перемычка OBD 3–7 по отметке пользователя: \(bridgeState)")
            guard let e = self.elm else {
                self.t("Опрос не начат: нет активного соединения ELM327")
                self.flushTraceFile()
                self.ui { self.blockScanState = .fail; self.blockScanStatus = "Сначала подключи ELM327" }
                return
            }

            self.ecuOk = false
            if let previous = self.activeModule {
                self.updateModule(previous) { $0.connectionState = .idle; $0.connectionText = "Сканер блоков завершил прежний сеанс" }
            }
            self.activeModule = nil
            self.setEcu(.idle, "Выполняется полный опрос блоков")
            e.disconnectTP16()

            let targets = BlockScanTarget.cayenne955
            let total = targets.count * 6
            var progress = 0
            var results = targets.map { BlockScanResult(target: $0) }
            self.t("Кандидатов адресов: \(targets.count); проверок транспорта: \(total)")
            self.t("Адреса: \(targets.map { "0x\($0.addressText) \($0.title)" }.joined(separator: "; "))")
            self.t("Проверки только читающие: KWP идентификация/сессия, TP1.6 и TP2.0. Очистка, кодирование и исполнительные тесты не выполняются.")

            for index in targets.indices {
                if self.shouldStopBlockScan { break }
                let target = targets[index]
                self.t("=== адрес 0x\(target.addressText): \(target.title) ===")

                func record(_ label: String, run: () throws -> BlockScanAttempt) throws {
                    if self.shouldStopBlockScan { return }
                    progress += 1
                    let currentProgress = progress
                    let currentStatus = "\(currentProgress)/\(total) · 0x\(target.addressText) \(target.title) · \(label)"
                    self.ui {
                        self.blockScanProgress = currentProgress
                        self.blockScanStatus = currentStatus
                    }
                    self.t("--- ПРОБА \(label), адрес 0x\(target.addressText); перемычка отмечена как: \(self.currentBlockScanBridgeState) ---")
                    let attempt = try run()
                    results[index].attempts.append(attempt)
                    let stateText: String
                    switch attempt.state {
                    case .responded: stateText = "ОТВЕТИЛ"
                    case .channelOnly: stateText = "КАНАЛ ОТКРЫТ, KWP МОЛЧИТ"
                    case .noResponse: stateText = "НЕТ ОТВЕТА"
                    }
                    self.t("ИТОГ 0x\(target.addressText) · \(label): \(stateText) · \(attempt.detail)")
                    let snapshot = results
                    self.ui { self.blockScanResults = snapshot }
                    self.flushTraceFile()
                }

                try record("KWP fast init · K-Line") {
                    try e.prepareKwpMode()
                    _ = try e.cmd("ATSP5")
                    let header = "81\(target.addressText)F1"
                    _ = try e.cmd("ATSH\(header)")
                    _ = try e.cmd("ATWM\(header)3E")
                    return try self.probeBlockKwp(e)
                }

                try record("KWP slow init · K-Line 5 бод") {
                    try e.prepareKwpMode()
                    _ = try e.cmd("ATSP4")
                    _ = try e.cmd("ATIIA\(target.addressText)")
                    let header = "C1\(target.addressText)F1"
                    _ = try e.cmd("ATSH\(header)")
                    _ = try e.cmd("ATWM\(header)3E")
                    return try self.probeBlockKwp(e)
                }

                for (name, divisor) in [("VW TP1.6 · CAN 500 кбит/с", 1), ("VW TP1.6 · CAN 250 кбит/с", 2)] {
                    try record(name) {
                        let setup = try e.connectTP16(target: target.address, baudDivisor: divisor)
                        guard setup.connected else { return BlockScanAttempt(mode: name, state: .noResponse, detail: setup.reason) }
                        let response = try self.probeBlockKwp(e)
                        e.disconnectTP16()
                        if let response = response.response {
                            return BlockScanAttempt(mode: name, state: .responded, detail: response.detail)
                        }
                        return BlockScanAttempt(mode: name, state: .channelOnly,
                                                detail: "транспортный канал открыт; диагностический KWP-ответ не получен (\(response.detail))")
                    }
                }

                for (name, divisor) in [("VW TP2.0 · CAN 500 кбит/с", 1), ("VW TP2.0 · CAN 250 кбит/с", 2)] {
                    try record(name) {
                        let setup = try e.connectTP20(target: target.address, baudDivisor: divisor)
                        guard setup.connected else { return BlockScanAttempt(mode: name, state: .noResponse, detail: setup.reason) }
                        let response = try self.probeBlockKwp(e)
                        e.disconnectTP16()
                        if let response = response.response {
                            return BlockScanAttempt(mode: name, state: .responded, detail: response.detail)
                        }
                        return BlockScanAttempt(mode: name, state: .channelOnly,
                                                detail: "транспортный канал открыт; диагностический KWP-ответ не получен (\(response.detail))")
                    }
                }
            }

            e.disconnectTP16()
            let replied = results.filter(\.responded).count
            let channelOnly = results.filter { !$0.responded && $0.transportOpened }.count
            let stopped = self.shouldStopBlockScan
            let summary = stopped
                ? "Остановлено пользователем: \(progress)/\(total) проверок; ответили \(replied) блоков, ещё \(channelOnly) открыли только транспортный канал."
                : "Завершено: ответили \(replied) блоков; ещё \(channelOnly) открыли только транспортный канал."
            self.t("=== ИТОГ ПОЛНОГО ОПРОСА ===")
            self.t(summary)
            self.ui {
                self.blockScanResults = results
                self.blockScanProgress = progress
                self.blockScanStatus = summary
                self.blockScanState = stopped ? .idle : .ok
            }
            self.setEcu(.idle, "Опрос завершён; выбери блок для отдельного подключения")
            self.flushTraceFile()
        }
    }

    func stopBlockScan() {
        blockScanLock.lock()
        blockScanStopRequested = true
        blockScanLock.unlock()
        t("=== Пользователь запросил остановку полного опроса; текущая проба будет завершена ===")
        ui { self.blockScanStatus = "Останавливаю после текущей пробы…" }
    }

    private func probeBlockKwp(_ e: Elm) throws -> (response: Response?, detail: String) {
        var observations: [String] = []
        for service in ["1A91", "1A9B"] {
            let response = try e.request(service, timeout: 1.2)
            t("Проба KWP \(service): \(response)")
            observations.append("\(service): \(response)")
            if response.ok { return (response, "\(service) → \(response)") }
        }

        for service in ["1089", "1086", "1003"] {
            let session = try e.request(service, timeout: 1.5)
            t("Проба KWP-сеанса \(service): \(session)")
            observations.append("\(service): \(session)")
            guard session.ok else { continue }
            if session.isPositive(0x10) {
                for identifier in ["1A91", "1A9B"] {
                    let afterSession = try e.request(identifier, timeout: 1.2)
                    t("Повтор KWP \(identifier) после сеанса \(service): \(afterSession)")
                    if afterSession.ok {
                        return (afterSession, "сеанс \(service); \(identifier) → \(afterSession)")
                    }
                }
            }
            return (session, "ответ на сеанс \(service) → \(session)")
        }
        return (nil, observations.joined(separator: "; "))
    }

    private func moduleConnectionFail(_ module: DtcModule, _ message: String) {
        t("ОШИБКА \(module.title): \(message.replacingOccurrences(of: "\n", with: "; "))")
        if activeModule == module { activeModule = nil }
        updateModule(module) {
            $0.connectionState = .fail
            $0.connectionText = message
            $0.softwareNumber = "Не получен: нет соединения с блоком"
        }
    }

    /// Read long ECU identification first, then try common VAG KWP identification options.
    /// Values are kept as returned instead of being guessed into a part/software number.
    private func readSoftwareNumber(_ e: Elm, module: DtcModule) throws {
        for option in ["9B", "91"] {
            do {
                let response = try e.request("1A\(option)", timeout: 4)
                guard response.isPositive(0x1A), response.bytes.count > 2 else { continue }
                let value = Dtc.identificationText(Array(response.bytes.dropFirst(2)))
                let label = "1A \(option) · \(value)"
                updateModule(module) { $0.softwareNumber = label }
                t("\(module.title), идентификация ПО: \(label)")
                return
            } catch ElmError.closed {
                throw ElmError.closed
            } catch {
                t("\(module.title), идентификация 1A \(option): \(error)")
            }
        }
        updateModule(module) { $0.softwareNumber = "Блок не предоставил поддерживаемый номер ПО" }
        t("\(module.title): идентификатор ПО не поддержан")
    }

    private func ecuFail(_ msg: String) {
        t("ОШИБКА ЭБУ: \(msg.replacingOccurrences(of: "\n", with: "; "))")
        ecuOk = false
        if activeModule == .engine { activeModule = nil }
        updateModule(.engine) { $0.connectionState = .fail; $0.connectionText = msg }
        setEcu(.fail, "НЕ ПОДКЛЮЧЕНО\n\(msg)")
    }

    /// Returns (accepted session, "") or (nil, short reason of the last failure).
    private func startSession(_ e: Elm, _ s: Settings) throws -> (String?, String) {
        let list = s.sessions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return try startSession(e, list)
    }

    private func startSession(_ e: Elm, _ list: [String]) throws -> (String?, String) {
        var reason = "нет ответа"
        for sess in list {
            let r = try e.request(sess == "-" ? "3E" : sess, timeout: 8)
            t("\(sess == "-" ? "tester present" : "session \(sess)"): \(r)")
            if sess == "-" && r.ok && !r.negative { return ("без запроса сессии", "") }
            if r.isPositive(0x10) { return (sess, "") }
            if r.negative { reason = "отказ 7F \(hx(r.bytes[1])) \(hx(r.bytes[2])) на \(sess)" }
            else if let first = r.errors.first { reason = first }
            else { reason = "нет ответа" }
            let busError = r.errors.contains { err in
                let u = err.uppercased()
                return u.contains("UNABLE") || u.contains("BUS INIT") || u.contains("BUS ERROR")
            }
            if busError { _ = try e.cmd("ATPC") }          // close protocol, next attempt re-inits
        }
        return (nil, reason)
    }

    /// Standard OBD requests tell apart "adapter has no working K-line" from "K-line works, ECU ignores our init".
    /// Leaves the ECU disconnected and the ELM back in its base setup.
    func probeBus() {
        job({ self.ecuFail($0) }) {
            guard let e = self.elm else { self.ecuFail("сначала подключи ELM"); return }
            self.ecuOk = false
            if let previous = self.activeModule {
                self.updateModule(previous) { $0.connectionState = .idle; $0.connectionText = "Сеанс закрыт для проверки шины" }
            }
            self.activeModule = nil
            self.setEcu(.busy, "Проверка шины (OBD 0100)…")
            self.t("=== диагностика шины (OBD 0100) ===")
            var answers: [String] = []
            func probe(_ name: String, _ setup: [String]) throws {
                _ = try e.cmd("ATPC")
                for c in setup { _ = try e.cmd(c) }
                let r = try e.cmd("0100", timeout: 10)
                let hex = r.split(separator: "\n").contains { $0.range(of: "^[0-9A-Fa-f ]{6,}$", options: .regularExpression) != nil }
                self.t("\(name): \(hex ? "ОТВЕТ" : "нет")")
                if hex { answers.append(name) }
            }
            try probe("K-line 5 бод 0x33", ["ATSP4", "ATIIA33", "ATSHC133F1"])
            try probe("K-line fast init", ["ATSP5", "ATSHC133F1"])
            _ = try e.cmd("ATD"); _ = try e.cmd("ATE0"); _ = try e.cmd("ATH1")   // defaults + headers on: shows who answers
            try probe("автопоиск", ["ATSP0"])
            let dp = try e.cmd("ATDPN")
            _ = try e.cmd("ATPC")
            for c in baseSetup { _ = try e.cmd(c) }
            if answers.isEmpty {
                self.ecuFail("Шина: OBD не отвечает ни по одному протоколу — похоже, у адаптера нет K-line (только CAN) или не подключён контакт 7")
            } else {
                let msg = "Шина живая: OBD отвечает (\(answers.joined(separator: ", ")), протокол \(dp)). Блок есть, проблема в инициализации"
                self.t(msg)
                self.setEcu(.idle, "НЕ ПОДКЛЮЧЕНО\n\(msg)")
            }
        }
    }

    // ---------- fault codes ----------

    /// KWP 0x18 readDiagnosticTroubleCodesByStatus, all groups. Answer: 58 n (hi lo status)*, possibly split over several lines.
    func readDtc() {
        job({ self.dtcFail($0) }) {
            guard let e = self.elm, self.ecuOk else { self.dtcFail("сначала подключи ЭБУ"); return }
            self.setDtc(.busy, "Чтение ошибок…")
            self.t("=== чтение ошибок ===")
            let text = try e.cmd("1802FF00", timeout: 5)
            var codes: [String] = []
            var answered = false
            for line in text.split(separator: "\n") {
                guard let b = hexBytes(String(line)) else { continue }
                if b[0] == 0x7F {
                    self.dtcFail("отказ 7F \(hx(b.count > 1 ? b[1] : 0)) \(hx(b.count > 2 ? b[2] : 0))")
                    return
                }
                if b[0] != 0x58 { continue }
                answered = true
                var i = 2
                while i + 2 < b.count { codes.append(Dtc.describe(b[i], b[i + 1], b[i + 2])); i += 3 }
            }
            if !answered {
                self.dtcFail("нет ответа (\(text.isEmpty ? "пусто" : text.replacingOccurrences(of: "\n", with: "; ")))")
                return
            }
            let msg = codes.isEmpty ? "Ошибок нет" : "Ошибок: \(codes.count)\n" + codes.joined(separator: "\n")
            self.t(msg)
            self.setDtc(codes.isEmpty ? .ok : .fail, msg)
        }
    }

    /// KWP 0x14 clearDiagnosticInformation, all groups; reads the list again afterwards.
    func clearDtc() {
        job({ self.dtcFail($0) }) {
            guard let e = self.elm, self.ecuOk else { self.dtcFail("сначала подключи ЭБУ"); return }
            self.setDtc(.busy, "Стирание ошибок…")
            self.t("=== стирание ошибок ===")
            let before = try self.readDtcSnapshotForClear(e, module: .engine)
            let r = try e.request("14FF00", timeout: 5)
            self.t("стирание: \(r)")
            let outcome = self.clearAckOutcome(r)
            self.t("результат команды очистки: \(outcome.detail)")
            if !outcome.acknowledged {
                self.dtcFail(outcome.detail)
                self.flushTraceFile()
                return
            }
            guard let remaining = try self.readDtcOnWorker(e, module: .engine) else { return }
            self.applyClearVerification(.engine, before: before, remaining: remaining)
        }
    }

    private func dtcFail(_ msg: String) {
        t("ОШИБКА ЧТЕНИЯ DTC: \(msg)")
        setDtc(.fail, "Не удалось: \(msg)")
    }

    /// Selected-module version used by the new module selector and detail screens.
    func readDtc(_ module: DtcModule) {
        job({ self.moduleDtcFail(module, $0) }) {
            guard let e = self.elm else { self.moduleDtcFail(module, "сначала подключи ELM"); return }
            guard self.activeModule == module else {
                self.moduleDtcFail(module, "сначала подключись к этому блоку")
                return
            }
            self.updateModule(module) { $0.dtcState = .busy; $0.dtcText = "Чтение ошибок…" }
            if module == .engine { self.setDtc(.busy, "Чтение ошибок…") }
            self.t("=== чтение ошибок: \(module.title) ===")
            _ = try self.readDtcOnWorker(e, module: module)
        }
    }

    /// Clear only the selected controller's fault memory, then confirm by reading it again.
    func clearDtc(_ module: DtcModule) {
        job({ self.moduleDtcFail(module, $0) }) {
            guard let e = self.elm else { self.moduleDtcFail(module, "сначала подключи ELM"); return }
            guard self.activeModule == module else {
                self.moduleDtcFail(module, "сначала подключись к этому блоку")
                return
            }
            self.updateModule(module) { $0.dtcState = .busy; $0.dtcText = "Стирание ошибок…" }
            if module == .engine { self.setDtc(.busy, "Стирание ошибок…") }
            self.t("=== стирание ошибок: \(module.title) ===")
            let before = try self.readDtcSnapshotForClear(e, module: module)
            let response = try e.request("14FF00", timeout: 8)
            self.t("ответ блока на стирание: \(response)")
            let outcome = self.clearAckOutcome(response)
            self.t("результат команды очистки: \(outcome.detail)")
            guard outcome.acknowledged else {
                self.moduleDtcFail(module, outcome.detail)
                self.flushTraceFile()
                return
            }
            guard let remaining = try self.readDtcOnWorker(e, module: module) else { return }
            self.applyClearVerification(module, before: before, remaining: remaining)
        }
    }

    /// Clear each supported ECU one at a time. A module is only counted as cleared when
    /// it acknowledged the clear request and a follow-up read reports an empty list.
    func clearAllDtc(_ s: Settings) {
        guard beginClearAll() else { return }
        setClearAll(.busy, "Подготовка к очистке…")
        job({ self.setClearAll(.fail, "Остановлено: \($0)") }) {
            defer { self.endClearAll() }
            do {
                guard let e = self.elm else {
                    self.setClearAll(.fail, "Сначала подключи ELM")
                    return
                }
                var cleared: [String] = []
                var acceptedWithRemaining: [String] = []
                var acceptedCount = 0
                var failed: [String] = []
                for module in DtcModule.allCases {
                    self.setClearAll(.busy, "\(module.title): подключение…")
                    do {
                        guard try self.connectModuleOnWorker(module, e, s) else {
                            failed.append("\(module.title): нет связи")
                            continue
                        }
                        self.setClearAll(.busy, "\(module.title): стирание ошибок…")
                        self.updateModule(module) { $0.dtcState = .busy; $0.dtcText = "Стирание ошибок…" }
                        if module == .engine { self.setDtc(.busy, "Стирание ошибок…") }
                        self.t("=== массовая очистка: \(module.title) ===")
                        let before = try self.readDtcSnapshotForClear(e, module: module)
                        let clearResponse = try e.request("14FF00", timeout: 8)
                        self.t("ответ блока на очистку \(module.title): \(clearResponse)")
                        let outcome = self.clearAckOutcome(clearResponse)
                        self.t("результат команды очистки \(module.title): \(outcome.detail)")
                        guard outcome.acknowledged else {
                            self.moduleDtcFail(module, outcome.detail)
                            failed.append("\(module.title): \(outcome.detail)")
                            continue
                        }
                        acceptedCount += 1
                        self.setClearAll(.busy, "\(module.title): проверка результата…")
                        guard let remaining = try self.readDtcOnWorker(e, module: module) else {
                            failed.append("\(module.title): команда принята, но результат не удалось проверить")
                            continue
                        }
                        let verification = self.applyClearVerification(module, before: before, remaining: remaining)
                        if remaining.isEmpty {
                            cleared.append(module.title)
                        } else {
                            acceptedWithRemaining.append("\(module.title): \(verification)")
                        }
                    } catch ElmError.closed {
                        throw ElmError.closed
                    } catch {
                        self.moduleDtcFail(module, "ошибка обмена: \(error)")
                        failed.append("\(module.title): ошибка обмена (\(error))")
                    }
                }

                var summary = "Команда очистки подтверждена для \(acceptedCount) блоков; без ошибок после проверки: \(cleared.count)."
                if !cleared.isEmpty { summary += "\nОшибок нет: \(cleared.joined(separator: ", "))." }
                if !acceptedWithRemaining.isEmpty {
                    summary += "\nКоманда принята, но коды остались или сразу появились снова: \(acceptedWithRemaining.joined(separator: "; "))."
                }
                if !failed.isEmpty { summary += "\nНе удалось выполнить или проверить: \(failed.joined(separator: "; "))." }
                self.t("Очистка ошибок во всех блоках завершена: \(summary.replacingOccurrences(of: "\n", with: " "))")
                self.flushTraceFile()
                self.setClearAll(failed.isEmpty ? .ok : .fail, summary)
            } catch ElmError.closed {
                self.setClearAll(.fail, "Остановлено: соединение с адаптером потеряно")
                throw ElmError.closed
            }
        }
    }

    private func readDtcSnapshotForClear(_ e: Elm, module: DtcModule) throws -> [DtcEntry]? {
        let response = try e.request("1802FF00", timeout: 8)
        guard let codes = Dtc.entries(from: response.bytes, module: module) else {
            t("Снимок до очистки \(module.title) не распознан: \(response)")
            return nil
        }
        let list = codes.isEmpty ? "ошибок нет" : codes.map { "\($0.code) [\($0.rawWord)]" }.joined(separator: ", ")
        t("Снимок до очистки \(module.title): \(list)")
        return codes
    }

    /// A KWP clear command can first return one or more 7F 14 78 (response pending)
    /// frames and then the actual 54 FF 00 acknowledgement in the same ELM exchange.
    private func clearAckOutcome(_ response: Response) -> (acknowledged: Bool, detail: String) {
        let bytes = response.bytes
        var pendingCount = 0
        var finalNegative: Int?
        var acknowledged = false
        if bytes.count >= 3 {
            for index in 0...(bytes.count - 3) {
                let a = bytes[index], b = bytes[index + 1], c = bytes[index + 2]
                if a == 0x7F && b == 0x14 && c == 0x78 { pendingCount += 1 }
                else if a == 0x7F && b == 0x14 { finalNegative = c }
                else if a == 0x54 && b == 0xFF && c == 0x00 { acknowledged = true }
            }
        }
        if acknowledged {
            let pending = pendingCount > 0 ? "; перед ним блок отложил ответ (7F 14 78 ×\(pendingCount))" : ""
            return (true, "подтверждено положительным ответом 54 FF 00\(pending)")
        }
        if let code = finalNegative {
            return (false, "блок отказал: 7F 14 \(hx(code))")
        }
        if pendingCount > 0 {
            return (false, "блок сообщил только 7F 14 78 (обработка ещё не подтверждена); итогового ответа нет")
        }
        return (false, "нет положительного подтверждения от блока (\(response))")
    }

    @discardableResult
    private func applyClearVerification(_ module: DtcModule, before: [DtcEntry]?, remaining: [DtcEntry]) -> String {
        let summary: String
        if remaining.isEmpty {
            summary = "Команда очистки подтверждена; после проверки ошибок нет."
        } else {
            let beforeWords = Set(before?.map(\.rawWord) ?? [])
            let codes = remaining.map(\.code).joined(separator: ", ")
            let alreadyPresent = remaining.filter { beforeWords.contains($0.rawWord) }.map(\.code)
            let firstObserved = remaining.filter { !beforeWords.contains($0.rawWord) }.map(\.code)
            var comparison = ""
            if before == nil {
                comparison = "; сравнение с исходным списком невозможно"
            } else {
                if !alreadyPresent.isEmpty {
                    comparison += "; совпадают с исходным списком: \(alreadyPresent.joined(separator: ", "))"
                }
                if !firstObserved.isEmpty {
                    comparison += "; в исходном списке не были получены: \(firstObserved.joined(separator: ", "))"
                }
                if comparison.isEmpty { comparison = "; коды отличаются от исходного списка" }
            }
            summary = "Очистка подтверждена, но после проверки обнаружены: \(codes)\(comparison)."
        }
        t("Проверка очистки \(module.title): \(summary)")
        updateModule(module) { $0.dtcState = .ok; $0.dtcText = summary; $0.codes = remaining }
        if module == .engine { setDtc(.ok, summary) }
        flushTraceFile()
        return summary
    }

    private func readDtcOnWorker(_ e: Elm, module: DtcModule) throws -> [DtcEntry]? {
        let response = try e.request("1802FF00", timeout: 8)
        if response.negative {
            let service = response.bytes.count > 1 ? hx(response.bytes[1]) : "??"
            let code = response.bytes.count > 2 ? hx(response.bytes[2]) : "??"
            moduleDtcFail(module, "блок отказал: 7F \(service) \(code)")
            return nil
        }
        guard let codes = Dtc.entries(from: response.bytes, module: module) else {
            moduleDtcFail(module, response.bytes.isEmpty
                ? "нет ответа от блока"
                : "неизвестный формат ответа: \(response)")
            return nil
        }
        let message = codes.isEmpty ? "Ошибок нет" : "Найдено ошибок: \(codes.count)"
        updateModule(module) { $0.dtcState = .ok; $0.dtcText = message; $0.codes = codes }
        if module == .engine { setDtc(.ok, message) }
        t("\(module.title): \(message)")
        return codes
    }

    private func moduleDtcFail(_ module: DtcModule, _ message: String) {
        t("ОШИБКА DTC \(module.title): \(message)")
        updateModule(module) { $0.dtcState = .fail; $0.dtcText = "Не удалось: \(message)" }
        if module == .engine { setDtc(.fail, "Не удалось: \(message)") }
    }

    // ---------- 3. logging ----------

    func stopLog() { running = false }

    func startLog(_ s: Settings, _ wanted: [Measurement]) {
        running = true
        setLog(true, "Запуск…")
        job({ msg in self.ecuFail(msg); self.running = false; self.setLog(false, "ошибка: \(msg)") }) {
            guard let e = self.elm, self.ecuOk else {
                self.running = false
                self.setLog(false, "сначала подключи ЭБУ")
                return
            }
            self.setLog(true, "Определение переменных (0x2C)…")
            let plan = try self.defineVariables(e, s, wanted)
            if plan.variables.count != wanted.count {
                let accepted = Set(plan.variables.map(\.name))
                let missing = wanted.filter { !accepted.contains($0.name) }.map(\.name)
                self.running = false
                self.t("ОШИБКА ЗАПИСИ: ЭБУ разрешил \(plan.variables.count) из \(wanted.count); не прочитаны: \(missing.joined(separator: ", "))")
                self.setLog(false, "ЭБУ принял \(plan.variables.count) из \(wanted.count) переменных; см. журнал")
                return
            }
            try self.logLoop(e, plan)
        }
    }

    private enum Mode: String { case ddli = "DDLI", rmba = "RMBA" }

    private struct MemorySpan {
        var address: Int
        var size: Int
    }

    private struct MemoryRegion {
        let address: Int
        let size: Int
        let position: Int
    }

    private struct ReadGroup {
        let lid: String
        let regions: [MemoryRegion]
        let byteCount: Int
    }

    private struct ReadPlan {
        let variables: [Measurement]
        let groups: [ReadGroup]
        let offsets: [String: Int]
        let mode: Mode
    }

    private func defineVariables(_ e: Elm, _ s: Settings, _ wanted: [Measurement]) throws -> ReadPlan {
        let byteLimit = min(max(s.maxBytes, 1), 0xFF)
        let sorted = wanted.sorted {
            if $0.address == $1.address { return $0.size < $1.size }
            return $0.address < $1.address
        }
        var spans: [MemorySpan] = []
        for measurement in sorted {
            guard measurement.size > 0, measurement.size <= byteLimit else {
                t("размер \(measurement.name) не помещается в один ответ 0x21")
                return try defineByMemory(e, wanted)
            }
            let end = measurement.address + measurement.size
            if let last = spans.indices.last {
                let currentEnd = spans[last].address + spans[last].size
                let mergedEnd = max(currentEnd, end)
                if measurement.address <= currentEnd && mergedEnd - spans[last].address <= byteLimit {
                    spans[last].size = mergedEnd - spans[last].address
                    continue
                }
            }
            spans.append(MemorySpan(address: measurement.address, size: measurement.size))
        }

        // These ME7 ECUs accept at most three memory regions in each dynamic local ID.
        // Adjacent variables are merged into one region before using another ID.
        let regionsPerLid = 3
        let maximumLids = 10
        var spanGroups: [[MemorySpan]] = []
        var currentGroup: [MemorySpan] = []
        var currentBytes = 0
        for span in spans {
            if currentGroup.count == regionsPerLid || currentBytes + span.size > byteLimit {
                spanGroups.append(currentGroup)
                currentGroup = []
                currentBytes = 0
            }
            currentGroup.append(span)
            currentBytes += span.size
        }
        if !currentGroup.isEmpty { spanGroups.append(currentGroup) }

        guard spanGroups.count <= maximumLids,
              let firstLid = Int(s.lid, radix: 16), firstLid + spanGroups.count - 1 <= 0xFF else {
            t("0x2C набрал слишком много разрозненных областей; перехожу на 0x23")
            return try defineByMemory(e, wanted)
        }

        var groups: [ReadGroup] = []
        var definitionFailed = false
        for (groupIndex, spanGroup) in spanGroups.enumerated() {
            let lid = String(format: "%02X", firstLid + groupIndex)
            let clear = try e.request("2C\(lid)04")
            guard clear.isPositive(0x2C) else {
                t("2C очистка LID \(lid): \(clear)")
                definitionFailed = true
                break
            }

            var regions: [MemoryRegion] = []
            var position = 1
            for span in spanGroup {
                guard position - 1 + span.size <= byteLimit else {
                    t("лимит \(byteLimit) байт для LID \(lid)")
                    definitionFailed = true
                    break
                }
                let response = try e.request("2C\(lid)03\(hx(position))\(hx(span.size))\(hx(span.address, 6))")
                guard response.isPositive(0x2C) else {
                    t("2C отказ для области 0x\(hx(span.address, 6)) размером \(span.size), LID \(lid): \(response)")
                    definitionFailed = true
                    break
                }
                regions.append(MemoryRegion(address: span.address, size: span.size, position: position))
                position += span.size
            }
            if definitionFailed { break }
            groups.append(ReadGroup(lid: lid, regions: regions, byteCount: position - 1))
        }

        if !definitionFailed {
            var offsets: [String: Int] = [:]
            var groupOffset = 0
            for group in groups {
                for measurement in wanted {
                    guard let region = group.regions.first(where: {
                        measurement.address >= $0.address && measurement.address + measurement.size <= $0.address + $0.size
                    }) else { continue }
                    offsets[measurement.name] = groupOffset + region.position - 1 + measurement.address - region.address
                }
                groupOffset += group.byteCount
            }
            if offsets.count == wanted.count {
                return ReadPlan(variables: wanted, groups: groups, offsets: offsets, mode: .ddli)
            }
            t("0x2C не сопоставил все выбранные переменные; пробую 0x23")
        }

        return try defineByMemory(e, wanted)
    }

    private func defineByMemory(_ e: Elm, _ wanted: [Measurement]) throws -> ReadPlan {
        setLog(true, "0x2C не принят полностью, пробую 0x23 (медленнее)…")
        var variables: [Measurement] = []
        var offsets: [String: Int] = [:]
        var position = 0
        for measurement in wanted {
            let response = try e.request("23\(hx(measurement.address, 6))\(hx(measurement.size))")
            if response.isPositive(0x23) && response.bytes.count >= 1 + measurement.size {
                offsets[measurement.name] = position
                position += measurement.size
                variables.append(measurement)
            } else {
                t("23 отказ для \(measurement.name): \(response)")
            }
        }
        return ReadPlan(variables: variables, groups: [], offsets: offsets, mode: .rmba)
    }

    private func logLoop(_ e: Elm, _ plan: ReadPlan) throws {
        let vars = plan.variables
        let st = stamp()
        let csv = openOutput("me7_\(st).csv")
        func w(_ line: String) { if let d = line.data(using: .utf8) { csv?.write(d) } }
        let actualPressure = vars.firstIndex { ["pvdkds_w", "pvdks_w"].contains($0.name) }
        let requestedPressure = vars.firstIndex { ["plsol", "plsol_w"].contains($0.name) }
        let ambientPressure = vars.firstIndex { ["pu_w", "pus_w"].contains($0.name) }
        let hasActualBoost = actualPressure != nil && ambientPressure != nil
        let hasRequestedBoost = requestedPressure != nil && ambientPressure != nil
        var extraNames: [String] = []
        var extraUnits: [String] = []
        if hasActualBoost { extraNames.append("boost_actual_gauge"); extraUnits.append("mbar(g)") }
        if hasRequestedBoost { extraNames.append("boost_target_gauge"); extraUnits.append("mbar(g)") }
        w("TimeStamp," + (vars.map { $0.name } + extraNames).joined(separator: ",") + "\n")
        w("s," + (vars.map { $0.displayUnit } + extraUnits).joined(separator: ",") + "\n")
        let modeText: String
        switch plan.mode {
        case .ddli: modeText = "DDLI · \(plan.groups.count) блока"
        case .rmba: modeText = "RMBA"
        }
        setLog(true, "Запись: \(vars.count) перем., режим \(modeText) → ME7Logs/me7_\(st).csv")
        var values = [Double](repeating: 0, count: vars.count)
        let t0 = Date()
        var samples = 0
        var fails = 0
        var lastUi = Date.distantPast
        var hzT = Date()
        var hzN = 0
        var hz = 0.0
        var reason = "остановлено, записано"
        defer {
            running = false
            try? csv?.close()
            t("записано \(samples) замеров")
            setLog(false, "\(reason) \(samples) замеров → ME7Logs/me7_\(st).csv")
        }
        while running {
            var data: [UInt8]? = nil
            switch plan.mode {
            case .ddli:
                var buffer: [UInt8] = []
                var good = true
                for group in plan.groups {
                    let response = try e.request("21\(group.lid)", timeout: 1.5)
                    if response.isPositive(0x21) && response.bytes.count >= 2 + group.byteCount {
                        buffer += response.bytes[2..<(2 + group.byteCount)].map { UInt8($0) }
                    } else {
                        t("21 LID \(group.lid): \(response)")
                        good = false
                        break
                    }
                }
                if good { data = buffer }
            case .rmba:
                var buf: [UInt8] = []
                var good = true
                for m in vars {
                    let r = try e.request("23\(hx(m.address, 6))\(hx(m.size))", timeout: 1.5)
                    if r.isPositive(0x23) && r.bytes.count >= 1 + m.size {
                        buf += r.bytes[1...m.size].map { UInt8($0) }
                    } else {
                        good = false; t("23 \(m.name): \(r)"); break
                    }
                }
                if good { data = buf }
            }
            guard let d = data else {
                fails += 1
                if fails >= 5 {
                    reason = "связь с блоком потеряна, записано"
                    ecuFail("связь потеряна: 5 ошибок чтения подряд")
                    break
                }
                continue
            }
            fails = 0
            var validOffsets = true
            for i in vars.indices {
                guard let offset = plan.offsets[vars[i].name], offset + vars[i].size <= d.count else {
                    t("нет байтов для \(vars[i].name) в ответе")
                    validOffsets = false
                    break
                }
                values[i] = vars[i].convert(d, offset)
            }
            if !validOffsets {
                fails += 1
                if fails >= 5 {
                    reason = "неполный ответ ЭБУ, записано"
                    ecuFail("ответ не содержит данные всех выбранных переменных")
                    break
                }
                continue
            }

            var outputValues = values
            var derivedLive: [LiveValue] = []
            if let actualPressure, let ambientPressure {
                let value = values[actualPressure] - values[ambientPressure]
                outputValues.append(value)
                derivedLive.append(LiveValue(id: "boost_actual_gauge", label: "Наддув фактический · избыточный", value: value, unit: "mbar"))
            }
            if let requestedPressure, let ambientPressure {
                let value = values[requestedPressure] - values[ambientPressure]
                outputValues.append(value)
                derivedLive.append(LiveValue(id: "boost_target_gauge", label: "Наддув заданный · избыточный", value: value, unit: "mbar"))
            }
            w(String(format: "%.3f", Date().timeIntervalSince(t0)) + outputValues.map { "," + fmt($0) }.joined() + "\n")
            samples += 1
            hzN += 1
            let now = Date()
            if now.timeIntervalSince(hzT) > 1 { hz = Double(hzN) / now.timeIntervalSince(hzT); hzT = now; hzN = 0 }
            if now.timeIntervalSince(lastUi) > 0.15 {
                lastUi = now
                var snap = vars.indices.map { index in
                    LiveValue(id: vars[index].name, label: vars[index].displayName, value: values[index], unit: vars[index].displayUnit)
                }
                snap += derivedLive
                let h = hz
                ui { self.live = snap; self.hz = h }
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e9 { return String(Int64(v)) }
        return String(format: "%.4f", v)
    }
}
