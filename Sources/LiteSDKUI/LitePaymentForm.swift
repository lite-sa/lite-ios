#if canImport(UIKit)
import SwiftUI

/// Embeddable payment form — same body as the presentable sheet; merchant owns surrounding layout.
///
/// Pass `clientSecret` to start automatically, or bind to an already-started `lite`.
public struct LitePaymentForm: View {
    @ObservedObject private var lite: Lite
    private let cardLayout: LiteCardLayout
    private let clientSecret: String?
    private let applePayEnabled: Bool
    private let showResultInline: Bool
    private let privacyPolicyUrl: String?
    private let onPrivacyClick: (() -> Void)?
    private let onPayResult: ((Lite.PayResult) -> Void)?

    public init(
        lite: Lite,
        cardLayout: LiteCardLayout = .compact,
        clientSecret: String? = nil,
        applePayEnabled: Bool = true,
        showResultInline: Bool = false,
        privacyPolicyUrl: String? = nil,
        onPrivacyClick: (() -> Void)? = nil,
        onPayResult: ((Lite.PayResult) -> Void)? = nil
    ) {
        self.lite = lite
        self.cardLayout = cardLayout
        self.clientSecret = clientSecret
        self.applePayEnabled = applePayEnabled
        self.showResultInline = showResultInline
        self.privacyPolicyUrl = privacyPolicyUrl
        self.onPrivacyClick = onPrivacyClick
        self.onPayResult = onPayResult
    }

    @State private var startedFor: String?

    public var body: some View {
        LitePaymentFormContent(
            lite: lite,
            cardLayout: cardLayout,
            showHeader: false,
            applePayEnabled: applePayEnabled,
            showResultInline: showResultInline,
            onPayResult: onPayResult,
            privacyPolicyUrl: privacyPolicyUrl,
            onPrivacyClick: onPrivacyClick
        )
        .task(id: clientSecret) {
            let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !secret.isEmpty else { return }
            // `.task(id:)` also re-runs on reappear with the same id; do not wipe card fields.
            if startedFor == secret {
                switch lite.phase {
                case .ready, .paying, .loadingSession: return
                case .idle, .failed: break
                }
            }
            await lite.start(clientSecret: secret)
            startedFor = secret
        }
    }
}
#endif
