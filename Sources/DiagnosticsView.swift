import SwiftUI
import UIKit

struct ErrorsView: View {
    @ObservedObject var link: Me7Link
    let makeSettings: () -> Settings
    @State private var confirmClearAll = false

    private let columns = [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Выбери блок управления, чтобы прочитать или удалить его ошибки.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    confirmClearAll = true
                } label: {
                    HStack(spacing: 11) {
                        if link.clearAllState == .busy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "trash.fill").font(.system(size: 17, weight: .bold))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(link.clearAllState == .busy ? "Удаляем ошибки…" : "Удалить ошибки во всех блоках")
                                .font(.system(size: 15, weight: .bold))
                                .multilineTextAlignment(.leading)
                            if link.clearAllState != .busy {
                                Text("Двигатель · АКПП · ABS/ESP · подвеска")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.82))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .padding(.horizontal, 15)
                    .foregroundStyle(.white)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(link.elmState != .ok || link.clearAllState == .busy)

                if link.clearAllState != .idle {
                    Label(link.clearAllText, systemImage: link.clearAllState == .ok ? "checkmark.circle.fill" : (link.clearAllState == .busy ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(link.clearAllState == .ok ? Color.green : (link.clearAllState == .busy ? Color.orange : Color.red))
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: columns, spacing: 11) {
                    ForEach(DtcModule.allCases) { module in
                        NavigationLink {
                            ModuleErrorsView(link: link, module: module, makeSettings: makeSettings)
                        } label: {
                            ModuleTile(module: module, diagnostic: link.moduleDiagnostics[module] ?? ModuleDiagnostic())
                        }
                        .buttonStyle(.plain)
                        .disabled(link.clearAllState == .busy)
                    }
                }

                NavigationLink {
                    BlockScanView(link: link, makeSettings: makeSettings)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 42, height: 42)
                            .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Тест блоков")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.primary)
                            Text("Опрос возможных адресов и вариантов подключения")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(link.clearAllState == .busy)

                Label("Подключение к модулю проверяется отдельно. Если блок не отвечает, причина будет показана на его странице и записана в журнале.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Ошибки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog("Удалить ошибки из всех блоков?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Удалить во всех блоках", role: .destructive) { link.clearAllDtc(makeSettings()) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Приложение по очереди подключится к двигателю, АКПП, ABS/ESP и подвеске. Из каждого блока будут удалены сохранённые ошибки, если блок ответит и подтвердит команду.")
        }
    }
}

