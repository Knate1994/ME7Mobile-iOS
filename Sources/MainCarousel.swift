import SwiftUI
import UIKit

enum MainPage: Int, CaseIterable {
    case errors, connection, logs, settings

    var title: String {
        switch self {
        case .errors: return "Ошибки"
        case .connection: return "Подключение"
        case .logs: return "Логи"
        case .settings: return "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .errors: return "exclamationmark.triangle.fill"
        case .connection: return "car.fill"
        case .logs: return "waveform.path.ecg"
        case .settings: return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .errors: return Color(red: 0.64, green: 0.20, blue: 0.22)
        case .connection: return Color(red: 0.65, green: 0.28, blue: 0.08)
        case .logs: return Color(red: 0.07, green: 0.40, blue: 0.42)
        case .settings: return Color(red: 0.33, green: 0.29, blue: 0.60)
        }
    }
}

struct CarouselBar: View {
    @Binding var selection: MainPage
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MainPage.allCases, id: \.self) { page in
                let active = page == selection
                Button {
                    selection = page
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: page.symbol).font(.system(size: 16, weight: .semibold))
                        Text(page.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(page.tint.gradient)
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.09), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.90), value: selection)
    }
}

/// One retained navigation stack per page, including across the last-to-first swipe.
struct MainCarousel: UIViewControllerRepresentable {
    let link: Me7Link
    @Binding var selection: MainPage

    func makeCoordinator() -> Coordinator {
        Coordinator(link: link, selection: $selection)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.setViewControllers([context.coordinator.controllers[selection.rawValue]], direction: .forward, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.showSelection(in: pager)
    }

    @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let controllers: [UIViewController]
        private let selection: Binding<MainPage>
        private var transitioning = false
        private var selectionBeforeSwipe: MainPage?

        init(link: Me7Link, selection: Binding<MainPage>) {
            controllers = MainPage.allCases.map { UIHostingController(rootView: MainScreen(page: $0, link: link)) }
            self.selection = selection
            super.init()
        }

        private func neighbor(of controller: UIViewController, offset: Int) -> UIViewController? {
            guard let i = controllers.firstIndex(of: controller) else { return nil }
            return controllers[(i + offset + controllers.count) % controllers.count]
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
            neighbor(of: controller, offset: -1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
            neighbor(of: controller, offset: 1)
        }

        func showSelection(in pager: UIPageViewController) {
            let target = selection.wrappedValue.rawValue
            guard !transitioning, let visible = pager.viewControllers?.first,
                  let current = controllers.firstIndex(of: visible), current != target else { return }
            let distance = (target - current + controllers.count) % controllers.count
            let direction: UIPageViewController.NavigationDirection = distance <= controllers.count / 2 ? .forward : .reverse
            transitioning = true
            pager.view.isUserInteractionEnabled = false
            pager.setViewControllers([controllers[target]], direction: direction, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak pager] _ in
                guard let self, let pager else { return }
                pager.view.isUserInteractionEnabled = true
                self.transitioning = false
                self.showSelection(in: pager)
            }
        }

        func pageViewController(_ pager: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            selectionBeforeSwipe = selection.wrappedValue
        }

        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            // A tap on the bar during a swipe takes precedence once the gesture settles.
            if completed, selectionBeforeSwipe == selection.wrappedValue, let visible = pager.viewControllers?.first,
               let index = controllers.firstIndex(of: visible), let page = MainPage(rawValue: index) {
                selection.wrappedValue = page
            }
            selectionBeforeSwipe = nil
            transitioning = false
            showSelection(in: pager)
        }
    }
}
