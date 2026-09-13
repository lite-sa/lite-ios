#if canImport(UIKit)
import SwiftUI
import UIKit
import ObjectiveC
import LiteSDKCore

private struct LiteTerminalResultNotificationID: Equatable {
    let result: Lite.PayResult?
    let isTerminalSession: Bool
}

/// Shared payment body — Figma Bottom Sheet + web checkout accordion pattern:
/// saved cards as rows; “Pay with a new card” nests logos + fields when selected.
public struct LitePaymentFormContent: View {
    @ObservedObject var lite: Lite
    var cardLayout: LiteCardLayout
    var title: String?
    var showHeader: Bool
    var applePayEnabled: Bool
    var onClose: (() -> Void)?
    var showResultInline: Bool
    var onPayResult: ((Lite.PayResult) -> Void)?
    var privacyPolicyUrl: String?
    var onPrivacyClick: (() -> Void)?
    /// When true (payment sheet), size to content instead of expanding a ScrollView into empty space.
    var preferContentHeight: Bool

    @State private var paying = false
    @State private var didNotifyTerminalResult = false

    public init(
        lite: Lite,
        cardLayout: LiteCardLayout = .compact,
        title: String? = nil,
        showHeader: Bool = false,
        applePayEnabled: Bool = true,
        onClose: (() -> Void)? = nil,
        showResultInline: Bool = false,
        onPayResult: ((Lite.PayResult) -> Void)? = nil,
        privacyPolicyUrl: String? = nil,
        onPrivacyClick: (() -> Void)? = nil,
        preferContentHeight: Bool = false
    ) {
        self.lite = lite
        self.cardLayout = cardLayout
        self.title = title
        self.showHeader = showHeader
        self.applePayEnabled = applePayEnabled
        self.onClose = onClose
        self.showResultInline = showResultInline
        self.onPayResult = onPayResult
        self.privacyPolicyUrl = privacyPolicyUrl
        self.onPrivacyClick = onPrivacyClick
        self.preferContentHeight = preferContentHeight
    }

