import SwiftUI

struct CayenneConnectionView: View {
    @ObservedObject var link: Me7Link
    let makeSettings: () -> Settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connected: Bool { link.elmState == .ok }

    var body: some View {
        GeometryReader { bounds in
            let width = max(1, min(bounds.size.width * 0.95, bounds.size.height * 1.28, 620))
            ZStack {
                LinearGradient(colors: scheme == .dark
                    ? [Color(red: 0.045, green: 0.08, blue: 0.12), Color(red: 0.14, green: 0.17, blue: 0.20), Color(red: 0.07, green: 0.065, blue: 0.075)]
                    : [Color(red: 0.89, green: 0.93, blue: 0.95), Color(red: 0.99, green: 0.95, blue: 0.89), Color(red: 0.92, green: 0.87, blue: 0.81)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                Ellipse()
                    .fill(Color.orange.opacity(scheme == .dark ? 0.20 : 0.15))
                    .frame(width: width * 0.86, height: width * 0.36)
                    .blur(radius: width * 0.13)
                    .accessibilityHidden(true)
                Button {
                    if connected { link.disconnect() } else { link.connectElm(makeSettings()) }
                } label: {
                    Image("Cayenne955")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .background(alignment: .bottom) {
                            Ellipse()
                                .fill(Color.black.opacity(scheme == .dark ? 0.48 : 0.24))
                                .frame(width: width * 0.83, height: width * 0.067)
                                .blur(radius: width * 0.028)
                                .offset(y: -width * 0.031)
                        }
                        .overlay {
                            // Projector centers in the original 1536 × 1024 cutout.
                            GeometryReader { image in
                                let size = image.size
                                Group {
                                    headlight(diameter: size.width * 0.109)
                                        .position(x: size.width * 150 / 1536, y: size.height * 450 / 1024)
                                    headlight(diameter: size.width * 0.135)
                                        .position(x: size.width * 893 / 1536, y: size.height * 452 / 1024)
                                }
                                .opacity(connected ? 1 : 0)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: connected)
                            }
                            .allowsHitTesting(false)
                        }
                        .frame(width: width)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CarPressStyle(reduceMotion: reduceMotion))
                .disabled(link.elmState == .busy || link.logging || link.clearAllState == .busy || link.blockScanState == .busy)
                .accessibilityLabel(connected ? "Отключить ELM327" : "Подключить ELM327")
                .accessibilityValue(link.elmText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headlight(diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.17),
                .init(color: Color(red: 0.91, green: 0.96, blue: 1), location: 0.24),
                .init(color: Color(red: 0.77, green: 0.87, blue: 1).opacity(0.61), location: 0.34),
                .init(color: .white.opacity(0.18), location: 0.58),
                .init(color: .white.opacity(0), location: 1)
            ], center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
    }
}

private struct CarPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.972 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.80), value: configuration.isPressed)
    }
}
