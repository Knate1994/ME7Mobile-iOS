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
    @Published var logging = false
    @Published var logText = ""
    @Published var live: [LiveValue] = []
    @Published var hz = 0.0
    @Published var trace: [String] = []

    private let worker = DispatchQueue(label: "me7.link")
    private var elm: Elm?
    private var traceFile: FileHandle?
    private var ecuOk = false
    private var activeModule: DtcModule?
    private let flagLock = NSLock()
    private var runFlag = false
    private var running: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return runFlag }
        set { flagLock.lock(); runFlag = newValue; flagLock.unlock() }
    }

    // ---------- plumbing ----------

    private func ui(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
    private func setElm(_ s: LinkState, _ text: String) { ui { self.elmState = s; self.elmText = text } }
    private func setEcu(_ s: LinkState, _ text: String) { ui { self.ecuState = s; self.ecuText = text } }
    private func setDtc(_ s: LinkState, _ text: String) { ui { self.dtcState = s; self.dtcText = text } }
    private func setLog(_ r: Bool, _ text: String) { ui { self.logging = r; self.logText = text } }
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
        ui {
            self.trace.append(s)
            if self.trace.count > 60 { self.trace.removeFirst(self.trace.count - 60) }
        }
        if let f = traceFile, let d = (s + "\n").data(using: .utf8) { f.write(d) }
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
        return try? FileHandle(forWritingTo: url)
    }

    /// Runs `block` on the worker; a dead adapter connection turns step 1 red, anything else is reported by `onError`.
    private func job(_ onError: @escaping (String) -> Void, _ block: @escaping () throws -> Void) {
        worker.async {
            do { try block() }
            catch ElmError.closed { self.elmFail("связь с адаптером потеряна") }
            catch { self.t("EXCEPTION \(error)"); onError("\(error)") }
        }
    }

    // ---------- 1. adapter ----------

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
        try? traceFile?.close()
        traceFile = nil
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
            self.ecuOk = false
            if let previous = self.activeModule, previous != .engine {
                self.updateModule(previous) { $0.connectionState = .idle; $0.connectionText = "Сеанс закрыт при выборе двигателя" }
            }
            self.activeModule = nil
            self.updateModule(.engine) { $0.connectionState = .busy; $0.connectionText = "Инициализация блока двигателя…" }
            self.setEcu(.busy, "Инициализация блока…")
            self.t("=== ЭБУ ===")
            var links = [Link(proto: s.proto, initAddress: s.initAddress, header: s.header)]
            for l in [Link(proto: "5", initAddress: "", header: "8110F1"), Link(proto: "5", initAddress: "", header: "8101F1")]
            where !links.contains(where: { $0.proto == l.proto && $0.header == l.header }) {
                links.append(l)
            }
            var results: [String] = []
            for link in links {
                self.setEcu(.busy, (["Инициализация: \(link.label)…"] + results).joined(separator: "\n"))
                self.t("--- попытка: \(link.label), заголовок \(link.header) ---")
                _ = try e.cmd("ATPC")
                _ = try e.cmd("ATSP\(link.proto)")
                if link.proto == "3" || link.proto == "4" { _ = try e.cmd("ATIIA\(link.initAddress)") }
                _ = try e.cmd("ATSH\(link.header)")
                _ = try e.cmd("ATWM\(link.header)3E")      // keep-alive (tester present) while idle
                let (session, error) = try self.startSession(e, s)
                if let session = session {
                    self.ecuOk = true
                    self.activeModule = .engine
                    self.t("ЭБУ подключён: \(link.label), сессия \(session)")
                    self.setEcu(.ok, "ПОДКЛЮЧЕНО · \(link.label) · сессия \(session)")
                    self.updateModule(.engine) { $0.connectionState = .ok; $0.connectionText = "Подключено · \(link.label) · сессия \(session)" }
                    try self.readSoftwareNumber(e, module: .engine)
                    return
                }
                results.append("\(link.label) ✗ \(error)")
            }
            self.updateModule(.engine) { $0.connectionState = .fail; $0.connectionText = results.joined(separator: "\n") }
            self.ecuFail(results.joined(separator: "\n"))
        }
    }

    /// Connect to one selected KWP2000 controller. Other modules are explicitly reinitialized
    /// because the ELM adapter can hold only one active physical K-line session at a time.
    func connectModule(_ module: DtcModule, _ s: Settings) {
        if module == .engine {
            connectEcu(s)
            return
        }
        job({ self.moduleConnectionFail(module, $0) }) {
            guard let e = self.elm else { self.moduleConnectionFail(module, "сначала подключи ELM"); return }
            self.ecuOk = false
            if let previous = self.activeModule {
                self.updateModule(previous) { $0.connectionState = .idle; $0.connectionText = "Сеанс закрыт при выборе другого блока" }
            }
            self.activeModule = nil
            self.setEcu(.idle, "Двигатель не выбран для текущей диагностики")
            self.updateModule(module) {
                $0.connectionState = .busy
                $0.connectionText = "Подключение к блоку \(module.target)…"
                $0.softwareNumber = "Чтение…"
                $0.dtcState = .idle
                $0.dtcText = "Ошибки не прочитаны"
                $0.codes = []
            }
            self.t("=== подключение: \(module.title), адрес 0x\(module.target) ===")

            let target = module.target
            let links = [
                Link(proto: "5", initAddress: "", header: "81\(target)F1"),
                Link(proto: "4", initAddress: target, header: "C1\(target)F1"),
            ]
            var failures: [String] = []
            for link in links {
                self.t("--- \(link.label), заголовок \(link.header) ---")
                _ = try e.cmd("ATPC")
                _ = try e.cmd("ATSP\(link.proto)")
                if link.proto == "3" || link.proto == "4" { _ = try e.cmd("ATIIA\(link.initAddress)") }
                _ = try e.cmd("ATSH\(link.header)")
                _ = try e.cmd("ATWM\(link.header)3E")
                let (session, error) = try self.startSession(e, module.sessions)
                if let session = session {
                    self.activeModule = module
                    let status = "Подключено · \(link.label) · сессия \(session)"
                    self.updateModule(module) { $0.connectionState = .ok; $0.connectionText = status }
                    self.t("\(module.title): подключено, \(status)")
                    try self.readSoftwareNumber(e, module: module)
                    return
                }
                failures.append("\(link.label): \(error)")
                _ = try e.cmd("ATPC")
            }

            var message = failures.joined(separator: "\n")
            if let hint = module.protocolHint { message += "\n\(hint)" }
            message += "\nПроверь тип ELM и доступность K-Line этого блока на диагностическом разъёме."
            self.moduleConnectionFail(module, message)
        }
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
            let r = try e.request("14FF00", timeout: 5)
            self.t("стирание: \(r)")
            if !r.isPositive(0x14) {
                self.dtcFail(r.negative ? "блок отказал: 7F \(hx(r.bytes[1])) \(hx(r.bytes[2]))" : "нет подтверждения (\(r))")
                return
            }
            self.readDtc()
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
            try self.readDtcOnWorker(e, module: module)
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
            let response = try e.request("14FF00", timeout: 8)
            self.t("ответ блока на стирание: \(response)")
            guard response.isPositive(0x14) else {
                let reason = response.negative && response.bytes.count >= 3
                    ? "блок отказал: 7F \(hx(response.bytes[1])) \(hx(response.bytes[2]))"
                    : "нет подтверждения от блока (\(response))"
                self.moduleDtcFail(module, reason)
                return
            }
            try self.readDtcOnWorker(e, module: module)
        }
    }

    private func readDtcOnWorker(_ e: Elm, module: DtcModule) throws {
        let response = try e.request("1802FF00", timeout: 8)
        if response.negative {
            let service = response.bytes.count > 1 ? hx(response.bytes[1]) : "??"
            let code = response.bytes.count > 2 ? hx(response.bytes[2]) : "??"
            moduleDtcFail(module, "блок отказал: 7F \(service) \(code)")
            return
        }
        guard let codes = Dtc.entries(from: response.bytes, module: module) else {
            moduleDtcFail(module, response.bytes.isEmpty
                ? "нет ответа от блока"
                : "неизвестный формат ответа: \(response)")
            return
        }
        let message = codes.isEmpty ? "Ошибок нет" : "Найдено ошибок: \(codes.count)"
        updateModule(module) { $0.dtcState = .ok; $0.dtcText = message; $0.codes = codes }
        if module == .engine { setDtc(.ok, message) }
        t("\(module.title): \(message)")
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
            let (vars, mode) = try self.defineVariables(e, s, wanted)
            if vars.isEmpty {
                self.running = false
                self.t("ОШИБКА ЗАПИСИ: ни одна переменная не принята блоком")
                self.setLog(false, "ни одна переменная не принята блоком (см. лог)")
                return
            }
            try self.logLoop(e, s, vars, mode)
        }
    }

    private enum Mode: String { case ddli = "DDLI", rmba = "RMBA" }

    private func defineVariables(_ e: Elm, _ s: Settings, _ wanted: [Measurement]) throws -> ([Measurement], Mode) {
        let lid = s.lid
        _ = try e.request("2C\(lid)04")                   // clear LID (may be refused, harmless)
        var ok: [Measurement] = []
        var pos = 1
        var refusedService = false
        for m in wanted {
            if pos - 1 + m.size > s.maxBytes { t("лимит \(s.maxBytes) байт: \(m.name) пропущена"); continue }
            let r = try e.request("2C\(lid)03\(hx(pos))\(hx(m.size))\(hx(m.address, 6))")
            if r.isPositive(0x2C) {
                ok.append(m); pos += m.size
            } else {
                t("2C отказ для \(m.name): \(r)")
                if r.negative && [0x11, 0x33, 0x80].contains(r.bytes[2]) { refusedService = true; break }
            }
        }
        if !ok.isEmpty && !refusedService { return (ok, .ddli) }
        // fallback: readMemoryByAddress per variable
        setLog(true, "0x2C не принят, пробую 0x23 (медленнее)…")
        var ok2: [Measurement] = []
        for m in wanted {
            let r = try e.request("23\(hx(m.address, 6))\(hx(m.size))")
            if r.isPositive(0x23) { ok2.append(m) } else { t("23 отказ для \(m.name): \(r)") }
        }
        return (ok2, .rmba)
    }

    private func logLoop(_ e: Elm, _ s: Settings, _ vars: [Measurement], _ mode: Mode) throws {
        let st = stamp()
        let csv = openOutput("me7_\(st).csv")
        func w(_ line: String) { if let d = line.data(using: .utf8) { csv?.write(d) } }
        w("TimeStamp," + vars.map { $0.name }.joined(separator: ",") + "\n")
        w("s," + vars.map { $0.unit }.joined(separator: ",") + "\n")
        setLog(true, "Запись: \(vars.count) перем., режим \(mode.rawValue) → ME7Logs/me7_\(st).csv")
        var values = [Double](repeating: 0, count: vars.count)
        let t0 = Date()
        var samples = 0
        var fails = 0
        var lastUi = Date.distantPast
        var hzT = Date()
        var hzN = 0
        var hz = 0.0
        let total = vars.reduce(0) { $0 + $1.size }
        var reason = "остановлено, записано"
        defer {
            running = false
            try? csv?.close()
            t("записано \(samples) замеров")
            setLog(false, "\(reason) \(samples) замеров → ME7Logs/me7_\(st).csv")
        }
        while running {
            var data: [UInt8]? = nil
            switch mode {
            case .ddli:
                let r = try e.request("21\(s.lid)", timeout: 1.5)
                if r.isPositive(0x21) && r.bytes.count >= 2 + total {
                    data = r.bytes[2..<(2 + total)].map { UInt8($0) }
                } else {
                    t("21: \(r)")
                }
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
            var p = 0
            for i in vars.indices { values[i] = vars[i].convert(d, p); p += vars[i].size }
            w(String(format: "%.3f", Date().timeIntervalSince(t0)) + values.map { "," + fmt($0) }.joined() + "\n")
            samples += 1
            hzN += 1
            let now = Date()
            if now.timeIntervalSince(hzT) > 1 { hz = Double(hzN) / now.timeIntervalSince(hzT); hzT = now; hzN = 0 }
            if now.timeIntervalSince(lastUi) > 0.15 {
                lastUi = now
                let snap = zip(vars, values).map { pair in LiveValue(id: pair.0.name, value: pair.1, unit: pair.0.unit) }
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
