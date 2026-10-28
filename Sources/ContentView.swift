import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var link = Me7Link()
    @AppStorage("host") private var host = "192.168.0.10"
    @AppStorage("port") private var port = "35000"
    @AppStorage("proto") private var proto = "4"
    @AppStorage("init") private var initAddress = "01"
    @AppStorage("header") private var header = "8101F1"
    @AppStorage("sessions") private var sessions = "1089,1086,-"
    @AppStorage("maxBytes") private var maxBytes = "64"
    @AppStorage("vars") private var varsCsv = ""
    @State private var showSettings = false
    @State private var showVars = false
    @State private var confirmClear = false

    private var selected: [Measurement] {
        let names = Set(varsCsv.split(separator: ",").map(String.init))
        return EcuDef.all.filter { names.contains($0.name) }
    }

    private func settings() -> Settings {
        var s = Settings()
        s.host = host.trimmingCharacters(in: .whitespaces)
        s.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 35000
        s.proto = proto.trimmingCharacters(in: .whitespaces)
        s.initAddress = initAddress.trimmingCharacters(in: .whitespaces)
        s.header = header.trimmingCharacters(in: .whitespaces)
        s.sessions = sessions.trimmingCharacters(in: .whitespaces)
        s.maxBytes = Int(maxBytes.trimmingCharacters(in: .whitespaces)) ?? 64
        return s
    }

    private func preset(_ names: [String]) {
        varsCsv = names.filter { n in EcuDef.all.contains { $0.name == n } }.joined(separator: ",")
    }

    var body: some View {
        let elmOk = link.elmState == .ok
        let elmBusy = link.elmState == .busy
        let ecuBusy = link.ecuState == .busy
        let ecuOk = link.ecuState == .ok
        let dtcBusy = link.dtcState == .busy

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup("Настройки", isExpanded: $showSettings) {
                    VStack(spacing: 6) {
                        field("ELM IP", $host, keyboard: .numbersAndPunctuation)
                        field("Порт", $port, keyboard: .numberPad)
                        field("Протокол ELM", $proto, keyboard: .numberPad)
                        field("Адрес блока", $initAddress)
                        field("Заголовок KWP", $header)
                        field("Сессии", $sessions, keyboard: .numbersAndPunctuation)
                        field("Макс. байт", $maxBytes, keyboard: .numberPad)
                    }
                    .padding(.top, 6)
                }

                title("① АДАПТЕР ELM327")
                StatusBox(state: link.elmState, text: link.elmText)
                HStack {
                    button("Подключить ELM", !elmBusy && !link.logging && !ecuBusy) { link.connectElm(settings()) }
                    button("Отключить", (elmOk || elmBusy) && !link.logging) { link.disconnect() }
                }

                title("② БЛОК ДВИГАТЕЛЯ (ЭБУ)")
                StatusBox(state: link.ecuState, text: link.ecuText)
                HStack {
                    button("Подключить ЭБУ", elmOk && !ecuBusy && !link.logging) { link.connectEcu(settings()) }
                    button("Проверить шину", elmOk && !ecuBusy && !link.logging) { link.probeBus() }
                }

                title("ОШИБКИ ЭБУ")
                StatusBox(state: link.dtcState, text: link.dtcText)
                HStack {
                    button("Прочитать", ecuOk && !link.logging && !dtcBusy) { link.readDtc() }
                    button("Стереть", ecuOk && !link.logging && !dtcBusy) { confirmClear = true }
                }

                title("③ ЗАПИСЬ")
                Text(link.logText.isEmpty ? "Выбрано переменных: \(selected.count)" : link.logText)
                    .font(.footnote)
                HStack {
                    button("Переменные", !link.logging) { showVars = true }
                    Menu {
                        ForEach(EcuDef.presets.indices, id: \.self) { i in
                            Button(EcuDef.presets[i].0) { preset(EcuDef.presets[i].1) }
                        }
                    } label: {
                        Text("Наборы").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(link.logging)
                }
                Button {
                    if link.logging { link.stopLog() } else { link.startLog(settings(), selected) }
                } label: {
                    Text(link.logging ? "■ СТОП ЗАПИСИ" : "▶ СТАРТ ЗАПИСИ")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(link.logging ? .red : .green)
                .disabled(!(link.logging || ecuOk) || dtcBusy || (!link.logging && selected.isEmpty))

                liveView

                Text("Обмен с адаптером:").font(.footnote).padding(.top, 8)
                Text(link.trace.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
        }
        .sheet(isPresented: $showVars) { VarPicker(selectedCsv: $varsCsv) }
        .confirmationDialog("Стереть ошибки?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Стереть", role: .destructive) { link.clearDtc() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все коды и freeze frame в блоке двигателя будут удалены. Лучше сначала прочитать их.")
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true      // keep the screen on in the car
            if varsCsv.isEmpty, let p = EcuDef.presets.first { preset(p.1) }
        }
    }

    @ViewBuilder private var liveView: some View {
        if link.live.isEmpty {
            Text(selected.map { $0.name }.joined(separator: "\n"))
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f Гц", link.hz)).font(.system(size: 14, design: .monospaced))
                ForEach(link.live) { v in
                    HStack {
                        Text(v.id)
                        Spacer()
                        Text(String(format: "%.2f", v.value)).bold()
                        Text(v.unit).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
                    }
                    .font(.system(size: 17, design: .monospaced))
                }
            }
        }
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 15, weight: .bold)).padding(.top, 14)
    }

    private func field(_ label: String, _ value: Binding<String>, keyboard: UIKeyboardType = .asciiCapable) -> some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private func button(_ title: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .disabled(!enabled)
    }
}

/// Green = connected, red = failed (reason below the headline), amber = in progress, grey = not connected.
struct StatusBox: View {
    let state: LinkState
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(state == .busy ? .black : .white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color)
            .cornerRadius(8)
    }

    private var color: Color {
        switch state {
        case .ok: return Color(red: 0.18, green: 0.49, blue: 0.20)
        case .fail: return Color(red: 0.78, green: 0.16, blue: 0.16)
        case .busy: return Color(red: 0.98, green: 0.66, blue: 0.15)
        case .idle: return Color(white: 0.26)
        }
    }
}

struct VarPicker: View {
    @Binding var selectedCsv: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sel: Set<String> = []

    private var filtered: [Measurement] {
        if query.isEmpty { return EcuDef.all }
        return EcuDef.all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.alias.localizedCaseInsensitiveContains(query)
                || $0.comment.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { m in
                Button {
                    if sel.contains(m.name) { sel.remove(m.name) } else { sel.insert(m.name) }
                } label: {
                    HStack {
                        Image(systemName: sel.contains(m.name) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(m.name).font(.system(.body, design: .monospaced))
                            Text(m.alias.isEmpty ? m.comment : m.alias)
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                .foregroundColor(.primary)
            }
            .searchable(text: $query)
            .navigationTitle("Переменные (\(sel.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        selectedCsv = EcuDef.all.map { $0.name }.filter { sel.contains($0) }.joined(separator: ",")
                        dismiss()
                    }
                }
            }
        }
        .onAppear { sel = Set(selectedCsv.split(separator: ",").map(String.init)) }
    }
}
