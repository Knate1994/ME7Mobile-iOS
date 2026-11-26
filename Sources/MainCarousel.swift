import Combine
import SwiftUI
import UIKit

enum MainPage: Int, CaseIterable {
    case errors, connection, logs, settings

    func neighbor(_ step: Int) -> MainPage {
        let pages = MainPage.allCases
        return pages[(rawValue + step + pages.count) % pages.count]
    }

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

@MainActor final class CarouselNavigation: ObservableObject {
    @Published fileprivate(set) var visiblePage: MainPage = .connection
    @Published var errorPath: [DiagnosticPage] = []
    fileprivate let tabSelections = PassthroughSubject<MainPage, Never>()

    func select(_ page: MainPage) {
        // Tapping the current tab also cancels a swipe still in progress.
        if visiblePage != page { visiblePage = page }
        tabSelections.send(page)
    }
}

struct CarouselBar: View {
    let selection: MainPage
    let select: (MainPage) -> Void
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MainPage.allCases, id: \.self) { page in
                let active = page == selection
                Button {
                    select(page)
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

/// Each section owns one hosting controller for the lifetime of the carousel.
struct MainCarousel: UIViewControllerRepresentable {
    let link: Me7Link
    let navigation: CarouselNavigation

    func makeUIViewController(context: Context) -> CarouselController {
        CarouselController(link: link, navigation: navigation)
    }

    func updateUIViewController(_ controller: CarouselController, context: Context) {}
}

@MainActor final class CarouselController: UIViewController, UIScrollViewDelegate {
    private let scroll = CarouselScrollView()
    private let navigation: CarouselNavigation
    private let screens: [UIHostingController<MainScreen>]
    private var selection: AnyCancellable?
    private var swipeOrigin: MainPage?
    private var lastSize = CGSize.zero

    init(link: Me7Link, navigation: CarouselNavigation) {
        self.navigation = navigation
        screens = MainPage.allCases.map {
            UIHostingController(rootView: MainScreen(page: $0, link: link, navigation: navigation))
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(link:navigation:)") }

    override func loadView() { view = scroll }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.delegate = self
        scroll.isPagingEnabled = true
        scroll.bounces = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.scrollsToTop = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.preservesBackGesture = { [weak self] in
            guard let self else { return false }
            return self.navigation.visiblePage == .errors && !self.navigation.errorPath.isEmpty
        }
        scroll.accessibilityPage = { [weak self] offset in
            guard let self else { return }
            let page = self.navigation.visiblePage.neighbor(offset)
            self.navigation.select(page)
            UIAccessibility.post(notification: .pageScrolled, argument: page.title)
        }
        for screen in screens {
            addChild(screen)
            scroll.addSubview(screen.view)
            screen.didMove(toParent: self)
        }
        selection = navigation.tabSelections.sink { [weak self] page in
            guard let self else { return }
            // A tab tap wins immediately, even when the finger is down or the page is coasting.
            self.cancelSwipe()
            for other in MainPage.allCases where other != page {
                self.screens[other.rawValue].view.endEditing(true)
            }
            self.positionScreens(around: page, recenter: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scroll.bounds.size
        guard size != lastSize else { return }
        let widthChanged = size.width != lastSize.width
        lastSize = size
        if widthChanged { cancelSwipe() }
        positionScreens(around: navigation.visiblePage, recenter: widthChanged)
    }

    private func cancelSwipe() {
        swipeOrigin = nil
        if scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
            scroll.isScrollEnabled = false
            scroll.isScrollEnabled = true
        }
    }

    private func positionScreens(around page: MainPage, recenter: Bool) {
        let size = scroll.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // The three slots always hold previous, current and next, including across the wrap.
        // Recenter without animation: the destination occupies the same pixels before and after.
        UIView.performWithoutAnimation { [self] in
            scroll.contentSize = CGSize(width: 3 * size.width, height: size.height)
            for item in MainPage.allCases {
                let screen = screens[item.rawValue].view!
                let slot: Int
                switch item {
                case page.neighbor(-1): slot = 0
                case page: slot = 1
                case page.neighbor(1): slot = 2
                default:
                    screen.isHidden = true
                    continue
                }
                screen.frame = CGRect(x: CGFloat(slot) * size.width, y: 0, width: size.width, height: size.height)
                screen.isHidden = false
                screen.accessibilityElementsHidden = item != page
            }
            if recenter { scroll.contentOffset = CGPoint(x: size.width, y: 0) }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A second swipe can catch the first one mid-deceleration. Shift the slots under
        // the finger by exactly one width, keeping every visible pixel in place.
        finishSwipe(continuingDrag: true)
        swipeOrigin = navigation.visiblePage
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard swipeOrigin != nil else { return }
        if scrollView.panGestureRecognizer.state == .cancelled || scrollView.panGestureRecognizer.state == .failed {
            cancelSwipe()
            positionScreens(around: navigation.visiblePage, recenter: true)
        } else if !decelerate {
            finishSwipe()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishSwipe()
    }

    private func finishSwipe(continuingDrag: Bool = false) {
        guard let origin = swipeOrigin, origin == navigation.visiblePage, scroll.bounds.width > 0 else { return }
        swipeOrigin = nil
        let slot = Int((scroll.contentOffset.x / scroll.bounds.width).rounded())
        let step = min(2, max(0, slot)) - 1
        let page = origin.neighbor(step)
        let shiftedX = scroll.contentOffset.x - CGFloat(step) * scroll.bounds.width
        if page != origin {
            navigation.visiblePage = page
            screens[origin.rawValue].view.endEditing(true)
        }
        if continuingDrag {
            if step != 0 {
                positionScreens(around: page, recenter: false)
                scroll.contentOffset = CGPoint(x: shiftedX, y: 0)
            }
        } else {
            positionScreens(around: page, recenter: true)
        }
    }
}

private final class CarouselScrollView: UIScrollView {
    var preservesBackGesture: (() -> Bool)?
    var accessibilityPage: ((Int) -> Void)?

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === panGestureRecognizer else { return super.gestureRecognizerShouldBegin(gesture) }
        let pan = panGestureRecognizer
        let translation = pan.translation(in: self)
        let direction = translation == .zero ? pan.velocity(in: self) : translation
        guard abs(direction.x) > abs(direction.y) * 1.25 else { return false }
        if preservesBackGesture?() == true {
            let start = pan.location(in: self).x - translation.x
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let fromLeadingEdge = rtl ? start >= bounds.maxX - 32 : start <= bounds.minX + 32
            if fromLeadingEdge && (rtl ? direction.x < 0 : direction.x > 0) { return false }
        }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let accessibilityPage, direction == .left || direction == .right else {
            return super.accessibilityScroll(direction)
        }
        accessibilityPage(direction == .left ? 1 : -1)
        return true
    }
}
