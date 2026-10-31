import SwiftUI
import UIKit

struct LoggingScreen: View {
    @ObservedObject var link: Me7Link
    @Binding var varsCsv: String
    @Binding var showVars: Bool
    let makeSettings: () -> Settings
    let applyPreset: ([String]) -> Void
    @State private var showTrace = false

    private var selected: [Measurement] {
        let names = Set(varsCsv.split(separator: ",").map(String.init))
        return EcuDef.all.filter { names.contains($0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                panel {
                    heading("Запись параметров", detail: "Выбрано: \(selected.count) переменных", symbol: "record.circle")
                    StatusBox(state: link.ecuState, text: link.ecuText)
                    if !link.logText.isEmpty {
                        Text(link.logText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 9) {
                        actionButton("Переменные", symbol: "list.bullet", enabled: !link.logging) { showVars = true }
                        Menu {
                            ForEach(EcuDef.presets.indices, id: \.self) { index in
                                Button(EcuDef.presets[index].0) { applyPreset(EcuDef.presets[index].1) }
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
                        if link.logging { link.stopLog() } else { link.startLog(makeSettings(), selected) }
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

                panel {
                    HStack(alignment: .center) {
                        heading("Показания", detail: "Текущие данные двигателя", symbol: "gauge.with.needle")
                        Spacer(minLength: 4)
                        if !link.live.isEmpty {
                            Text(String(format: "%.1f Гц", link.hz))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color.cyan.opacity(0.13), in: Capsule())
                                .foregroundStyle(.cyan)
                        }
                    }
                    if link.live.isEmpty {
                        Text("После запуска записи параметры появятся здесь.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(link.live.indices, id: \.self) { index in
                                let value = link.live[index]
                                HStack(spacing: 8) {
                                    Text(value.id).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(String(format: "%.2f", value.value)).fontWeight(.bold)
                                    Text(value.unit).foregroundStyle(.secondary).frame(minWidth: 42, alignment: .leading)
                                }
                                .font(.system(size: 14, design: .monospaced))
                                .padding(.vertical, 9)
                                if index < link.live.count - 1 { Divider().opacity(0.6) }
                            }
                        }
                    }
                }

                panel {
                    DisclosureGroup(isExpanded: $showTrace) {
                        ScrollView {
                            Text(link.trace.suffix(120).joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        .frame(height: 210)
                    } label: {
                        HStack {
                            Label("Журнал обмена", systemImage: "terminal")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text("\(link.trace.count) строк")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .tint(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Логирование")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(15)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func heading(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 38, height: 38)
                .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
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