    /// Window height when available (Split View / Stage Manager); `UIScreen.main` is last resort.
    private static var fittingScrollMaxHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let height = scene?.windows.first(where: \.isKeyWindow)?.bounds.height
            ?? scene?.screen.bounds.height
            ?? UIScreen.main.bounds.height
        return height * 0.92 - 160
    }

    public var body: some View {
        let skipFormForTerminalSession = lite.lastPayResult != nil
            && CheckoutSessionStatus.isTerminal(lite.session?.status)
        let terminalNotificationID = LiteTerminalResultNotificationID(
            result: lite.lastPayResult,
            isTerminalSession: skipFormForTerminalSession
        )
        Group {
            if showResultInline, let result = lite.lastPayResult {
                LitePaymentResultView(
                    result: result,
                    onDismiss: nil,
                    config: LitePaymentResultConfig(
                        amountMinor: lite.session?.amount,
                        currency: lite.session?.currency,
                        showCloseButton: false
                    )
                )
            } else if skipFormForTerminalSession {
                EmptyView()
            } else {
                formBody
            }
        }
        .task(id: terminalNotificationID) {
            guard let result = terminalNotificationID.result else {
                didNotifyTerminalResult = false
                return
            }
            guard terminalNotificationID.isTerminalSession,
                  !didNotifyTerminalResult
            else { return }
            notifyPayResult(result)
        }
        .liteFixedColorScheme()
    }

    private var formBody: some View {
        VStack(spacing: 0) {
            if showHeader {
                LiteSheetHeader(title: title ?? "Payment information", onClose: onClose)
            }

            // Horizontal padding lives OUTSIDE the scroll view so scroll safe-area / content
            // margins cannot desync side inset vs the sticky pay footer (selection stutter).
            let methods = VStack(alignment: .leading, spacing: LiteTheme.Spacing.xl) {
                switch lite.phase {
                case .loadingSession:
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(LiteTheme.Colors.primary)
                        Spacer()
                    }
                    .padding(.vertical, LiteTheme.Spacing.xl)
                case .failed(let message):
                    Text(message)
                        .font(LiteTheme.Typography.body())
                        .foregroundColor(LiteTheme.Colors.error)
                default:
                    paymentMethodsSection
                }
            }
            // Figma sheet column gap 24 after header (and 16 when embedded without header)
            .padding(.top, showHeader ? LiteTheme.Spacing.xl : LiteTheme.Spacing.m)
            .padding(.bottom, LiteTheme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if preferContentHeight {
                    // Sheet: methods scroll when tall; pay footer stays pinned below.
                    // Reserve ~160pt for header + pay chrome so the sheet can still grow to ~full screen.
                    LiteFittingScroll(maxHeight: Self.fittingScrollMaxHeight) {
                        methods
                    }
                } else {
                    ScrollView {
                        methods
                    }
                    .modifier(LiteScrollIndicatorsHidden())
                    .liteScrollDismissesKeyboard()
                }
            }
            .padding(.horizontal, LiteTheme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .top)

            // Figma Button footer: top border + pt 16 — always visible in the sheet.
            VStack(spacing: LiteTheme.Spacing.s) {
                if lite.isPayLocked, let lockMessage = lite.payLockMessage {
                    Text(lockMessage)
                        .font(LiteTheme.Typography.body())
                        .foregroundColor(LiteTheme.Colors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(lockMessage)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                payButton
            }
            .padding(.horizontal, LiteTheme.Spacing.m)
            .padding(.top, LiteTheme.Spacing.m)
            .padding(.bottom, LiteTheme.Spacing.m)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LiteTheme.Colors.border)
                    .frame(height: 1)
            }
        }
        .background(LiteTheme.Colors.background)
        .background(LiteKeyboardDismissInstaller())
        .liteKeyboardAvoidance()
    }

    @ViewBuilder
    private var paymentMethodsSection: some View {
        let showsExpressPaymentMethod = hasExpressPaymentMethod
        VStack(alignment: .leading, spacing: LiteTheme.Spacing.xl) {
            #if canImport(PassKit)
            if showsExpressPaymentMethod {
                expressPaymentSection
            }
            #endif

            cardPaymentSection(showAlternativeLabel: showsExpressPaymentMethod)

            SecurePaymentFooter(
                onPrivacyClick: onPrivacyClick,
                privacyPolicyUrl: privacyPolicyUrl
            )
        }
    }

    private var hasExpressPaymentMethod: Bool {
        #if canImport(PassKit)
        return applePayEnabled && lite.isApplePayAvailable
        #else
        return false
        #endif
    }

    /// Available express-payment buttons without redundant section chrome.
    @ViewBuilder
    private var expressPaymentSection: some View {
        #if canImport(PassKit)
        LiteApplePayButton(lite, type: .plain) { result in
            notifyPayResult(result)
        }
        #endif
    }

    /// Card methods use an alternative-payment label only when an APM is visible above them.
    private func cardPaymentSection(showAlternativeLabel: Bool) -> some View {
        VStack(alignment: .leading, spacing: LiteTheme.Spacing.s) {
            if showAlternativeLabel {
                sectionLabel(icon: LiteIcons.creditCard, title: "OR Pay with card")
            }

            VStack(spacing: LiteTheme.Spacing.s) {
                ForEach(lite.getStoredInstruments()) { instrument in
                    let selected: Bool = {
                        if case .storedInstrument(let id) = lite.cardSelection { return id == instrument.id }
                        return false
                    }()
                    StoredInstrumentRow(
                        instrument: instrument,
                        selected: selected,
                        onClick: { lite.selectStoredInstrument(instrument.id) }
                    )
                    .onAppear {
                        if selected && !instrument.enabled {
                            lite.selectNewCard()
                        }
                    }
                    .onChange(of: instrument.enabled) { enabled in
                        if selected && !enabled {
                            lite.selectNewCard()
                        }
                    }
                }

                NewCardMethodBlock(
                    lite: lite,
                    selected: {
                        if case .newCard = lite.cardSelection { return true }
                        return false
                    }(),
                    cardLayout: cardLayout,
                    onSelect: { lite.selectNewCard() }
                )
            }
        }
    }

    private func sectionLabel(icon: Image, title: String) -> some View {
        HStack(spacing: LiteTheme.Spacing.xs) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundColor(LiteTheme.Colors.textSecondary)
            Text(title)
                .font(LiteTheme.Typography.bodyMedium())
                .foregroundColor(LiteTheme.Colors.textSecondary)
        }
    }

    private var payButton: some View {
        let enabled = lite.isReadyToPay && !paying && lite.phase == .ready && !lite.isPayLocked
        let contentColor = LiteTheme.Colors.textOnPrimary

        return Button {
            Task {
                paying = true
                let result = await lite.pay()
                paying = false
                // Stay on the form (web toaster path) — do not advance to result / dismiss.
                if result.errorCode == LiteAPIError.paymentMethodNotSupported
                    || result.errorCode == Lite.threeDSChallengeDismissedErrorCode {
                    return
                }
                notifyPayResult(result)
            }
        } label: {
            Group {
                if paying || lite.phase == .paying {
                    ProgressView()
                        .tint(contentColor)
                } else {
                    HStack(spacing: 6) {
                        Text("Pay Now")
                            .font(LiteTheme.Typography.bodySemiBold())
                            .foregroundColor(contentColor)
                        if let session = lite.session {
                            LiteMoneyAmount(
                                amountMinor: session.amount,
                                currency: session.currency,
                                font: LiteTheme.Typography.bodySemiBold(),
                                color: contentColor
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: LiteTheme.inputHeight)
            .background(enabled ? LiteTheme.Colors.primary : LiteTheme.Colors.primary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: LiteTheme.Radii.pill, style: .continuous))
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .accessibilityLabel((paying || lite.phase == .paying) ? "Processing payment" : "Pay Now")
    }

    private func notifyPayResult(_ result: Lite.PayResult) {
        guard result.errorCode != Lite.threeDSChallengeDismissedErrorCode else { return }
        didNotifyTerminalResult = true
        onPayResult?(result)
    }
}

// MARK: - Header

struct LiteSheetHeader: View {
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LiteTheme.Spacing.m) {
                Text(title)
                    .font(LiteTheme.Typography.title())
                    .foregroundColor(LiteTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onClose {
                    Button(action: onClose) {
                        LiteIcons.close
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                            .foregroundColor(LiteTheme.Colors.textPrimary)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle().stroke(LiteTheme.Colors.border, lineWidth: 0.9)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Close")
                }
            }
            .padding(LiteTheme.Spacing.m)
            .frame(height: 68)
            Divider().background(LiteTheme.Colors.border)
        }
    }
}

// MARK: - New card accordion

private struct NewCardMethodBlock: View {
    @ObservedObject var lite: Lite
    let selected: Bool
    let cardLayout: LiteCardLayout
    let onSelect: () -> Void

    var body: some View {
        let border = selected ? LiteTheme.Colors.primary : LiteTheme.Colors.border
        VStack(alignment: .leading, spacing: LiteTheme.Spacing.s) {
            Button(action: onSelect) {
                HStack(spacing: LiteTheme.Spacing.xs) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 18))
                        .foregroundColor(selected ? LiteTheme.Colors.primary : LiteTheme.Colors.textSecondary)
                        .frame(width: 20, height: 20)
                    LiteIcons.payWithNewCard
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 20)
                        .foregroundColor(LiteTheme.Colors.textPrimary)
                    Text("Pay with a new card")
                        .font(LiteTheme.Typography.body())
                        .foregroundColor(LiteTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            if selected {
                // Nested like Android: logos + Card Information inside, left-aligned
                VStack(alignment: .leading, spacing: LiteTheme.Spacing.s) {
                    let enabled = lite.getEnabledCardNetworks()
                    if !enabled.isEmpty {
                        LiteBrandStrip(enabledNetworks: enabled)
                    }
                    LiteCardEntryView(
                        lite: lite,
                        layout: cardLayout,
                        showBrandStrip: false,
                        showStoreToggle: true
                    )
                }
            }
        }
        .padding(LiteTheme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: LiteTheme.Radii.card, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
    }
}

// MARK: - Rows

private struct StoredInstrumentRow: View {
    let instrument: StoredInstrument
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        let brand = CardType.from(scheme: instrument.display.scheme)
        let schemeRaw = instrument.display.scheme.isEmpty ? brand.displayName : instrument.display.scheme
        let schemeLabel = schemeRaw.lowercased().capitalized
        let title = "\(schemeLabel) **** \(instrument.display.last4)"
        let year = instrument.display.expiryYear
        let shortYear = year.count >= 2 ? String(year.suffix(2)) : year
        let month = instrument.display.expiryMonth
        let paddedMonth = month.count < 2 ? String(repeating: "0", count: max(0, 2 - month.count)) + month : month
        let subtitle = "Expires \(paddedMonth)/\(shortYear)"
        let disabled = !instrument.enabled
        let border = selected && !disabled ? LiteTheme.Colors.primary : LiteTheme.Colors.border
        let primaryText = disabled ? LiteTheme.Colors.textSecondary : LiteTheme.Colors.textPrimary

        Button(action: {
            guard !disabled else { return }
            onClick()
        }) {
            HStack(alignment: .center, spacing: LiteTheme.Spacing.xs) {
                // Left cluster top-aligned like Android / web `items-start`
                HStack(alignment: .top, spacing: LiteTheme.Spacing.xs) {
                    Image(systemName: selected && !disabled ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 18))
                        .foregroundColor(selected && !disabled ? LiteTheme.Colors.primary : LiteTheme.Colors.textSecondary)
                        .frame(width: 20, height: 20)
                    LiteIcons.creditCard
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundColor(primaryText)
                    VStack(alignment: .leading, spacing: LiteTheme.Spacing.xxs) {
                        Text(title)
                            .font(LiteTheme.Typography.body())
                            .foregroundColor(primaryText)
                        Text(subtitle)
                            .font(LiteTheme.Typography.body())
                            .foregroundColor(LiteTheme.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Brand logo vertically centered in the row (Figma / Android)
                if brand != .unknown {
                    CardBrandImage(brand: brand)
                        .opacity(disabled ? 0.4 : 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(LiteTheme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(disabled ? 0.55 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: LiteTheme.Radii.card, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }
}

private struct SecurePaymentFooter: View {
    var onPrivacyClick: (() -> Void)?
    var privacyPolicyUrl: String?

    private var hasPrivacyAction: Bool {
        onPrivacyClick != nil || (privacyPolicyUrl?.isEmpty == false)
    }

    var body: some View {
        // Figma Secure Payment Footer: lock + text + logo; Privacy only when configured (IOS-023).
        HStack(spacing: LiteTheme.Spacing.s) {
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                LiteIcons.secureCheckout
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text("Secured payment by")
                    .font(LiteTheme.Typography.caption())
                    .foregroundColor(LiteTheme.Colors.textSecondary)
                LiteIcons.liteLogo
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 10)
            }
            if hasPrivacyAction {
                Rectangle()
                    .fill(LiteTheme.Colors.border)
                    .frame(width: 1, height: 18)
                Button {
                    if let onPrivacyClick {
                        onPrivacyClick()
                    } else if let privacyPolicyUrl, let url = LiteHTTPURL.parse(privacyPolicyUrl) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Privacy Policy")
                        .font(LiteTheme.Typography.captionSemiBold())
                        .underline()
                        .foregroundColor(LiteTheme.Colors.textPrimary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 21)
    }
}

/// ScrollView that sizes to its content height up to `maxHeight` (pay footer stays outside).
/// Horizontal padding must be applied by the parent — never inside this scroll — so side inset
/// stays identical whether the body is scrolling or not.
private struct LiteFittingScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: LiteScrollContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .modifier(LiteScrollIndicatorsHidden())
        .liteScrollDismissesKeyboard()
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(
            height: contentHeight > 0 ? min(contentHeight, max(maxHeight, 0)) : nil,
            alignment: .top
        )
        // Animate height locally; sheet detent is debounced separately to avoid reflow stutter.
        .animation(.easeInOut(duration: 0.2), value: contentHeight)
        .onPreferenceChange(LiteScrollContentHeightKey.self) { newHeight in
            guard newHeight > 0, abs(newHeight - contentHeight) > 1 else { return }
            contentHeight = newHeight
        }
    }
}

private struct LiteScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Hide scroll indicators and disable automatic content insets that shift horizontal padding.
private struct LiteScrollIndicatorsHidden: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .contentMargins(.horizontal, 0, for: .scrollIndicators)
        } else if #available(iOS 16.0, *) {
            content
                .scrollIndicators(.hidden)
                .background(LiteHideScrollIndicators())
        } else {
            content.background(LiteHideScrollIndicators())
        }
    }
}

/// iOS 15/16: hide UIScrollView indicators + disable automatic inset adjustment.
private struct LiteHideScrollIndicators: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context _: Context) {
        DispatchQueue.main.async {
            var parent = uiView.superview
            while let current = parent {
                if let scroll = current as? UIScrollView {
                    scroll.showsVerticalScrollIndicator = false
                    scroll.showsHorizontalScrollIndicator = false
                    scroll.contentInsetAdjustmentBehavior = .never
                    scroll.contentInset = .zero
                    scroll.scrollIndicatorInsets = .zero
                    return
                }
                parent = current.superview
            }
        }
    }
}

// MARK: - Keyboard (kept in this file so CocoaPods LiteSDKUI compiles without a new source)

enum LiteKeyboard {
    static func resign() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

extension View {
    func liteKeyboardAvoidance() -> some View {
        modifier(LiteKeyboardAvoidance())
    }

    func liteScrollDismissesKeyboard() -> some View {
        modifier(LiteScrollDismissesKeyboard())
    }
}

private struct LiteKeyboardAvoidance: ViewModifier {
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, inset)
            .animation(.easeOut(duration: 0.25), value: inset)
            .background(
                LiteKeyboardOverlapProbe(inset: $inset)
                    .accessibilityHidden(true)
            )
    }
}

private struct LiteScrollDismissesKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}

