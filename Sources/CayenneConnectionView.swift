import SwiftUI

struct CayenneConnectionView: View {
    @ObservedObject var link: Me7Link
    let makeSettings: () -> Settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var connected: Bool { link.elmState == .ok }
    private let buttonGap: CGFloat = 12

    private var buttonTitle: String {
        switch link.elmState {
        case .idle, .fail: return "Подключить"
        case .busy: return link.elmText
        case .ok: return "Отключить"
        }
    }

    var body: some View {
        GeometryReader { bounds in
            let width = min(bounds.size.width * 0.95, 620)
            let buttonWidth = dynamicTypeSize.isAccessibilitySize ? width : min(width, max(240, width * 0.63))
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
                VStack(spacing: buttonGap) {
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
                            GeometryReader { image in
                                headlights(image: image.size, buttonWidth: buttonWidth)
                                    .frame(width: image.size.width, height: image.size.height + buttonGap)
                                    .opacity(connected ? 1 : 0)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: connected)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    Button {
                        if connected { link.disconnect() } else { link.connectElm(makeSettings()) }
                    } label: {
                        HStack(spacing: 8) {
                            if link.elmState == .busy {
                                ProgressView().tint(.white)
                            }
                            Text(buttonTitle)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Color(red: 0.15, green: 0.23, blue: 0.31))
                    .frame(width: buttonWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .overlay {
                        Capsule().strokeBorder(
                            LinearGradient(colors: [.white, .white.opacity(0.1)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 2
                        )
                        .shadow(color: .white, radius: 6, y: -2)
                        .opacity(connected ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: connected)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .disabled(link.elmState == .busy || link.logging || link.clearAllState == .busy || link.blockScanState == .busy)
                    .accessibilityLabel(link.elmState == .busy ? "Адаптер ELM327" : "\(buttonTitle) ELM327")
                    .accessibilityValue(link.elmText)
                }
                .frame(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headlights(image: CGSize, buttonWidth: CGFloat) -> some View {
        Canvas { context, size in
            // Projector centers in the original 1536 × 1024 cutout.
            let left = CGPoint(x: image.width * 150 / 1536, y: image.height * 450 / 1024)
            let right = CGPoint(x: image.width * 893 / 1536, y: image.height * 452 / 1024)
            let spread = buttonWidth * 0.18
            drawHeadlight(in: context, from: left, radius: image.width * 0.055,
                          to: CGPoint(x: size.width / 2 - spread, y: size.height), spread: spread)
            drawHeadlight(in: context, from: right, radius: image.width * 0.067,
                          to: CGPoint(x: size.width / 2 + spread, y: size.height), spread: spread)
        }
    }

    private func drawHeadlight(in context: GraphicsContext, from lamp: CGPoint, radius: CGFloat,
                               to button: CGPoint, spread: CGFloat) {
        var beam = Path()
        beam.move(to: lamp)
        beam.addLine(to: CGPoint(x: button.x - spread, y: button.y))
        beam.addLine(to: CGPoint(x: button.x + spread, y: button.y))
        beam.closeSubpath()
        let ice = Color(red: 0.79, green: 0.89, blue: 1)
        var soft = context
        soft.addFilter(.blur(radius: radius * 0.16))
        soft.fill(beam, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.64), ice.opacity(0.25), ice.opacity(0.12)]),
            startPoint: lamp, endPoint: button))
        let halo = CGRect(x: lamp.x - radius, y: lamp.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: halo), with: .radialGradient(
            Gradient(stops: [.init(color: .white, location: 0.18), .init(color: ice.opacity(0.78), location: 0.33),
                             .init(color: .white.opacity(0), location: 1)]),
            center: lamp, startRadius: 0, endRadius: radius))
    }
}
