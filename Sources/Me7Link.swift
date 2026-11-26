import Combine
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

struct AddressFinding: Identifiable {
    struct ID: Hashable {
        let address: Int
        let can: Bool
    }
    let id: ID
    let route: SweepRoute
    let detail: String
    let hasIdentity: Bool
    let module: DtcModule?
}

struct AddressSweepReport {
    enum Phase { case idle, running, paused, completed, failed }
    var phase = Phase.idle
    var status = "Поиск ещё не запускался"
    var position = 0
    var skipped = 0
    var kLineAddresses: Set<Int> = []
    var tp20Addresses: Set<Int> = []
    var tp16Addresses: Set<Int> = []
    var attemptedAddresses: Int { kLineAddresses.union(tp20Addresses).union(tp16Addresses).count }
    var findings: [AddressFinding] = []
}

private struct SweepCheckpoint {
    var report = AddressSweepReport()
    var unsupportedRates: Set<SweepRate> = []
    var unsupportedCAN: Set<SweepRoute.Mode> = []
}

struct LiveValue: Identifiable {
    let id: String
    let label: String
    let value: Double
    let unit: String
}

private struct MAFPairReading {
    let response: Response

    var isPositive: Bool { response.bytes.count >= 7 && response.bytes[0] == 0x41 && response.bytes[1] == 0x66 }
    var supportsA: Bool { isPositive && (response.bytes[2] & 0x01) != 0 }
    var supportsB: Bool { isPositive && (response.bytes[2] & 0x02) != 0 }
    var flowA: Double? {
        guard supportsA else { return nil }
        return Double((response.bytes[3] << 8) | response.bytes[4]) / 32.0
    }
    var flowB: Double? {
        guard supportsB else { return nil }
        return Double((response.bytes[5] << 8) | response.bytes[6]) / 32.0
    }
    var supportsAny: Bool { supportsA || supportsB }
}

/// ATAL: K-line messages longer than 7 data bytes (0x21 block, DTC list).
/// ATST FF: wait up to ~1 s for a reply (default 0x64 ≈ 400 ms cuts off slow KWP ECUs:
/// in the traces a silent address was declared NO DATA already after ~613 ms).
private let baseSetup = ["ATE0", "ATL0", "ATS0", "ATH0", "ATAL", "ATAT1", "ATSTFF", "ATKW0"]

