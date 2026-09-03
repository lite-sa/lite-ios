#if canImport(UIKit)
import SwiftUI
import UIKit
import Combine
import LiteSDKCore

/// Presentable payment sheet — `UISheetPresentationController` hosting SwiftUI form content.
///
/// ```
/// LitePaymentSheet.present(from: self, clientSecret: secret) { result in … }
/// LitePaymentSheet.present(from: self, clientSecret: secret, configuration: .init(cardLayout: .compact)) { … }
/// ```
@MainActor
public enum LitePaymentSheet {

    public struct Configuration: Sendable {
        public var cardLayout: LiteCardLayout = .compact
        public var defaultStoreForFuture: Bool = false
        /// When true, show the Figma result sheet until the user taps the CTA / close.
        /// Cancelled outcomes never show the result UI — the sheet completes immediately.
        public var showResultBeforeDismiss: Bool = true
        public var applePayEnabled: Bool = true
        /// When set, the secure footer shows a Privacy Policy control that opens this URL.
        public var privacyPolicyUrl: String? = nil

        public init(
            cardLayout: LiteCardLayout = .compact,
            defaultStoreForFuture: Bool = false,
            showResultBeforeDismiss: Bool = true,
            applePayEnabled: Bool = true,
            privacyPolicyUrl: String? = nil
        ) {
            self.cardLayout = cardLayout
            self.defaultStoreForFuture = defaultStoreForFuture
            self.showResultBeforeDismiss = showResultBeforeDismiss
            self.applePayEnabled = applePayEnabled
            self.privacyPolicyUrl = privacyPolicyUrl
        }
    }

    public static func present(
        from presenter: UIViewController,
        clientSecret: String,
        configuration: Configuration = .init(),
        completion: @escaping (Lite.PayResult) -> Void
    ) {
        let lite = Lite()

        let host = LitePaymentSheetHostController(
            lite: lite,
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            configuration: configuration,
            completion: completion
        )
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            // Keep full-width at every detent height. Without this, shorter content detents
            // inset from the screen edges and taller ones go edge-to-edge — the side-gap stutter.
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = false
            host.applyContentDetents(animated: false)
            sheet.prefersGrabberVisible = false
            if #available(iOS 16.0, *) {
                sheet.preferredCornerRadius = LiteTheme.Radii.sheet
            }
        }
        presenter.present(host, animated: true)
    }
}

// MARK: - Host

@MainActor
private final class LitePaymentSheetHostController: UIViewController {
    private let lite: Lite
    private let clientSecret: String
    private let configuration: LitePaymentSheet.Configuration
    private let completion: (Lite.PayResult) -> Void
    private var didFinish = false
    private var hostingController: UIHostingController<LitePaymentSheetRoot>?
    private var cancellables = Set<AnyCancellable>()
    private var reportedContentHeight: CGFloat = 0
    private var detentUpdateWorkItem: DispatchWorkItem?

    private static let contentDetentId = UISheetPresentationController.Detent.Identifier("lite.payment.content")

    private var screenBounds: CGRect {
        view.window?.windowScene?.screen.bounds ?? view.bounds
    }

    init(
        lite: Lite,
        clientSecret: String,
        configuration: LitePaymentSheet.Configuration,
        completion: @escaping (Lite.PayResult) -> Void
    ) {
        self.lite = lite
        self.clientSecret = clientSecret
        self.configuration = configuration
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        view.backgroundColor = LiteTheme.Colors.backgroundUIColor
        LiteFonts.registerIfNeeded()

        // Block interactive dismiss while authorize / 3DS is in flight, and remeasure
        // when phase changes. `DispatchQueue.main` delivers during scroll tracking
        // (`RunLoop.main` default mode does not).
        lite.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.isModalInPresentation = (phase == .paying)
                self?.invalidateContentDetentsAfterLayout()
            }
            .store(in: &cancellables)

