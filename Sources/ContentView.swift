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
    @State private var showTrace = false
    @State private var currentPage = 2
    @State private var pageNavigationRequestID = 0

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
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            TabView(selection: $currentPage) {
                loggingPage.tag(0)
                errorsPage.tag(1)
                connectionPage.tag(2)
                loggingPage.tag(3)
                errorsPage.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .bottom, spacing: 0) { pageNavigation }
        }
        .sheet(isPresented: $showVars) { VarPicker(selectedCsv: $varsCsv) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true      // keep the screen on in the car
            if varsCsv.isEmpty, let p = EcuDef.presets.first { preset(p.1) }
        }
        .onChange(of: currentPage) { page in
            pageNavigationRequestID += 1
            guard page == 0 || page == 4 else { return }
            DispatchQueue.main.async {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { currentPage = page == 0 ? 3 : 1 }
            }
        }
    }

    private var connectionPage: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    appHeader
                    connectionButton
                    HStack(spacing: 10) {
                        connectionStatus("ELM327", state: link.elmState, text: link.elmText, symbol: "wifi")
                        connectionStatus("ЭБУ двигателя", state: link.ecuState, text: link.ecuText, symbol: "cpu")
                    }
                    swipeHint
                    settingsPanel
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var loggingPage: some View {
        NavigationStack {
            LoggingScreen(link: link, varsCsv: $varsCsv, showVars: $showVars, makeSettings: settings, applyPreset: preset)
        }
    }

    private var errorsPage: some View {
        NavigationStack {
            ErrorsView(link: link, makeSettings: settings)
        }
    }

    private var connectionButton: some View {
        Button {
            link.connectAll(settings())
        } label: {
            VStack(spacing: 10) {
                if link.elmState == .busy || link.ecuState == .busy {
                    ProgressView().tint(.white).scaleEffect(1.15)
                } else {
                    Image(systemName: link.elmState == .ok && link.ecuState == .ok ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 38, weight: .medium))
                }
                Text(link.elmState == .ok && link.ecuState == .ok ? "Переподключить" : "Подключить автомобиль")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("ELM327  +  блок двигателя")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 158)
            .background(
                LinearGradient(colors: [Color(red: 0.05, green: 0.57, blue: 0.76), Color(red: 0.10, green: 0.31, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 25, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Color.blue.opacity(0.20), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(link.elmState == .busy || link.ecuState == .busy || link.logging)
    }

    private func connectionStatus(_ title: String, state: LinkState, text: String, symbol: String) -> some View {
        let color: Color = {
            switch state {
            case .ok: return Color(red: 0.10, green: 0.62, blue: 0.34)
            case .fail: return Color(red: 0.82, green: 0.20, blue: 0.20)
            case .busy: return Color(red: 0.88, green: 0.55, blue: 0.08)
            case .idle: return .secondary
            }
        }()
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                Text(title).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(compactStatus(state, text))
                .font(.system(size: 11, weight: state == .fail ? .medium : .semibold))
                .foregroundColor(color)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(state == .idle ? 0.08 : 0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func compactStatus(_ state: LinkState, _ text: String) -> String {
        switch state {
        case .ok: return "Подключено"
        case .busy: return "Подключение…"
        case .idle: return "Ожидает подключения"
        case .fail:
            let details = text.components(separatedBy: "\n").dropFirst().joined(separator: " · ")
            return details.isEmpty ? "Не подключено" : details
        }
    }

    private var swipeHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.right")
            Text("Ошибки")
            Text("·").foregroundColor(.secondary)
            Image(systemName: "arrow.left")
            Text("Логирование")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.vertical, 1)
    }

    private var pageNavigation: some View {
        let selectedPage = currentPage == 2 ? 1 : ((currentPage == 0 || currentPage == 3) ? 2 : 0)
        return HStack(spacing: 8) {
            pageButton("Ошибки", symbol: "exclamationmark.triangle", selected: selectedPage == 0) { navigate(to: 1) }
            pageButton("Подключение", symbol: "antenna.radiowaves.left.and.right", selected: selectedPage == 1) { navigate(to: 2) }
            pageButton("Логирование", symbol: "waveform.path.ecg", selected: selectedPage == 2) { navigate(to: 3) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.22), value: selectedPage)
    }

    private func navigate(to page: Int) {
        pageNavigationRequestID += 1
        let requestID = pageNavigationRequestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard requestID == pageNavigationRequestID else { return }
            withAnimation(.easeInOut(duration: 0.32)) {
                currentPage = page
            }
        }
    }

    private func pageButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 10, weight: selected ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(selected ? .cyan : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 39)
            .background(selected ? Color.cyan.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text("ME7Mobile").font(.system(size: 21, weight: .bold, design: .rounded))
                Text("Cayenne Turbo · ME7.1.1").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(link.elmState == .ok ? .green : .secondary)
                .padding(10)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
                .accessibilityLabel(link.elmState == .ok ? "ELM подключён" : "ELM не подключён")
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var settingsPanel: some View {
        panel {
            DisclosureGroup(isExpanded: $showSettings) {
                VStack(spacing: 8) {
                    field("ELM IP", $host, keyboard: .numbersAndPunctuation)
                    field("Порт", $port, keyboard: .numberPad)
                    field("Протокол ELM", $proto, keyboard: .numberPad)
                    field("Адрес блока", $initAddress)
                    field("Заголовок KWP", $header)
                    field("Сессии", $sessions, keyboard: .numbersAndPunctuation)
                    field("Макс. байт", $maxBytes, keyboard: .numberPad)
                }
                .padding(.top, 10)
            } label: {
                Label("Настройки соединения", systemImage: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .tint(.secondary)
        }
    }

    private var elmPanel: some View {
        panel {
            sectionHeading("01", "Адаптер ELM327", "Wi‑Fi · \(host):\(port)", symbol: "wifi")
            StatusBox(state: link.elmState, text: link.elmText)
            HStack(spacing: 9) {
                actionButton("Подключить", symbol: "link", enabled: link.elmState != .busy && !link.logging && link.ecuState != .busy) {
                    link.connectElm(settings())
                }
                actionButton("Отключить", symbol: "xmark", enabled: (link.elmState == .ok || link.elmState == .busy) && !link.logging) {
                    link.disconnect()
                }
            }
        }
    }

    private var ecuPanel: some View {
        panel {
            sectionHeading("02", "Блок двигателя", "Подключение к ЭБУ", symbol: "cpu")
            StatusBox(state: link.ecuState, text: link.ecuText)
            HStack(spacing: 9) {
                actionButton("Подключить ЭБУ", symbol: "bolt.horizontal.circle", enabled: link.elmState == .ok && link.ecuState != .busy && !link.logging) {
                    link.connectEcu(settings())
                }
                actionButton("Проверить шину", symbol: "waveform.path", enabled: link.elmState == .ok && link.ecuState != .busy && !link.logging) {
                    link.probeBus()
                }
            }
        }
    }

    private var navigationPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("ДИАГНОСТИКА")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundColor(.secondary)

            NavigationLink {
                ErrorsView(link: link, makeSettings: settings)
            } label: {
                navigationCard("Ошибки", detail: "Двигатель · АКПП · ABS/ESP · подвеска", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            .buttonStyle(.plain)

            NavigationLink {
                LoggingScreen(link: link, varsCsv: $varsCsv, showVars: $showVars, makeSettings: settings, applyPreset: preset)
            } label: {
                navigationCard("Логирование", detail: "Запись параметров двигателя", symbol: "waveform.path.ecg", tint: .cyan)
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func navigationCard(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(.primary)
                Text(detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(12)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var dtcPanel: some View {
        panel {
            sectionHeading("DTC", "Ошибки ЭБУ", "Коды неисправностей", symbol: "exclamationmark.triangle")
            StatusBox(state: link.dtcState, text: link.dtcText)
            HStack(spacing: 9) {
                actionButton("Прочитать", symbol: "arrow.clockwise", enabled: link.ecuState == .ok && !link.logging && link.dtcState != .busy) {
                    link.readDtc()
                }
                actionButton("Стереть", symbol: "trash", enabled: link.ecuState == .ok && !link.logging && link.dtcState != .busy) {
                    confirmClear = true
                }
            }
        }
    }

    private var recordingPanel: some View {
        panel {
            sectionHeading("03", "Запись параметров", "Выбрано: \(selected.count) переменных", symbol: "record.circle")
            if !link.logText.isEmpty {
                Text(link.logText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 9) {
                actionButton("Переменные", symbol: "list.bullet", enabled: !link.logging) { showVars = true }
                Menu {
                    ForEach(EcuDef.presets.indices, id: \.self) { i in
                        Button(EcuDef.presets[i].0) { preset(EcuDef.presets[i].1) }
                    }
                } label: {
                    Label("Наборы", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
                .disabled(link.logging)
            }
            Button {
                if link.logging { link.stopLog() } else { link.startLog(settings(), selected) }
            } label: {
                Label(link.logging ? "Остановить запись" : "Начать запись", systemImage: link.logging ? "stop.fill" : "record.circle")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(link.logging ? .red : .green)
            .disabled(!(link.logging || link.ecuState == .ok) || link.dtcState == .busy || (!link.logging && selected.isEmpty))
        }
    }

    private var livePanel: some View {
        panel {
            HStack(alignment: .center) {
                sectionHeading("", "Показания", "Данные двигателя", symbol: "gauge")
                Spacer(minLength: 4)
                if !link.live.isEmpty {
                    Text(String(format: "%.1f Гц", link.hz))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.cyan.opacity(0.13), in: Capsule())
                        .foregroundColor(.cyan)
                }
            }
            if link.live.isEmpty {
                Text(selected.map { $0.name }.joined(separator: "  ·  "))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(link.live.indices, id: \.self) { index in
                        let v = link.live[index]
                        HStack(spacing: 8) {
                            Text(v.id)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: "%.2f", v.value))
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            Text(v.unit)
                                .foregroundColor(.secondary)
                                .frame(minWidth: 42, alignment: .leading)
                        }
                        .font(.system(size: 15, design: .monospaced))
                        .padding(.vertical, 9)
                        if index < link.live.count - 1 {
                            Divider().opacity(0.6)
                        }
                    }
                }
            }
        }
    }

    private var tracePanel: some View {
        panel {
            DisclosureGroup(isExpanded: $showTrace) {
                ScrollView {
                    Text(link.trace.suffix(120).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .frame(height: 190)
            } label: {
                HStack {
                    Label("Журнал обмена", systemImage: "terminal")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(link.trace.count) строк")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.primary)
            }
            .tint(.secondary)
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(15)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }

    private func sectionHeading(_ index: String, _ title: String, _ detail: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.cyan)
                .frame(width: 38, height: 38)
                .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !index.isEmpty {
                        Text(index).foregroundColor(.cyan)
                    }
                    Text(title).foregroundColor(.primary)
                }
                .font(.system(size: 15, weight: .bold))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func field(_ label: String, _ value: Binding<String>, keyboard: UIKeyboardType = .asciiCapable) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading).font(.subheadline)
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private func actionButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 42)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
            .buttonStyle(.bordered)
            .tint(.cyan)
            .disabled(!enabled)
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
                                Text(m.name).font(.system(.body, design: .monospaced))
                                Text(m.alias.isEmpty ? m.comment : m.alias)
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
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
