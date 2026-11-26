import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var link = Me7Link()
    @AppStorage("vars") private var varsCsv = ""
    @StateObject private var navigation = CarouselNavigation()
    @State private var showAdapterError = false

    var body: some View {
        VStack(spacing: 0) {
            MainCarousel(link: link, navigation: navigation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            CarouselBar(selection: navigation.visiblePage, select: navigation.select)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .onChange(of: link.elmState) { state in
            if state == .fail && navigation.visiblePage == .connection { showAdapterError = true }
        }
        .alert("Нет связи с ELM327", isPresented: $showAdapterError) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(link.elmText)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true      // keep the screen on in the car
            let previousBoostPreset = ["nmot", "wped_w", "wdkba", "rl_w", "rlsol_w", "rlmax_w", "plsol", "pvdkds_w", "pu_w",
                                       "ldtvm", "ldrlts_w", "B_ldsua", "zwout", "tans", "lamsoni_w", "lamsoni2_w"].joined(separator: ",")
            if varsCsv == previousBoostPreset || varsCsv.isEmpty, let first = EcuDef.presets.first {
                varsCsv = first.1.filter { name in EcuDef.all.contains { $0.name == name } }.joined(separator: ",")
            }
        }
    }
}

struct MainScreen: View {
    let page: MainPage
    @ObservedObject var link: Me7Link
    @ObservedObject var navigation: CarouselNavigation
    @AppStorage("host") private var host = "192.168.0.10"
    @AppStorage("port") private var port = "35000"
    @AppStorage("proto") private var proto = "4"
    @AppStorage("init") private var initAddress = "01"
    @AppStorage("header") private var header = "8101F1"
    @AppStorage("sessions") private var sessions = "1089,1086,-"
    @AppStorage("maxBytes") private var maxBytes = "64"
    @AppStorage("vars") private var varsCsv = ""
    @State private var showVars = false

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
        switch page {
        case .connection:
            CayenneConnectionView(link: link, makeSettings: settings)
        case .errors:
            NavigationStack(path: $navigation.errorPath) {
                ErrorsView(link: link, makeSettings: settings)
            }
        case .logs:
            NavigationStack {
                LoggingScreen(link: link, varsCsv: $varsCsv, showVars: $showVars, makeSettings: settings, applyPreset: preset)
            }
            .sheet(isPresented: $showVars) { VarPicker(selectedCsv: $varsCsv) }
        case .settings:
            NavigationStack {
                Form {
                    Section {
                        StatusBox(state: link.elmState, text: link.elmText)
                            .accessibilityElement(children: .combine)
                        field("IP-адрес", $host, keyboard: .numbersAndPunctuation)
                        field("Порт", $port, keyboard: .numberPad)
                    } header: {
                        Label("Адаптер ELM327", systemImage: "wifi")
                    }
                    Section {
                        field("Протокол ELM", $proto, keyboard: .numberPad)
                        field("Адрес блока", $initAddress)
                        field("Заголовок KWP", $header)
                        field("Сессии", $sessions, keyboard: .numbersAndPunctuation)
                        field("Макс. байт", $maxBytes, keyboard: .numberPad)
                    } header: {
                        Label("Блок двигателя", systemImage: "cpu")
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Настройки")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func field(_ title: String, _ value: Binding<String>, keyboard: UIKeyboardType = .asciiCapable) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField(title, text: value)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}

/// Clear connection states with a compact icon, tinted background, and wrapped diagnostic text.
struct StatusBox: View {
    let state: LinkState
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 22, height: 22)
                .padding(7)
                .background(color.opacity(0.15), in: Circle())
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(color)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(color.opacity(0.18), lineWidth: 1))
    }

    private var symbol: String {
        switch state {
        case .ok: return "checkmark"
        case .fail: return "exclamationmark"
        case .busy: return "ellipsis"
        case .idle: return "circle"
        }
    }

    private var color: Color {
        switch state {
        case .ok: return Color(red: 0.12, green: 0.62, blue: 0.34)
        case .fail: return Color(red: 0.82, green: 0.20, blue: 0.20)
        case .busy: return Color(red: 0.88, green: 0.55, blue: 0.08)
        case .idle: return Color.secondary
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
                || $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        sel = Set(EcuDef.all.map(\.name))
                    } label: {
                        Label("Выбрать все", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.cyan)
                    .disabled(EcuDef.all.allSatisfy { sel.contains($0.name) })

                    Button {
                        sel.removeAll()
                    } label: {
                        Label("Снять все", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(sel.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                List(filtered) { m in
                    Button {
                        if sel.contains(m.name) { sel.remove(m.name) } else { sel.insert(m.name) }
                    } label: {
                        HStack {
                            Image(systemName: sel.contains(m.name) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(m.displayName)
                                    .font(.body.weight(.medium)).lineLimit(2)
                                Text(m.name)
                                    .font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
                .listStyle(.plain)
                .searchable(text: $query)
            }
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