private struct ModuleTile: View {
    let module: DtcModule
    let diagnostic: ModuleDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: module.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 42, height: 42)
                    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Spacer(minLength: 0)
                Circle()
                    .fill(stateColor(diagnostic.connectionState))
                    .frame(width: 9, height: 9)
            }
            Text(module.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(diagnostic.dtcState == .ok ? diagnostic.dtcText : module.subtitle)
                .font(.caption)
                .foregroundStyle(diagnostic.dtcState == .ok && !diagnostic.codes.isEmpty ? Color.orange : Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}

struct ModuleErrorsView: View {
    @ObservedObject var link: Me7Link
    let module: DtcModule
    let makeSettings: () -> Settings
    @State private var confirmClear = false

    private var diagnostic: ModuleDiagnostic {
        link.moduleDiagnostics[module] ?? ModuleDiagnostic()
    }

    private var busy: Bool {
        diagnostic.connectionState == .busy || diagnostic.dtcState == .busy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                moduleHeader
                StatusBox(state: diagnostic.connectionState, text: diagnostic.connectionText)
                softwareCard
                connectionButton
                errorActions
                dtcResults
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(module.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog("Удалить ошибки из блока «\(module.title)»?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить ошибки", role: .destructive) { link.clearDtc(module) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут удалены коды только из выбранного блока. Сначала сохраните или сфотографируйте их, если они нужны для ремонта.")
        }
    }

    private var moduleHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: module.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title).font(.system(size: 19, weight: .bold))
                Text(module.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private var softwareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Номер ПО / идентификация блока", systemImage: "number.square")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(diagnostic.softwareNumber)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(diagnostic.softwareNumber == "Не прочитан" ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var connectionButton: some View {
        Button {
            link.connectModule(module, makeSettings())
        } label: {
            Label(diagnostic.connectionState == .ok ? "Переподключиться" : "Подключиться к блоку", systemImage: "bolt.horizontal.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .disabled(link.elmState != .ok || busy)
    }

    private var errorActions: some View {
        HStack(spacing: 10) {
            Button {
                link.readDtc(module)
            } label: {
                Label("Прочитать", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.bordered)
            .tint(.cyan)
            .disabled(diagnostic.connectionState != .ok || busy)

            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Удалить", systemImage: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.bordered)
            .disabled(diagnostic.connectionState != .ok || diagnostic.dtcState != .ok || diagnostic.codes.isEmpty || busy)
        }
    }

    @ViewBuilder
    private var dtcResults: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Коды неисправностей")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                if diagnostic.dtcState == .busy { ProgressView().controlSize(.small) }
            }

            if diagnostic.dtcState == .idle {
                emptyMessage("Подключись к блоку и нажми «Прочитать».", symbol: "doc.text.magnifyingglass", color: .secondary)
            } else if diagnostic.dtcState == .busy {
                emptyMessage(diagnostic.dtcText, symbol: "arrow.triangle.2.circlepath", color: .orange)
            } else if diagnostic.dtcState == .fail {
                emptyMessage(diagnostic.dtcText, symbol: "exclamationmark.triangle.fill", color: .red)
            } else if diagnostic.codes.isEmpty {
                emptyMessage("Ошибок нет", symbol: "checkmark.circle.fill", color: .green)
            } else {
                Label(diagnostic.dtcText, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(diagnostic.codes) { code in
                    DtcCard(code: code)
                }
            }
        }
        .padding(15)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func emptyMessage(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
    }
}

private struct DtcCard: View {
    let code: DtcEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(code.code)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Text(code.statusText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(code.description)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Исходный код блока: 0x\(code.rawWord)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.orange.opacity(0.17), lineWidth: 1))
    }
}

struct BlockScanView: View {
    @ObservedObject var link: Me7Link
    let makeSettings: () -> Settings
    @AppStorage("blockScanBridgeState") private var bridgeState = "Не указано"
    @State private var showingTraceShare = false

    private var scanning: Bool { link.blockScanState == .busy }
    private var answeredCount: Int { link.blockScanResults.filter(\.responded).count }
    private var unverifiedCount: Int { link.blockScanResults.filter { !$0.responded && $0.hasUnverifiedResponse }.count }
    private var negativeResponseCount: Int {
        link.blockScanResults.filter { !$0.responded && !$0.hasUnverifiedResponse && $0.receivedNegativeResponse }.count
    }
    private var channelOnlyCount: Int {
        link.blockScanResults.filter { !$0.responded && !$0.hasUnverifiedResponse && !$0.receivedNegativeResponse && $0.transportOpened }.count
    }
    private var checkedWithoutAnswerCount: Int {
        link.blockScanResults.filter {
            !$0.responded && !$0.receivedNegativeResponse && !$0.transportOpened && !$0.attempts.isEmpty
                && !$0.hasUnverifiedResponse
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                explanationCard
                bridgeCard
                scanButton

                if link.blockScanTotal > 0 {
                    progressCard
                    summaryCounts
                }

                if !link.blockScanResults.isEmpty {
                    Text("Адреса блоков")
                        .font(.system(size: 18, weight: .bold))
                        .padding(.top, 3)
                    ForEach(link.blockScanResults) { result in
                        BlockScanResultCard(result: result)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Тест блоков")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    link.prepareTraceExport()
                    showingTraceShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(link.traceFileURL == nil)
                .accessibilityLabel("Поделиться полной трассой")
            }
        }
        .sheet(isPresented: $showingTraceShare) {
            if let url = link.traceFileURL {
                TraceShareSheet(items: [url])
            }
        }
        .onAppear { link.noteBlockScanScreenOpened(bridgeState: bridgeState) }
        .onChange(of: bridgeState) { newValue in
            link.noteBlockScanBridgeStateChanged(newValue)
        }
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Проверка связи с блоками", systemImage: "waveform.path.ecg")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.cyan)
            Text("Проверим адреса из профиля Touareg 7L, сопоставив их с твоим Cayenne 955. Для двигателя и приборной панели также учтены физические адреса из приложенных трасс.")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Положительный ответ на запрос сеанса сам по себе не считается найденным блоком: для зелёного результата нужен читаемый идентификатор. TP1.6 проверяется на PSM и подвеске. Опрос только читает ответы и не стирает ошибки, не кодирует блоки и не запускает исполнительные механизмы. Полная трасса сохраняет команды, ответы, таймауты и итоги.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var bridgeCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Перемычка OBD 3–7", systemImage: "cable.connector")
                .font(.system(size: 14, weight: .semibold))
            Picker("Состояние перемычки", selection: $bridgeState) {
                Text("Не указано").tag("Не указано")
                Text("Разомкнута").tag("Разомкнута")
                Text("Замкнута").tag("Замкнута")
            }
            .pickerStyle(.segmented)
            Text("Приложение не видит тумблер физически. Если переключишь его во время опроса, сразу отметь новое положение здесь — отметка попадёт в трассу.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var scanButton: some View {
        Button {
            if scanning {
                link.stopBlockScan()
            } else {
                link.scanAllBlocks(makeSettings(), bridgeState: bridgeState)
            }
        } label: {
            HStack(spacing: 10) {
                if scanning {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .bold))
                }
                Text(scanning ? "Остановить после текущей проверки" : "Опросить все блоки")
                    .font(.system(size: 16, weight: .bold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .padding(.horizontal, 16)
            .foregroundStyle(.white)
            .background(scanning ? Color.orange : Color.cyan, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(link.elmState != .ok && !scanning)

        if link.elmState != .ok && !scanning {
            Label("Сначала подключи ELM327 на главном экране.", systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Ход опроса").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(link.blockScanProgress) / \(link.blockScanTotal)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(link.blockScanProgress), total: Double(max(link.blockScanTotal, 1)))
                .tint(scanning ? .cyan : (link.blockScanState == .fail ? .red : .green))
            Text(link.blockScanStatus)
                .font(.footnote)
                .foregroundStyle(link.blockScanState == .fail ? .red : (scanning ? .orange : .secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var summaryCounts: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ScanCount(title: "Ответили", count: answeredCount, color: .green)
            ScanCount(title: "Ответ есть · ID не подтверждён", count: unverifiedCount, color: .orange)
            ScanCount(title: "Ответили отказом", count: negativeResponseCount, color: .purple)
            ScanCount(title: "Канал открыт", count: channelOnlyCount, color: .orange)
            ScanCount(title: "Без ответа", count: checkedWithoutAnswerCount, color: .secondary)
        }
    }
}

private struct ScanCount: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 5)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct BlockScanResultCard: View {
    let result: BlockScanResult
    @State private var expanded = false

    private var color: Color {
        if result.responded { return .green }
        if result.hasUnverifiedResponse { return .orange }
        if result.receivedNegativeResponse { return .purple }
        if result.transportOpened { return .orange }
        return result.attempts.isEmpty ? .secondary : .red
    }

    private var summary: String {
        if result.responded { return "Получен ответ блока" }
        if result.hasUnverifiedResponse { return "Есть отклик, номер блока не подтверждён" }
        if result.receivedNegativeResponse { return "ECU ответил, но отказал в проверочном сервисе" }
        if result.transportOpened { return "Транспортный канал есть · KWP молчит" }
        return result.attempts.isEmpty ? "Ожидает проверки" : "Ответа нет"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text("0x\(result.target.addressText) · \(result.target.title)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(summary).font(.caption.weight(.medium)).foregroundStyle(color)
                }
                Spacer(minLength: 0)
            }

            if !result.attempts.isEmpty {
                DisclosureGroup("Подробности · \(result.attempts.count) способов", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(result.attempts) { attempt in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: attemptSymbol(attempt.state))
                                        .foregroundStyle(attemptColor(attempt.state))
                                    Text(attempt.mode).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                                }
                                Text(attempt.detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption.weight(.medium))
                .tint(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(color.opacity(0.14), lineWidth: 1))
    }

    private func attemptSymbol(_ state: BlockScanAttemptState) -> String {
        switch state {
        case .responded: return "checkmark.circle.fill"
        case .unverifiedResponse: return "questionmark.circle.fill"
        case .negativeResponse: return "exclamationmark.circle.fill"
        case .channelOnly: return "circle.lefthalf.filled"
        case .noResponse: return "xmark.circle.fill"
        }
    }

    private func attemptColor(_ state: BlockScanAttemptState) -> Color {
        switch state {
        case .responded: return .green
        case .unverifiedResponse: return .orange
        case .negativeResponse: return .purple
        case .channelOnly: return .orange
        case .noResponse: return .red
        }
    }
}

private struct TraceShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private func stateColor(_ state: LinkState) -> Color {
    switch state {
    case .ok: return .green
    case .fail: return .red
    case .busy: return .orange
    case .idle: return .secondary
    }
}