private struct LiteKeyboardOverlapProbe: UIViewRepresentable {
    @Binding var inset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(inset: $inset)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.install()
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.inset = $inset
        context.coordinator.view = uiView
    }

    static func dismantleUIView(_: UIView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    final class Coordinator {
        var inset: Binding<CGFloat>
        weak var view: UIView?
        private var tokens: [NSObjectProtocol] = []

        init(inset: Binding<CGFloat>) {
            self.inset = inset
        }

        func install() {
            let center = NotificationCenter.default
            tokens.append(center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.apply(note)
            })
            tokens.append(center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.inset.wrappedValue = 0
            })
        }

        func tearDown() {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens.removeAll()
        }

        func apply(_ note: Notification) {
            guard
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                let window = view?.window ?? UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)
            else { return }
            let keyboard = window.convert(end, from: nil)
            let overlap = max(0, window.bounds.maxY - keyboard.minY)
            inset.wrappedValue = keyboard.minY >= window.bounds.maxY - 1 ? 0 : overlap
        }
    }

}

enum LiteKeyboardDismissTap {
    private static var ownerKey: UInt8 = 0

    static func install(on view: UIView) {
        if view.gestureRecognizers?.contains(where: { $0.name == Self.recognizerName }) == true {
            return
        }
        let owner = Owner()
        let tap = UITapGestureRecognizer(target: owner, action: #selector(Owner.dismiss))
        tap.name = Self.recognizerName
        tap.cancelsTouchesInView = false
        tap.delegate = owner
        view.addGestureRecognizer(tap)
        objc_setAssociatedObject(view, &ownerKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static let recognizerName = "lite.keyboard.dismiss"

    private final class Owner: NSObject, UIGestureRecognizerDelegate {
        @objc func dismiss() {
            LiteKeyboard.resign()
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField { return false }
                view = current.superview
            }
            return true
        }
    }
}

struct LiteKeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context _: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_: InstallerView, context _: Context) {
        // Installation is driven by InstallerView.didMoveToWindow().
    }

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let vc = current as? UIViewController {
                    LiteKeyboardDismissTap.install(on: vc.view)
                    return
                }
                responder = current.next
            }
        }
    }
}

#endif
