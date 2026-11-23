import Foundation

/// Read-only comparison with the ABS controller identified in the vehicle by the workshop tester.
enum MK25Test {
    struct Result {
        let identified: Bool
        let text: String
    }

    static func matchesPart(_ payload: [Int]) -> Bool {
        // The controller can pad the printed part number with spaces or hyphens.
        let text = String(decoding: payload.map { UInt8(clamping: $0) }, as: UTF8.self)
            .uppercased()
        return text.range(of: #"7L0[ -]*907[ -]*379[ -]*C(?![A-Z])"#, options: .regularExpression) != nil
    }

    static func run(_ elm: Elm, report: (String) -> Void) throws -> Result {
        func accepted(_ reply: String) -> Bool {
            let lines = reply.uppercased().components(separatedBy: .newlines)
            return lines.contains("OK") || lines.contains { $0.hasPrefix("BUS INIT") && $0.hasSuffix("OK") }
        }
        func configure(_ commands: [String]) throws -> String? {
            for command in commands {
                let reply = try elm.cmd(command)
                if !accepted(reply) { return "\(command) → \(reply.isEmpty ? "тайм-аут" : reply)" }
            }
            return nil
        }

        try elm.prepareBlockScanKwpMode()
        var outcomes: [String] = []
        for slow in [true, false] {
            let mode = slow ? "5 бод" : "Fast init"
            report("ABS 03 · \(mode) · настройка ELM")
            var commands = ["ATPC", slow ? "ATSP4" : "ATSP5", "ATIB10", "ATH0"]
            if slow { commands.append("ATIIA03") }
            commands += ["ATSH8103F1", "ATWM8103F13E"]
            if let error = try configure(commands) {
                outcomes.append("\(mode) · настройка: \(error)")
                continue
            }
            Thread.sleep(forTimeInterval: 0.4)
            let reply = try elm.cmd(slow ? "ATSI" : "ATFI", timeout: 8)
            let implicitInit = reply.trimmingCharacters(in: .whitespacesAndNewlines) == "?"
            if !accepted(reply) && !implicitInit {
                outcomes.append("\(mode) · инициализация: \(reply.isEmpty ? "тайм-аут" : reply)")
                continue
            }
            var keywords = ""
            if !implicitInit {
                keywords = try elm.cmd("ATKW")
                report("ABS 03 · \(mode) · KW: \(keywords) · эталон ВАСИ E9 8F")
            }
            // Some adapters do not implement AT SI/FI; the first identification
            // request then performs the same initiation automatically.
            var stage = implicitInit ? "неявная инициализация, ответа на чтение ID нет"
                                     : "инициализация принята, ответа на чтение ID нет"
            for option in [0x9B, 0x91] {
                let frames = try elm.requestFramesForBlockScan("1A" + hx(option), timeout: 7)
                if frames.contains(where: { $0.errors.contains { $0.uppercased().contains("BUS INIT") } }) {
                    stage = "ELM сообщил об ошибке инициализации"
                    break
                }
                for frame in frames {
                    if frame.isPositive(0x1A), frame.bytes.count > 2, frame.bytes[1] == option {
                        let payload = Array(frame.bytes.dropFirst(2))
                        if matchesPart(payload) {
                            if implicitInit { keywords = try elm.cmd("ATKW") }
                            return Result(identified: true, text: "7L0 907 379 C · \(mode) · KW: \(keywords.isEmpty ? "нет данных" : keywords)")
                        }
                        stage = "ответ на чтение ID: \(Dtc.identificationText(payload))"
                    } else if frame.negative {
                        stage = "блок ответил на запрос идентификации: \(frame)"
                    } else if !frame.errors.isEmpty {
                        stage += " · \(frame.errors.joined(separator: ", "))"
                    }
                }
            }
            outcomes.append("\(mode) · \(stage)")
        }
        // Compare the same slow-init command on the engine address seen in this car's trace.
        // An accepted engine handshake is a control for the adapter, not an ABS result.
        report("ABS 03 · контроль 5-бод инициализации на адресе двигателя 01")
        if let error = try configure(["ATPC", "ATSP4", "ATIB10", "ATIIA01", "ATSH8101F1", "ATWM8101F13E"]) {
            outcomes.append("Контроль 01 · настройка: \(error)")
        } else {
            Thread.sleep(forTimeInterval: 0.4)
            let reply = try elm.cmd("ATSI", timeout: 8)
            if accepted(reply) {
                let keywords = try elm.cmd("ATKW")
                outcomes.append("Контроль 01 · инициализация принята, KW: \(keywords)")
            } else {
                outcomes.append("Контроль 01 · \(reply.isEmpty ? "тайм-аут" : reply)")
            }
        }
        return Result(identified: false, text: outcomes.joined(separator: "\n"))
    }
}