        // Grow / shrink when the user expands new-card fields or swaps methods.
        // Height preference drives detent updates (debounced); avoid a second immediate invalidate.
        lite.$cardSelection
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateContentDetentsAfterLayout()
            }
            .store(in: &cancellables)

        let root = LitePaymentSheetRoot(
            lite: lite,
            clientSecret: clientSecret,
            configuration: configuration,
            onFinished: { [weak self] result in
                self?.finish(with: result)
            },
            onContentHeightChange: { [weak self] height in
                self?.updateReportedContentHeight(height)
            }
        )
        let host = UIHostingController(rootView: root)
        host.overrideUserInterfaceStyle = .light
        if #available(iOS 16.0, *) {
            host.sizingOptions = [.intrinsicContentSize]
        }
        hostingController = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        LiteKeyboardDismissTap.install(on: view)
    }

    /// Content-sized detent for both form and result (iOS 16+). iOS 15 falls back to medium/large.
    func applyContentDetents(animated: Bool) {
        guard let sheet = sheetPresentationController else { return }

        let apply = { [weak self] in
            guard let self else { return }
            if #available(iOS 16.0, *) {
                let detent = UISheetPresentationController.Detent.custom(
                    identifier: Self.contentDetentId
                ) { [weak self] context in
                    guard let self else { return min(420, context.maximumDetentValue) }
                    return self.measuredContentDetentHeight(maximum: context.maximumDetentValue)
                }
                sheet.detents = [detent]
                sheet.selectedDetentIdentifier = Self.contentDetentId
            } else {
                // iOS 15: pick medium vs large from measured content.
                let preferLarge = self.reportedContentHeight > self.screenBounds.height * 0.5
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = preferLarge ? .large : .medium
            }
        }

        if animated {
            sheet.animateChanges { apply() }
        } else {
            apply()
        }
    }

    private func updateReportedContentHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        // Ignore sub-pixel / layout thrash from GeometryReader during accordion expand.
        guard abs(height - reportedContentHeight) > 4 else { return }
        reportedContentHeight = height

        // Debounce detent animation so expand/collapse does not reflow the sheet every frame
        // (that reflow is what reads as a horizontal padding stutter).
        detentUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyContentDetents(animated: true)
            self.invalidateContentDetentsAfterLayout()
        }
        detentUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func invalidateContentDetentsAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let sheet = self.sheetPresentationController else { return }
            if #available(iOS 16.0, *) {
                sheet.invalidateDetents()
            }
        }
    }

    private func measuredContentDetentHeight(maximum: CGFloat) -> CGFloat {
        let width = view.bounds.width > 0 ? view.bounds.width : screenBounds.width
        var height = reportedContentHeight
        if height < 1, let host = hostingController {
            height = host.sizeThatFits(
                in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
            ).height
        }
        // Safe area / sheet chrome padding.
        height += view.safeAreaInsets.bottom
        // Grow with content up to the system maximum (nearly full screen).
        return min(max(height, 240), maximum)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        guard !didFinish else { return }

        // Prefer a completed non-cancel outcome if pay already finished.
        if let last = lite.lastPayResult, last.status != .cancelled {
            finish(with: last)
            return
        }

        // Still paying (or race): await the in-flight task — never invent cancelled after a timeout.
        if lite.hasInFlightPay || lite.phase == .paying {
            Task { @MainActor [weak self] in
                guard let self, !self.didFinish else { return }
                if let result = await self.lite.awaitInFlightPay() {
                    self.finish(with: result)
                } else {
                    self.finish(with: Lite.PayResult(status: .cancelled, paymentId: nil, error: "cancelled"))
                }
            }
            return
        }

        finish(with: Lite.PayResult(status: .cancelled, paymentId: nil, error: "cancelled"))
    }

    private func finish(with result: Lite.PayResult) {
        guard !didFinish else { return }
        didFinish = true
        let completion = self.completion
        if isBeingDismissed || presentingViewController == nil {
            completion(result)
        } else {
            dismiss(animated: true) {
                completion(result)
            }
        }
    }
}

// MARK: - SwiftUI root

private struct LiteSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LitePaymentSheetRoot: View {
    @ObservedObject var lite: Lite
    let clientSecret: String
    let configuration: LitePaymentSheet.Configuration
    let onFinished: (Lite.PayResult) -> Void
    let onContentHeightChange: (CGFloat) -> Void

    @State private var result: Lite.PayResult?
    @State private var showResult = false

    var body: some View {
        Group {
            if showResult, let result {
                LitePaymentResultView(
                    result: result,
                    onDismiss: { onFinished(result) },
                    compact: false,
                    config: LitePaymentResultConfig(
                        amountMinor: lite.session?.amount,
                        currency: lite.session?.currency
                    )
                )
                .padding(.bottom, LiteTheme.Spacing.xs)
            } else {
                LitePaymentFormContent(
                    lite: lite,
                    cardLayout: configuration.cardLayout,
                    title: "Payment information",
                    showHeader: true,
                    applePayEnabled: configuration.applePayEnabled,
                    onClose: {
                        guard lite.phase != .paying else { return }
                        onFinished(Lite.PayResult(status: .cancelled, paymentId: nil, error: "cancelled"))
                    },
                    onPayResult: { payResult in
                        // Skip result chrome for user cancel — complete immediately.
                        if payResult.status == .cancelled {
                            onFinished(payResult)
                            return
                        }
                        result = payResult
                        if configuration.showResultBeforeDismiss {
                            showResult = true
                        } else {
                            onFinished(payResult)
                        }
                    },
                    privacyPolicyUrl: configuration.privacyPolicyUrl,
                    // Methods scroll when tall; pay button stays pinned in the form footer.
                    preferContentHeight: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(LiteTheme.Colors.background)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: LiteSheetHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(LiteSheetHeightKey.self) { height in
            guard height > 0 else { return }
            onContentHeightChange(height)
        }
        .liteFixedColorScheme()
        .task {
            guard !clientSecret.isEmpty else { return }
            await lite.start(clientSecret: clientSecret)
            // `start()` resets `storeForFuture`; re-apply the sheet configuration default.
            if configuration.defaultStoreForFuture {
                lite.storeForFuture = true
            }
            guard let preloaded = lite.lastPayResult else { return }
            if configuration.showResultBeforeDismiss {
                result = preloaded
                showResult = true
            } else {
                onFinished(preloaded)
            }
        }
    }
}
#endif
