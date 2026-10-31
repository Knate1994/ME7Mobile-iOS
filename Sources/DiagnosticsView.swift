import SwiftUI
import UIKit

struct ErrorsView: View {
    @ObservedObject var link: Me7Link
    let makeSettings: () -> Settings

    private let columns = [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Выбери блок управления, чтобы прочитать или удалить его ошибки.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, spacing: 11) {
                    ForEach(DtcModule.allCases) { module in
                        NavigationLink {
                            ModuleErrorsView(link: link, module: module, makeSettings: makeSettings)
                        } label: {
                            ModuleTile(module: module, diagnostic: link.moduleDiagnostics[module] ?? ModuleDiagnostic())
                        }
                        .buttonStyle(.plain)
                    }
                }

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

private func stateColor(_ state: LinkState) -> Color {
    switch state {
    case .ok: return .green
    case .fail: return .red
    case .busy: return .orange
    case .idle: return .secondary
    }
}