/// ME7 over ELM327 K-line, in three separate steps so it is clear which one fails:
///  1. connectElm  TCP to the Wi-Fi adapter + AT setup
///  2. select the engine in Errors and open its diagnostic session
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
    @Published private(set) var addressSweep = AddressSweepReport()
    // Only the ELM worker accesses the checkpoint, scoped to its current TCP connection.
    private var pausedSweep: SweepCheckpoint?
    /// Blocks that provably answered during this ELM connection (scan or direct connect).
    /// Shown on the errors screen next to the four base modules.
    @Published var discovered: Set<DtcModule> = []
    @Published var traceFileURL: URL?
    @Published var logging = false
    @Published var logText = ""
    @Published var mafProbeState = LinkState.idle
    @Published var mafProbeText = "Проверка ещё не запускалась"
    @Published var live: [LiveValue] = []
    @Published var hz = 0.0
    @Published var trace: [String] = []

    private let worker = DispatchQueue(label: "me7.link")
    private let traceFileLock = NSLock()
    private var elm: Elm?
    private var traceFile: FileHandle?
    private var ecuOk = false
    private var activeModule: DtcModule?
    private var lastSettings: Settings?
    /// Link variant that worked for each module during this ELM connection; tried first next time.
    private var workingLinks: [DtcModule: Link] = [:]
    private let flagLock = NSLock()
    private let clearAllLock = NSLock()
    private let blockScanLock = NSLock()
    private var clearAllIsQueuedOrRunning = false
    private var blockScanIsQueuedOrRunning = false
    private var blockScanStopRequested = false
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

    /// Blocks offered for the mass clear: everything that answered during this connection,
    /// or just the four base blocks until the first scan/connection finds anything.
    var clearableModules: [DtcModule] {
        let found = DtcModule.allCases.filter { discovered.contains($0) }
        return found.isEmpty ? DtcModule.allCases.filter(\.isBase) : found
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

    func connectElm(_ s: Settings) {
        guard elmState == .idle || elmState == .fail else { return }
        elmState = .busy
        elmText = "Подключение к \(s.host):\(s.port)…"
        addressSweep = AddressSweepReport()
        ui {
            self.trace.removeAll()
            // New connection = fresh vehicle state: found blocks and scan results reset,
            // so the next full scan checks every address again.
            self.discovered.removeAll()
            self.blockScanResults = []
            self.blockScanState = .idle
            self.blockScanStatus = "Полный опрос ещё не запускался"
            self.blockScanProgress = 0
            self.blockScanTotal = 0
        }
        job({ self.elmFail($0) }) {
            self.lastSettings = s
            self.pausedSweep = nil
            self.workingLinks.removeAll()
            self.closeAll()
            self.resetModules("Ожидание подключения")
            self.setEcu(.idle, "НЕ ПОДКЛЮЧЕНО")
            self.traceFile = self.openOutput("me7_\(self.stamp())_trace.txt")
            self.t("=== ELM \(s.host):\(s.port) ===")
            let e = Elm(trace: { [weak self] in self?.t($0) }, onClosed: { [weak self] adapter in
                self?.worker.async { [weak self] in
                    guard let self, self.elm === adapter else { return }
                    self.elmFail("связь с адаптером потеряна")
                }
            })
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
        guard elmState == .ok else { return }
        elmState = .busy
        elmText = "Отключение от ELM327…"
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
    private struct Link: Equatable {
        /// "5" = KWP fast init; "4" = 5-бод 10400, неявный init первым запросом;
        /// "4A" = 5-бод 10400 с явным ATSI; "4L" = 5-бод 9600 (ATIB96);
        /// "T20"/"T16" = VW TP2.0/TP1.6 по CAN (как Abrites/PoCOM для Cayenne 95x).
        let proto: String
        let initAddress: String
        let header: String
        var rate: SweepRate = .standard
        var label: String {
            switch proto {
            case "5": return "fast init \(header.dropFirst(2).prefix(2)) · \(rate.rawValue) бод"
            case "4A": return "5 бод 0x\(initAddress) · явный ATSI"
            case "4L": return "5 бод 0x\(initAddress) · 9600 бод"
            case "T20": return "VW TP2.0 · CAN · 0x\(initAddress)"
            case "T16": return "VW TP1.6 · CAN · 0x\(initAddress)"
            default: return "5 бод 0x\(initAddress) · \(rate.rawValue) бод"
            }
        }
    }

    /// One link variant with retries: the cheap ELM clone regularly flunks the 5-baud init
    /// (BUS INIT: ...OK followed by silence, or BUS INIT: ERROR), so a failing variant is
    /// re-attempted after ATPC + a pause instead of being written off on the first try.
    /// Returns (accepted session, "") or (nil, short reason of the last failure).
    private func openLink(_ e: Elm, _ link: Link, sessions: [String], slowAttempts: Int) throws -> (String?, String) {
        let attempts: Int
        switch link.proto {
        case "5": attempts = 2
        case "4A", "4L": attempts = min(2, max(1, slowAttempts))
        case "T20", "T16": attempts = 1
        default: attempts = max(1, slowAttempts)
        }
        var lastError = "нет ответа"
        for attempt in 1...attempts {
            t(attempts > 1
                ? "--- попытка \(attempt)/\(attempts): \(link.label), заголовок \(link.header) ---"
                : "--- попытка: \(link.label), заголовок \(link.header) ---")
            if link.proto == "T20" || link.proto == "T16" {
                guard let target = Int(link.initAddress, radix: 16) else { return (nil, "некорректный адрес TP") }
                let opened = link.proto == "T20" ? try e.connectTP20(target: target) : try e.connectTP16(target: target)
                guard opened.connected else {
                    lastError = opened.reason
                    continue
                }
                let (session, error) = try startSession(e, sessions)
                if let session = session { return (session, "") }
                lastError = error
                e.disconnectTP16()
                continue
            }
            try e.prepareKwpMode()
            _ = try e.cmd("ATSP\(link.proto.prefix(1))")
            if link.proto.hasPrefix("4") { _ = try e.cmd("ATIIA\(link.initAddress)") }
            let rate: SweepRate = link.proto == "4L" ? .low : link.rate
            if rate != .standard {
                guard try e.cmd(rate.command).uppercased() == "OK" else { return (nil, "ELM не подтвердил \(rate.rawValue) бод") }
            }
            _ = try e.cmd("ATSH\(link.header)")
            _ = try e.cmd("ATWM\(link.header)3E")
            if link.proto == "4A" {
                // Явная 5-бод инициализация: на части клонов ATSI проходит стабильнее,
                // чем неявный init на первом кадре данных.
                let initReply = try e.cmd("ATSI", timeout: 10)
                let upper = initReply.uppercased()
                guard upper.contains("BUS INIT"), upper.contains("OK"), !upper.contains("ERROR") else {
                    lastError = "ATSI: \(initReply.isEmpty ? "нет ответа" : initReply)"
                    if attempt < attempts {
                        _ = try e.cmd("ATPC")
                        Thread.sleep(forTimeInterval: 0.8)
                    }
                    continue
                }
            }
            let (session, error) = try startSession(e, sessions)
            if let session = session { return (session, "") }
            lastError = error
            if attempt < attempts {
                _ = try e.cmd("ATPC")
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        return (nil, lastError)
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
        for link in [Link(proto: "5", initAddress: "", header: "8110F1"),
                     Link(proto: "5", initAddress: "", header: "8101F1"),
                     // Abrites перебирает для ME7.x 5-бод адреса 0x01 и 0x11 — добавляем оба как запасной путь
                     Link(proto: "4", initAddress: "01", header: "8101F1"),
                     Link(proto: "4", initAddress: "11", header: "8111F1")]
        where !links.contains(where: { $0.proto == link.proto && $0.header == link.header }) {
            links.append(link)
        }
        if let known = workingLinks[.engine] {
            links.removeAll { $0 == known }
            links.insert(known, at: 0)
        }
        let sessions = s.sessions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var results: [String] = []
        for link in links {
            setEcu(.busy, (["Инициализация: \(link.label)…"] + results).joined(separator: "\n"))
            // The engine answers fast init reliably on this car, so slow-init retries stay few.
            let (session, error) = try openLink(e, link, sessions: sessions, slowAttempts: 2)
            if let session = session {
                ecuOk = true
                activeModule = .engine
                workingLinks[.engine] = link
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
        let target = module == .absEsp ? hx(DtcModule.mk25PhysicalAddress) : module.target
        updateModule(module) {
            $0.connectionState = .busy
            $0.connectionText = "Подключение к блоку 0x\(target)…"
            $0.softwareNumber = "Чтение…"
            $0.dtcState = .idle
            $0.dtcText = "Ошибки не прочитаны"
            $0.codes = []
        }
        t("=== подключение: \(module.title), адрес 0x\(target) ===")

        if module == .absEsp {
            let frames = try e.fastInitIdentification(header: "81\(target)F1")
            guard frames.contains(where: { frame in
                frame.bytes.starts(with: [0x5A, 0x9B]) &&
                    Dtc.identifyModule(Array(frame.bytes.dropFirst(2))) == .absEsp
            }) else {
                let reply = frames.map(\.description).joined(separator: " · ")
                moduleConnectionFail(module, "MK25 на 0x\(target) не подтвердил номер блока. 1A9B → \(reply.isEmpty ? "нет ответа" : reply)")
                return false
            }
            activeModule = module
            ui { _ = self.discovered.insert(module) }
            let status = "Подключено · K-line fast init 0x\(target)"
            updateModule(module) {
                $0.connectionState = .ok
                $0.connectionText = status
                $0.softwareNumber = "7L0 907 379 C"
            }
            t("\(module.title): \(status) · 7L0 907 379 C")
            return true
        }

        var links = module.fastInitTargets.map { Link(proto: "5", initAddress: "", header: "81\(hx($0))F1") }
        links.append(Link(proto: "4", initAddress: target, header: "81\(target)F1"))
        links.append(Link(proto: "4A", initAddress: target, header: "81\(target)F1"))
        links.append(Link(proto: "4L", initAddress: target, header: "81\(target)F1"))
        links.append(Link(proto: "T20", initAddress: target, header: ""))
        links.append(Link(proto: "T16", initAddress: target, header: ""))
        if let known = workingLinks[module] {
            links.removeAll { $0 == known }
            links.insert(known, at: 0)
        }
        var failures: [String] = []
        for link in links {
            // The clone often needs several 5-baud attempts before the init sticks
            // (Вася/VCDS proves these blocks answer on the very same K-line).
            let (session, error) = try openLink(e, link, sessions: module.sessions, slowAttempts: 5)
            if let session = session {
                activeModule = module
                workingLinks[module] = link
                ui { _ = self.discovered.insert(module) }
                let status = "Подключено · \(link.label) · сессия \(session)"
                updateModule(module) { $0.connectionState = .ok; $0.connectionText = status }
                t("\(module.title): подключено, \(status)")
                try readSoftwareNumber(e, module: module)
                return true
            }
            failures.append("\(link.label): \(error)")
        }

        var message = failures.joined(separator: "\n")
        if let hint = module.protocolHint { message += "\n\(hint)" }
        message += "\nПроверь питание блока и диагностическую линию (контакты 3/7 OBD)."
        moduleConnectionFail(module, message)
        return false
    }

    func noteBlockScanScreenOpened() {
        t("=== открыт экран теста блоков ===")
    }

    func scanAllBlocks(_ s: Settings) {
        guard beginBlockScan() else { return }
        let targets = BlockScanTarget.cayenne955
        // Blocks that already answered during this ELM connection are kept as-is and
        // skipped: re-probing them wastes minutes and can disturb open sessions.
        let previousByAddress = Dictionary(uniqueKeysWithValues: self.blockScanResults.map { ($0.target.address, $0) })
        let pending = targets.filter { previousByAddress[$0.address]?.responded != true }
        let skipped = targets.count - pending.count
        let plannedChecks = pending.reduce(0) { count, target in
            count + target.fastInitTargets.count + 3
        }
        ui {
            self.blockScanState = .busy
            self.blockScanStatus = "Подготовка опроса по профилю Touareg 7L…"
            self.blockScanProgress = 0
            self.blockScanTotal = plannedChecks
            self.blockScanResults = targets.map { previousByAddress[$0.address] ?? BlockScanResult(target: $0) }
        }
        job({ message in
            self.ui {
                self.blockScanState = .fail
                self.blockScanStatus = "Сканирование прервано: \(message)"
            }
        }) {
            defer { self.endBlockScan() }
            self.t("=== ТЕСТ БЛОКОВ · профиль адресов Touareg 7L / проверяемый автомобиль Cayenne 955 ===")
            self.t("ELM: \(s.host):\(s.port)")
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

            let total = plannedChecks
            var progress = 0
            var results = targets.map { previousByAddress[$0.address] ?? BlockScanResult(target: $0) }
            self.t("Кандидатов адресов: \(targets.count); к опросу: \(pending.count); пропущено как уже найденные: \(skipped); проверок транспорта и сценариев подключения: \(total)")
            self.t("Адреса: \(targets.map { "0x\($0.addressText) \($0.title)" }.joined(separator: "; "))")
            self.t("Проверки только читающие: KWP2000 по K-line (fast init, 5-бод 10400 с повторами, 5-бод 9600), затем VW TP2.0/TP1.6 по CAN — набор путей как у Abrites/PoCOM. Ошибки не стираются, кодирование и исполнительные тесты не запускаются. Адрес, ответивший хотя бы раз, из дальнейших проверок убирается.")

            for index in targets.indices {
                if self.shouldStopBlockScan { break }
                let target = targets[index]
                let alreadyResponded = previousByAddress[target.address]?.responded == true
                let plannedForTarget = alreadyResponded ? 0
                    : target.fastInitTargets.count + 3
                let progressBeforeTarget = progress
                if alreadyResponded {
                    self.t("=== адрес 0x\(target.addressText): \(target.title) — уже отвечал в этом подключении, пропускаю ===")
                    continue
                }
                self.t("=== адрес 0x\(target.addressText): \(target.title) ===")

                /// Runs one probe and reports it. Returns the outcome so the caller can stop
                /// checking this address as soon as anything answered.
                @discardableResult
                func record(_ label: String, run: () throws -> BlockScanAttempt) throws -> BlockScanAttemptState? {
                    if self.shouldStopBlockScan { return nil }
                    progress += 1
                    let currentProgress = progress
                    let currentStatus = "\(currentProgress)/\(total) · 0x\(target.addressText) \(target.title) · \(label)"
                    self.ui {
                        self.blockScanProgress = currentProgress
                        self.blockScanStatus = currentStatus
                    }
                    self.t("--- ПРОБА \(label), адрес 0x\(target.addressText) ---")
                    let attempt = try run()
                    results[index].attempts.append(attempt)
                    let stateText: String
                    switch attempt.state {
                    case .responded: stateText = "ОТВЕТИЛ"
                    case .unverifiedResponse: stateText = "ОТВЕТИЛ, НО БЛОК НЕ ИДЕНТИФИЦИРОВАН"
                    case .negativeResponse: stateText = "ОТВЕТИЛ ОТКАЗОМ НА СЕРВИС"
                    case .channelOnly: stateText = "КАНАЛ ОТКРЫТ, KWP МОЛЧИТ"
                    case .noResponse: stateText = "НЕТ ОТВЕТА"
                    }
                    self.t("ИТОГ 0x\(target.addressText) · \(label): \(stateText) · \(attempt.detail)")
                    if attempt.state == .responded, let module = DtcModule.module(forAddress: target.address) {
                        self.ui { _ = self.discovered.insert(module) }
                        self.updateModule(module) {
                            $0.connectionText = "Найден при полном опросе · \(label)"
                            $0.softwareNumber = attempt.detail
                        }
                        self.t("Блок 0x\(target.addressText) добавлен на экран ошибок как «\(module.title)»; дальнейшие проверки этого адреса не нужны")
                    }
                    let snapshot = results
                    self.ui { self.blockScanResults = snapshot }
                    self.flushTraceFile()
                    return attempt.state
                }

                var answered = false
                for physicalAddress in target.fastInitTargets where !answered {
                    let physicalText = String(format: "%02X", physicalAddress)
                    let header = "81\(physicalText)F1"
                    let mode = "KWP fast init · физический адрес 0x\(physicalText)"
                    answered = try record(mode) {
                        var probe: (response: Response?, negativeResponse: Response?, state: BlockScanAttemptState, detail: String)!
                        for fastAttempt in 1...2 {
                            try e.prepareBlockScanKwpMode()
                            _ = try e.cmd("ATSP5")
                            _ = try e.cmd("ATSH\(header)")
                            _ = try e.cmd("ATWM\(header)3E")
                            probe = try self.probeBlockKwp(e)
                            if probe.state != .noResponse { break }
                            if fastAttempt < 2, !self.shouldStopBlockScan {
                                self.t("Проба 0x\(physicalText): блок молчит после fast init, повторяю (попытка 2/2)")
                                _ = try e.cmd("ATPC")
                                Thread.sleep(forTimeInterval: 0.5)
                            }
                        }
                        if probe.state == .responded, let module = DtcModule.module(forAddress: target.address) {
                            self.workingLinks[module] = Link(proto: "5", initAddress: "", header: header)
                        }
                        return BlockScanAttempt(mode: mode, state: probe.state, detail: probe.detail)
                    } == .responded
                }

                if !answered {
                    let header = "81\(target.addressText)F1"
                    answered = try record("KWP slow init · K-Line 5 бод") {
                        var probe: (response: Response?, negativeResponse: Response?, state: BlockScanAttemptState, detail: String)!
                        for slowAttempt in 1...3 {
                            try e.prepareBlockScanKwpMode()
                            _ = try e.cmd("ATSP4")
                            _ = try e.cmd("ATIIA\(target.addressText)")
                            _ = try e.cmd("ATSH\(header)")
                            _ = try e.cmd("ATWM\(header)3E")
                            probe = try self.probeBlockKwp(e)
                            if probe.state != .noResponse { break }
                            if slowAttempt < 3, !self.shouldStopBlockScan {
                                self.t("Повтор slow init 0x\(target.addressText) (попытка \(slowAttempt + 1)/3) — клон ELM нестабилен на 5-бод инициализации")
                                _ = try e.cmd("ATPC")
                                Thread.sleep(forTimeInterval: 0.8)
                            }
                        }
                        if probe.state == .responded, let module = DtcModule.module(forAddress: target.address) {
                            self.workingLinks[module] = Link(proto: "4", initAddress: target.addressText, header: header)
                        }
                        return BlockScanAttempt(mode: "KWP slow init · K-Line 5 бод", state: probe.state, detail: probe.detail)
                    } == .responded
                }

                if !answered {
                    let header = "81\(target.addressText)F1"
                    answered = try record("KWP slow init · 5 бод · 9600 бод") {
                        // Abrites перебирает 10427 и 9600 бод: часть блоков 95x живёт на 9600,
                        // а после неудачного 10400 уже не просыпается — поэтому отдельная проба.
                        try e.prepareBlockScanKwpMode()
                        _ = try e.cmd("ATSP4")
                        _ = try e.cmd("ATIB96")
                        _ = try e.cmd("ATIIA\(target.addressText)")
                        _ = try e.cmd("ATSH\(header)")
                        _ = try e.cmd("ATWM\(header)3E")
                        let probe = try self.probeBlockKwp(e)
                        _ = try e.cmd("ATIB10")
                        if probe.state == .responded, let module = DtcModule.module(forAddress: target.address) {
                            self.workingLinks[module] = Link(proto: "4L", initAddress: target.addressText, header: header)
                        }
                        return BlockScanAttempt(mode: "KWP slow init · 5 бод · 9600 бод", state: probe.state, detail: probe.detail)
                    } == .responded
                }

                if !answered {
                    answered = try record("VW TP2.0 / TP1.6 · CAN") {
                        // PoCOM держит для блоков 95x варианты VW TP 1.6 — пробуем открыть
                        // диагностический CAN-канал; если открылся, KWP-идентификация идёт по нему.
                        var tpProto = "T20"
                        var opened = try e.connectTP20(target: target.address)
                        let tp20Reason = opened.reason
                        var tp16Reason = ""
                        if !opened.connected {
                            tpProto = "T16"
                            opened = try e.connectTP16(target: target.address)
                            tp16Reason = opened.reason
                        }
                        guard opened.connected else {
                            return BlockScanAttempt(mode: "VW TP2.0 / TP1.6 · CAN", state: .noResponse,
                                                    detail: "CAN-канал не открыт · TP2.0: \(tp20Reason); TP1.6: \(tp16Reason)")
                        }
                        let probe = try self.probeBlockKwp(e)
                        if probe.state == .responded, let module = DtcModule.module(forAddress: target.address) {
                            self.workingLinks[module] = Link(proto: tpProto, initAddress: target.addressText, header: "")
                        }
                        e.disconnectTP16()
                        let state: BlockScanAttemptState = probe.state == .noResponse ? .channelOnly : probe.state
                        return BlockScanAttempt(mode: "VW TP2.0 / TP1.6 · CAN", state: state,
                                                detail: "\(tpProto == "T20" ? "TP2.0" : "TP1.6"): \(probe.detail)")
                    } == .responded
                }

                // Probes skipped after an early answer still count toward the planned total,
                // otherwise the progress bar stalls below 100% on a successful scan.
                let leftover = plannedForTarget - (progress - progressBeforeTarget)
                if leftover > 0, !self.shouldStopBlockScan { progress += leftover }
            }

            let replied = results.filter(\.responded).count
            let unverified = results.filter { !$0.responded && $0.hasUnverifiedResponse }.count
            let negative = results.filter { !$0.responded && !$0.hasUnverifiedResponse && $0.receivedNegativeResponse }.count
            let stopped = self.shouldStopBlockScan
            let summary = stopped
                ? "Остановлено пользователем: \(progress)/\(total) проверок; блоки с ID \(replied), отклик без ID \(unverified), отказали в сервисе \(negative); без повторного опроса найденных ранее: \(skipped)."
                : "Завершено: блоки с подтверждённым ID \(replied), отклик без ID \(unverified), отказали в сервисе \(negative); без повторного опроса найденных ранее: \(skipped)."
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

    func findRespondingAddresses() {
        guard elmState == .ok, !running, clearAllState != .busy,
              blockScanState != .busy, beginBlockScan() else { return }
        let resume = addressSweep.phase == .paused
        if !resume { addressSweep = AddressSweepReport() }
        addressSweep.phase = .running
        addressSweep.status = "Подготовка адаптера…"
        blockScanState = .busy
        worker.async {
            var scan = resume ? self.pausedSweep ?? SweepCheckpoint() : SweepCheckpoint()
            self.pausedSweep = nil
            let adapter = self.elm
            defer {
                adapter?.finishIdentitySweep()
                self.flushTraceFile()
                self.endBlockScan()
                let finalReport = scan.report
                self.ui {
                    self.addressSweep = finalReport
                    self.blockScanState = finalReport.phase == .failed ? .fail : .idle
                }
            }
            guard let adapter else {
                scan.report.phase = .failed
                scan.report.status = "Соединение с ELM327 потеряно"
                return
            }
            if let previous = self.activeModule {
                self.updateModule(previous) { $0.connectionState = .idle; $0.connectionText = "Сеанс закрыт для поиска адресов" }
            }
            self.activeModule = nil
            self.ecuOk = false
            self.setEcu(.idle, "Выполняется поиск адресов")
            self.t("=== ПОИСК ОТВЕЧАЮЩИХ АДРЕСОВ · маршрут \(scan.report.position + 1) из \(SweepRoute.plan.count) ===")
            do {
                try self.runAddressSweep(adapter, scan: &scan)
                let complete = scan.report.position == SweepRoute.plan.count
                scan.report.phase = complete ? .completed : .paused
                let identified = scan.report.findings.filter(\.hasIdentity).count
                scan.report.status = "\(complete ? "Завершено" : "Приостановлено") · откликов по адресам и шинам: \(scan.report.findings.count), из них с ID: \(identified)."
                if !complete { self.pausedSweep = scan }
            } catch {
                scan.report.phase = .failed
                scan.report.status = "Поиск прерван: \(error). Полученные ответы сохранены."
                if case ElmError.closed = error { self.elmFail("связь с адаптером потеряна") }
            }
            self.t("\(scan.report.status) · \(scan.report.position)/\(SweepRoute.plan.count), пропущено: \(scan.report.skipped)")
        }
    }

    private func runAddressSweep(_ adapter: Elm, scan: inout SweepCheckpoint) throws {
        let plan = SweepRoute.plan
        while scan.report.position < plan.count && !shouldStopBlockScan {
            let route = plan[scan.report.position]
            let unsupported = route.rate.map { scan.unsupportedRates.contains($0) } ?? scan.unsupportedCAN.contains(route.mode)
            if unsupported {
                scan.report.skipped += 1
                scan.report.position += 1
                continue
            }
            scan.report.phase = .running
            scan.report.status = route.label
            let progress = scan.report
            ui { self.addressSweep = progress }
            t("--- Поиск \(scan.report.position + 1)/\(plan.count) · \(route.label) ---")
            let reply = try adapter.probeIdentity(on: route, stopped: { self.shouldStopBlockScan })
            if let rate = reply.unsupportedRate { scan.unsupportedRates.insert(rate) }
            if reply.unsupportedCAN { scan.unsupportedCAN.insert(route.mode) }
            if let issue = reply.setupIssue { t("Маршрут не проверен · \(issue)") }
            if reply.attempted {
                switch route.mode {
                case .fast, .slow: scan.report.kLineAddresses.insert(route.address)
                case .tp20: scan.report.tp20Addresses.insert(route.address)
                case .tp16: scan.report.tp16Addresses.insert(route.address)
                }
            }
            recordAddressReply(reply, on: route, report: &scan.report)
            // A stop between two identification requests leaves this route first on resume.
            if shouldStopBlockScan { break }
            if !reply.attempted || reply.setupIssue != nil {
                scan.report.skipped += 1
            }
            scan.report.position += 1
        }
    }

    private func recordAddressReply(_ reply: SweepReply, on route: SweepRoute, report: inout AddressSweepReport) {
        guard let detail = reply.identifier ?? reply.evidence else { return }
        let module = reply.module
        let description = module.map { "\($0.title) · \(detail)" } ?? detail
        let id = AddressFinding.ID(address: route.address, can: route.rate == nil)
        let finding = AddressFinding(id: id, route: route, detail: description, hasIdentity: reply.payload != nil, module: module)
        t("Отклик · \(route.label) · \(description)")
        if let index = report.findings.firstIndex(where: { $0.id == id }) {
            let previous = report.findings[index]
            if (finding.hasIdentity && !previous.hasIdentity) || (module != nil && previous.module == nil) {
                report.findings[index] = finding
            }
        } else {
            report.findings.append(finding)
        }
        guard let module, workingLinks[module] == nil else { return }
        let link: Link
        switch route.mode {
        case .fast(let rate): link = Link(proto: "5", initAddress: "", header: route.header, rate: rate)
        case .slow(let rate, let initByte): link = Link(proto: "4", initAddress: hx(initByte), header: route.header, rate: rate)
        case .tp20: link = Link(proto: "T20", initAddress: hx(route.address), header: "")
        case .tp16: link = Link(proto: "T16", initAddress: hx(route.address), header: "")
        }
        workingLinks[module] = link
        ui { _ = self.discovered.insert(module) }
        updateModule(module) {
            $0.softwareNumber = detail
            $0.connectionText = "Найден при поиске · \(route.label)"
        }
    }

    private func probeBlockKwp(_ e: Elm) throws -> (response: Response?, negativeResponse: Response?, state: BlockScanAttemptState, detail: String) {
        var observations: [String] = []
        var negativeResponses: [Response] = []
        var sawUnverifiedResponse = false
        // A 5-baud init takes ~3 s on the ELM side; a request sent while the init is still
        // running aborts it (STOPPED), so every probe gets a generous ceiling. Timeouts only
        // cap the wait — a fast answer still returns immediately. If the first request shows
        // BUS INIT: ERROR, the address is dead and the rest would just re-run the same init.
        var busDead = false

        func busInitFailed(_ frames: [Response]) -> Bool {
            !frames.isEmpty && frames.allSatisfy { frame in
                frame.bytes.isEmpty && frame.errors.contains { $0.uppercased().hasPrefix("BUS INIT") }
            }
        }

        func readIdentity(_ identifier: String) throws -> String? {
            if busDead { return nil }
            for attempt in 1...2 {
                let frames = try e.requestFramesForBlockScan(identifier, timeout: 6)
                if busInitFailed(frames) {
                    busDead = true
                    observations.append("\(identifier): инициализация K-line не удалась, блок молчит; остальные проверки адреса пропущены")
                    return nil
                }
                if frames.isEmpty { observations.append("\(identifier): нет ответа") }
                for frame in frames {
                    t("Проба KWP \(identifier): \(frame)")
                    observations.append("\(identifier): \(frame)")
                    guard frame.isPositive(0x1A), frame.bytes.count > 2,
                          frame.bytes[1] == (identifier == "1A9B" ? 0x9B : 0x91) else {
                        if frame.negative, frame.bytes[2] != 0x78 { negativeResponses.append(frame) }
                        continue
                    }
                    let identity = Dtc.identificationText(Array(frame.bytes.dropFirst(2)))
                    let generic = identity.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "HARDWARE NO"
                        || identity == "Ответ пустой"
                    if generic {
                        sawUnverifiedResponse = true
                        observations.append("\(identifier): получен только общий Hardware No, номер блока не подтверждён")
                    } else {
                        return "\(identifier) → \(identity)"
                    }
                }
                // A block that stays completely silent (only NO DATA) right after a successful
                // init may simply be slow to wake up; give the same request a second chance.
                if frames.contains(where: { $0.ok }) || attempt == 2 { return nil }
                t("Проба KWP \(identifier): блок молчит после инициализации, повторяю запрос через 0.7 с")
                Thread.sleep(forTimeInterval: 0.7)
            }
            return nil
        }

        for service in ["1A91", "1A9B"] {
            if let identity = try readIdentity(service) {
                return (nil, nil, .responded, "Подтверждён идентификатор блока: \(identity)")
            }
        }

        for service in ["1089", "1086", "1003"] {
            if busDead {
                observations.append("сеанс \(service): пропущен, инициализация шины уже не удалась")
                continue
            }
            let frames = try e.requestFramesForBlockScan(service, timeout: 6)
            if busInitFailed(frames) {
                busDead = true
                observations.append("сеанс \(service): инициализация K-line не удалась, блок молчит; остальные проверки адреса пропущены")
                continue
            }
            if frames.isEmpty { observations.append("сеанс \(service): нет ответа") }
            for session in frames {
                t("Проба KWP-сеанса \(service): \(session)")
                observations.append("сеанс \(service): \(session)")
                guard session.isPositive(0x10) else {
                    if session.negative, session.bytes[2] != 0x78 { negativeResponses.append(session) }
                    continue
                }
                sawUnverifiedResponse = true
                for identifier in ["1A9B", "1A91"] {
                    if let identity = try readIdentity(identifier) {
                        _ = try? e.request("1082", timeout: 1)   // close the probe session politely
                        return (nil, nil, .responded, "Сеанс \(service); подтверждён идентификатор блока: \(identity)")
                    }
                }
                _ = try? e.request("1082", timeout: 1)
                return (session, nil, .unverifiedResponse,
                        "Блок принял диагностический сеанс \(service), но не выдал проверяемый номер; не считаю это подтверждённым блоком")
            }
        }
        if let lastNegative = negativeResponses.last {
            return (nil, lastNegative, .negativeResponse, "ECU ответил отрицательно; проверочные сервисы не приняты: \(observations.joined(separator: "; "))")
        }
        if sawUnverifiedResponse {
            return (nil, nil, .unverifiedResponse, "ECU откликнулся, но номер блока не подтвердился: \(observations.joined(separator: "; "))")
        }
        var detail = observations.joined(separator: "; ")
        if !busDead {
            // The init handshake completed, so something may be alive at this address, yet every
            // KWP2000 request timed out. Two realistic causes: an older VAG KWP1281 block (the
            // "Вася"/VCDS protocol, which an ELM327 cannot speak), or the ELM clone dropping the
            // exchange right after its flaky 5-baud init. The scan retries the init several times;
            // if the address stays silent anyway, only VCDS/Вася tells the two causes apart.
            detail += "; инициализация прошла, но KWP2000-запросы без ответа — это либо блок KWP1281 (протокол VCDS: через ELM327 не читается, нужен KKL-адаптер), либо клон ELM потерял обмен после 5-бод инициализации; точно различает Вася/VCDS (например, АКПП 0x02 по Васе подтверждённо KWP2000)"
        }
        return (nil, nil, .noResponse, detail)
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
                let response = try requestFinal(e, "1A\(option)", service: 0x1A, timeout: 4)
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
    /// Session open goes through requestFinal: blocks like the suspension, gateway and
    /// airbag often answer 7F 10 78 ("response pending") first and send the real
    /// 50 xx confirmation in the next frame — taking the first frame would lose them.
    private func startSession(_ e: Elm, _ list: [String]) throws -> (String?, String) {
        var reason = "нет ответа"
        for sess in list {
            let r = try requestFinal(e, sess == "-" ? "3E" : sess, service: sess == "-" ? 0x3E : 0x10, timeout: 8)
            t("\(sess == "-" ? "tester present" : "session \(sess)"): \(r)")
            if sess == "-" && r.ok && !r.negative { return ("без запроса сессии", "") }
            if r.isPositive(0x10) { return (sess, "") }
            if r.negative, r.bytes.count > 2 { reason = "отказ 7F \(hx(r.bytes[1])) \(hx(r.bytes[2])) на \(sess)" }
            else if let first = r.errors.first { reason = first }
            else { reason = "нет ответа" }
            let busError = r.errors.contains { err in
                let u = err.uppercased()
                return u.contains("UNABLE") || u.contains("BUS INIT") || u.contains("BUS ERROR")
            }
            if busError {
                _ = try e.cmd("ATPC")     // close protocol, next attempt re-inits
                break                     // the init itself failed: remaining sessions would repeat the same failing init
            }
        }
        return (nil, reason)
    }

    /// KWP blocks often answer 7F xx 78 ("response pending") first and send the final response
    /// later; cheap ELM clones return to the prompt after that first frame and never deliver the
    /// final one. Resend the request until the final answer or a real refusal arrives.
    private func requestFinal(_ e: Elm, _ hex: String, service: Int, timeout: Double, attempts: Int = 4) throws -> Response {
        var last = Response(bytes: [], errors: [])
        for attempt in 0..<attempts {
            let r = try e.request(hex, timeout: timeout)
            last = r
            if r.isPositive(service) { return r }
            // Pending and final frames merged into one buffer: cut everything up to the positive frame.
            if r.negative, let start = r.bytes.firstIndex(of: service + 0x40) {
                return Response(bytes: Array(r.bytes[start...]), errors: r.errors)
            }
            let pendingOnly = r.negative && r.bytes.count > 2 && r.bytes[1] == service && r.bytes[2] == 0x78
            if pendingOnly && attempt + 1 < attempts {
                t("запрос \(hex): блок попросил время (7F \(hx(service)) 78), жду и повторяю (\(attempt + 1)/\(attempts))")
                Thread.sleep(forTimeInterval: 0.8)
                continue
            }
            return r
        }
        return last
    }

    /// Module request with recovery: if the block stays silent (the KWP session expired while
    /// the app was idle), reconnects to the module once and retries the request.
    private func moduleRequestFinal(_ e: Elm, _ module: DtcModule, _ hex: String, service: Int, timeout: Double) throws -> Response {
        guard activeModule == module else { return Response(bytes: [], errors: ["Нет соединения с выбранным блоком"]) }
        // A pending MK25 clear is verified by reading faults again. Do not resend it on silence or pending.
        let clearingMK25 = module == .absEsp && service == 0x14
        func send() throws -> Response {
            try requestFinal(e, hex, service: service, timeout: timeout, attempts: clearingMK25 ? 1 : 4)
        }
        var reply = try send()
        let silent = reply.bytes.isEmpty && (reply.errors.isEmpty || (module == .absEsp && reply.errors == ["NO DATA"]))
        if silent, !clearingMK25, let s = lastSettings {
            t("\(module.title): нет ответа на \(hex); переподключаюсь и повторяю запрос")
            guard try connectModuleOnWorker(module, e, s) else { return reply }
            reply = try send()
        }
        // Identification works in the default MK25 session. Switch only if the requested DTC service requires it.
        if module == .absEsp, reply.negative, reply.bytes[1] == service, [0x7E, 0x7F, 0x80].contains(reply.bytes[2]) {
            let (session, _) = try startSession(e, module.sessions.filter { $0 != "-" })
            if session != nil { reply = try send() }
        }
        return reply
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

    /// KWP 0x18 readDiagnosticTroubleCodesByStatus, all groups. Answer: 58 n (hi lo status)*.
    func readDtc() {
        job({ self.dtcFail($0) }) {
            guard let e = self.elm, self.ecuOk else { self.dtcFail("сначала подключи ЭБУ"); return }
            self.setDtc(.busy, "Чтение ошибок…")
            self.t("=== чтение ошибок ===")
            let response = try self.moduleRequestFinal(e, .engine, "1802FF00", service: 0x18, timeout: 8)
            if response.negative {
                self.dtcFail("отказ 7F \(hx(response.bytes.count > 1 ? response.bytes[1] : 0)) \(hx(response.bytes.count > 2 ? response.bytes[2] : 0))")
                return
            }
            guard let codes = Dtc.entries(from: response.bytes, module: .engine) else {
                let detail = response.bytes.isEmpty
                    ? (response.errors.isEmpty ? "пусто" : response.errors.joined(separator: "; "))
                    : "неизвестный формат ответа: \(response)"
                self.dtcFail("нет ответа (\(detail))")
                return
            }
            let msg = codes.isEmpty ? "Ошибок нет" : "Ошибок: \(codes.count)\n" + codes
                .map { "\($0.code) — \($0.description) · статус 0x\(hx($0.status))" }
                .joined(separator: "\n")
            self.t(msg)
            self.updateModule(.engine) {
                $0.dtcState = .ok
                $0.dtcText = codes.isEmpty ? "Ошибок нет" : "Найдено ошибок: \(codes.count)"
                $0.codes = codes
            }
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
            let r = try self.moduleRequestFinal(e, .engine, "14FF00", service: 0x14, timeout: 8)
            self.t("стирание: \(r)")
            let outcome = self.clearAckOutcome(r)
            self.t("результат команды очистки: \(outcome.detail)")
            if !outcome.acknowledged && !outcome.pending {
                self.dtcFail(outcome.detail)
                self.flushTraceFile()
                return
            }
            self.waitForPendingClearVerification(outcome, module: .engine)
            guard let remaining = try self.readDtcOnWorker(e, module: .engine) else { return }
            self.applyClearVerification(.engine, before: before, remaining: remaining, outcome: outcome)
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
            let response = try self.moduleRequestFinal(e, module, "14FF00", service: 0x14, timeout: 8)
            self.t("ответ блока на стирание: \(response)")
            let outcome = self.clearAckOutcome(response)
            self.t("результат команды очистки: \(outcome.detail)")
            guard outcome.acknowledged || outcome.pending else {
                self.moduleDtcFail(module, outcome.detail)
                self.flushTraceFile()
                return
            }
            self.waitForPendingClearVerification(outcome, module: module)
            guard let remaining = try self.readDtcOnWorker(e, module: module) else { return }
            self.applyClearVerification(module, before: before, remaining: remaining, outcome: outcome)
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
                var pendingVerified: [String] = []
                var pendingRemaining: [String] = []
                var acceptedCount = 0
                var failed: [String] = []
                for module in self.clearableModules {
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
                        let clearResponse = try self.moduleRequestFinal(e, module, "14FF00", service: 0x14, timeout: 8)
                        self.t("ответ блока на очистку \(module.title): \(clearResponse)")
                        let outcome = self.clearAckOutcome(clearResponse)
                        self.t("результат команды очистки \(module.title): \(outcome.detail)")
                        guard outcome.acknowledged || outcome.pending else {
                            self.moduleDtcFail(module, outcome.detail)
                            failed.append("\(module.title): \(outcome.detail)")
                            continue
                        }
                        if outcome.acknowledged { acceptedCount += 1 }
                        self.waitForPendingClearVerification(outcome, module: module)
                        self.setClearAll(.busy, "\(module.title): проверка результата…")
                        guard let remaining = try self.readDtcOnWorker(e, module: module) else {
                            failed.append("\(module.title): команда принята, но результат не удалось проверить")
                            continue
                        }
                        let verification = self.applyClearVerification(module, before: before, remaining: remaining, outcome: outcome)
                        if remaining.isEmpty {
                            cleared.append(module.title)
                            if outcome.pending { pendingVerified.append(module.title) }
                        } else if outcome.pending {
                            pendingRemaining.append("\(module.title): \(verification)")
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

                var summary = "Положительный ответ на очистку получен для \(acceptedCount) блоков; без ошибок после проверки: \(cleared.count)."
                if !cleared.isEmpty { summary += "\nОшибок нет: \(cleared.joined(separator: ", "))." }
                if !pendingVerified.isEmpty {
                    summary += "\nБлоки ответили только «обработка», но повторное чтение подтвердило пустой список: \(pendingVerified.joined(separator: ", "))."
                }
                if !pendingRemaining.isEmpty {
                    summary += "\nНет итогового подтверждения, ошибки остались после повторного чтения: \(pendingRemaining.joined(separator: "; "))."
                }
                if !acceptedWithRemaining.isEmpty {
                    summary += "\nКоманда принята, но коды остались или сразу появились снова: \(acceptedWithRemaining.joined(separator: "; "))."
                }
                if !failed.isEmpty { summary += "\nНе удалось выполнить или проверить: \(failed.joined(separator: "; "))." }
                self.t("Очистка ошибок во всех блоках завершена: \(summary.replacingOccurrences(of: "\n", with: " "))")
                self.flushTraceFile()
                self.setClearAll(failed.isEmpty && pendingRemaining.isEmpty ? .ok : .fail, summary)
            } catch ElmError.closed {
                self.setClearAll(.fail, "Остановлено: соединение с адаптером потеряно")
                throw ElmError.closed
            }
        }
    }

    private func readDtcSnapshotForClear(_ e: Elm, module: DtcModule) throws -> [DtcEntry]? {
        let response = try moduleRequestFinal(e, module, "1802FF00", service: 0x18, timeout: 8)
        guard let codes = Dtc.entries(from: response.bytes, module: module) else {
            t("Снимок до очистки \(module.title) не распознан: \(response)")
            return nil
        }
        let list = codes.isEmpty ? "ошибок нет" : codes.map { "\($0.code) [\($0.rawWord)]" }.joined(separator: ", ")
        t("Снимок до очистки \(module.title): \(list)")
        return codes
    }

    /// A KWP clear command may return 7F 14 78 without the final acknowledgement;
    /// callers then verify the actual DTC list before reporting the outcome.
    private func clearAckOutcome(_ response: Response) -> (acknowledged: Bool, pending: Bool, detail: String) {
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
            return (true, false, "подтверждено положительным ответом 54 FF 00\(pending)")
        }
        if let code = finalNegative {
            return (false, false, "блок отказал: 7F 14 \(hx(code))")
        }
        if pendingCount > 0 {
            return (false, true, "блок сообщил только 7F 14 78 (обработка ещё не подтверждена); итогового ответа нет")
        }
        return (false, false, "нет положительного подтверждения от блока (\(response))")
    }

    private func waitForPendingClearVerification(
        _ outcome: (acknowledged: Bool, pending: Bool, detail: String),
        module: DtcModule
    ) {
        guard outcome.pending else { return }
        t("\(module.title): \(outcome.detail); жду 3 секунды и затем перепроверяю ошибки")
        Thread.sleep(forTimeInterval: 3)
    }

    @discardableResult
    private func applyClearVerification(
        _ module: DtcModule,
        before: [DtcEntry]?,
        remaining: [DtcEntry],
        outcome: (acknowledged: Bool, pending: Bool, detail: String)
    ) -> String {
        let summary: String
        let beforeWords = Set(before?.map(\.rawWord) ?? [])
        let remainingWords = Set(remaining.map(\.rawWord))
        if outcome.pending && remaining.isEmpty {
            summary = "\(outcome.detail); повторное чтение подтвердило, что ошибок нет."
        } else if outcome.pending && before != nil && beforeWords != remainingWords {
            let codes = remaining.map(\.code).joined(separator: ", ")
            let removed = (before ?? []).filter { !remainingWords.contains($0.rawWord) }.map(\.code)
            let added = remaining.filter { !beforeWords.contains($0.rawWord) }.map(\.code)
            var changes: [String] = []
            if !removed.isEmpty { changes.append("исчезли: \(removed.joined(separator: ", "))") }
            if !added.isEmpty { changes.append("появились новые: \(added.joined(separator: ", "))") }
            let changesText = changes.isEmpty ? "список изменился" : changes.joined(separator: "; ")
            summary = "\(outcome.detail); после ожидания список изменился (\(changesText)), остались: \(codes)."
        } else if outcome.pending {
            let codes = remaining.map(\.code).joined(separator: ", ")
            summary = "\(outcome.detail); после повторного чтения ошибки остаются: \(codes)."
        } else if remaining.isEmpty {
            summary = "Команда очистки подтверждена; после проверки ошибок нет."
        } else {
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
        let response = try moduleRequestFinal(e, module, "1802FF00", service: 0x18, timeout: 8)
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

    func probeMafPair() {
        guard !logging else { return }
        ui { self.mafProbeState = .busy; self.mafProbeText = "Проверка поддержки PID 01 66…" }
        job({ msg in
            self.t("ОШИБКА ПРОВЕРКИ PID 01 66 для ДМРВ 1/2: \(msg)")
            self.ui { self.mafProbeState = .fail; self.mafProbeText = "Проверка не удалась: \(msg)" }
        }) {
            guard let e = self.elm, self.ecuOk, self.activeModule == .engine else {
                self.ui { self.mafProbeState = .fail; self.mafProbeText = "Сначала подключи ЭБУ двигателя" }
                return
            }
            self.t("=== проверка двух ДМРВ · OBD PID 01 66 ===")
            let reading = try self.readMafPair(e)
            self.publishMafProbe(reading)
        }
    }

    private func readMafPair(_ e: Elm) throws -> MAFPairReading {
        MAFPairReading(response: try e.request("0166", timeout: 1.5))
    }

    private func publishMafProbe(_ reading: MAFPairReading) {
        let response = reading.response.description.isEmpty ? "пустой ответ" : reading.response.description
        guard reading.isPositive else {
            let text = "ЭБУ не подтвердил PID 01 66: \(response)"
            t(text)
            ui { self.mafProbeState = .fail; self.mafProbeText = text }
            return
        }
        guard reading.supportsAny else {
            let text = "PID 01 66 ответил, но ЭБУ не отметил поддержку ДМРВ 1 или 2 (\(response))"
            t(text)
            ui { self.mafProbeState = .fail; self.mafProbeText = text }
            return
        }
        let a = reading.supportsA ? String(format: "%.2f г/с", reading.flowA ?? 0) : "не поддерживается"
        let b = reading.supportsB ? String(format: "%.2f г/с", reading.flowB ?? 0) : "не поддерживается"
        let text = "Расход: ДМРВ 1 — \(a); ДМРВ 2 — \(b)"
        t("PID 01 66: \(text); ответ \(response)")
        ui { self.mafProbeState = .ok; self.mafProbeText = text }
    }

    func startLog(_ s: Settings, _ wanted: [Measurement], includeMafPair: Bool = false) {
        running = true
        setLog(true, "Запуск…")
        job({ msg in self.ecuFail(msg); self.running = false; self.setLog(false, "ошибка: \(msg)") }) {
            guard let e = self.elm, self.ecuOk else {
                self.running = false
                self.setLog(false, "сначала подключи ЭБУ")
                return
            }
            var mafPairAvailable = false
            if includeMafPair {
                self.ui { self.mafProbeState = .busy; self.mafProbeText = "Проверка PID 01 66 перед записью…" }
                do {
                    let reading = try self.readMafPair(e)
                    self.publishMafProbe(reading)
                    mafPairAvailable = reading.isPositive && reading.supportsAny
                } catch {
                    let text = "Не удалось прочитать PID 01 66: \(error)"
                    self.t(text)
                    self.ui { self.mafProbeState = .fail; self.mafProbeText = text }
                }
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
            try self.logLoop(e, plan, includeMafPair: mafPairAvailable)
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

    private func logLoop(_ e: Elm, _ plan: ReadPlan, includeMafPair: Bool) throws {
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
        let mafNames = includeMafPair ? ["maf1_obd_g_s", "maf2_obd_g_s"] : []
        let mafUnits = includeMafPair ? ["g/s", "g/s"] : []
        w("TimeStamp," + (vars.map { $0.name } + extraNames + mafNames).joined(separator: ",") + "\n")
        w("s," + (vars.map { $0.displayUnit } + extraUnits + mafUnits).joined(separator: ",") + "\n")
        let modeText: String
        switch plan.mode {
        case .ddli: modeText = "DDLI · \(plan.groups.count) блока"
        case .rmba: modeText = "RMBA"
        }
        let mafText = includeMafPair ? ", два расхода ДМРВ PID 01 66" : ""
        setLog(true, "Запись: \(vars.count) перем., режим \(modeText)\(mafText) → ME7Logs/me7_\(st).csv")
        var values = [Double](repeating: 0, count: vars.count)
        let t0 = Date()
        var samples = 0
        var fails = 0
        var lastUi = Date.distantPast
        var hzT = Date()
        var hzN = 0
        var hz = 0.0
        var mafReadFailures = 0
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

            var mafReading: MAFPairReading?
            if includeMafPair {
                do {
                    mafReading = try self.readMafPair(e)
                    if mafReading?.isPositive == true { mafReadFailures = 0 }
                    else {
                        mafReadFailures += 1
                        if mafReadFailures == 1 || mafReadFailures % 20 == 0 {
                            t("PID 01 66: нет положительного ответа (\(mafReading?.response.description ?? "нет ответа")); основная запись продолжается")
                        }
                    }
                } catch {
                    mafReading = nil
                    mafReadFailures += 1
                    if mafReadFailures == 1 || mafReadFailures % 20 == 0 {
                        t("PID 01 66: \(error); основная запись продолжается")
                    }
                }
            }

            var outputFields = values.map(fmt)
            var derivedLive: [LiveValue] = []
            if let actualPressure, let ambientPressure {
                let value = values[actualPressure] - values[ambientPressure]
                outputFields.append(fmt(value))
                derivedLive.append(LiveValue(id: "boost_actual_gauge", label: "Наддув фактический · избыточный", value: value, unit: "mbar"))
            }
            if let requestedPressure, let ambientPressure {
                let value = values[requestedPressure] - values[ambientPressure]
                outputFields.append(fmt(value))
                derivedLive.append(LiveValue(id: "boost_target_gauge", label: "Наддув заданный · избыточный", value: value, unit: "mbar"))
            }
            if includeMafPair {
                let a = mafReading?.flowA
                let b = mafReading?.flowB
                outputFields.append(a.map(fmt) ?? "")
                outputFields.append(b.map(fmt) ?? "")
                if let a { derivedLive.append(LiveValue(id: "maf1_obd_g_s", label: "ДМРВ 1 · расход по OBD", value: a, unit: "г/с")) }
                if let b { derivedLive.append(LiveValue(id: "maf2_obd_g_s", label: "ДМРВ 2 · расход по OBD", value: b, unit: "г/с")) }
            }
            w(String(format: "%.3f", Date().timeIntervalSince(t0)) + "," + outputFields.joined(separator: ",") + "\n")
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
