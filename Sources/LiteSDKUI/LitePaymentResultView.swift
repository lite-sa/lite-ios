#if canImport(UIKit)
import SwiftUI
import LiteSDKCore
import UIKit

/// Figma Final Checkout Mobile result sheets:
/// Success / Already completed / Error / Cancelled / Link inactive / Link expired (+ Processing).
public enum LitePaymentResultKind: Sendable, CaseIterable, Identifiable {
    case success
    case alreadyCompleted
    case error
    case cancelled
    case linkInactive
    case linkExpired
    case processing

    public var id: Self { self }

    public static func from(result: Lite.PayResult) -> LitePaymentResultKind {
        let err = result.error ?? ""
        switch result.status {
        case .success:
            return .success
        case .alreadyCompleted:
            return .alreadyCompleted
        case .processing:
            return .processing
        case .cancelled:
            return .cancelled
        case .failure:
            if err.localizedCaseInsensitiveContains("already") { return .alreadyCompleted }
            if err.localizedCaseInsensitiveContains("expired") { return .linkExpired }
            if err.localizedCaseInsensitiveContains("inactive")
                || err.localizedCaseInsensitiveContains("no longer active") {
                return .linkInactive
            }
            return .error
        }
    }
}

/// Optional presentation extras for result sheets (amount).
public struct LitePaymentResultConfig: Sendable {
    public var amountMinor: Int?
    public var currency: String?
    public var showCloseButton: Bool

    public init(
        amountMinor: Int? = nil,
        currency: String? = nil,
        showCloseButton: Bool = true
    ) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.showCloseButton = showCloseButton
    }
}

public struct LitePaymentResultView: View {
    private let result: Lite.PayResult
    private let onDismiss: (() -> Void)?
    private let compact: Bool
    private let dismissLabel: String?
    private let kind: LitePaymentResultKind?
    private let config: LitePaymentResultConfig

    public init(
        result: Lite.PayResult,
        onDismiss: (() -> Void)? = nil,
        compact: Bool = false,
        dismissLabel: String? = nil,
        kind: LitePaymentResultKind? = nil,
        config: LitePaymentResultConfig = .init()
    ) {
        self.result = result
        self.onDismiss = onDismiss
        self.compact = compact
        self.dismissLabel = dismissLabel
        self.kind = kind
        self.config = config
    }

    private var resolvedKind: LitePaymentResultKind {
        kind ?? .from(result: result)
    }

    public var body: some View {
        let chrome = Self.chrome(for: resolvedKind)
        let actionLabel = dismissLabel ?? chrome.defaultActionLabel

        VStack(spacing: 0) {
            if onDismiss != nil, config.showCloseButton, !compact {
                HStack {
                    Spacer()
                    Button {
                        onDismiss?()
                    } label: {
                        LiteIcons.close
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                            .foregroundColor(LiteTheme.Colors.textPrimary)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(LiteTheme.Colors.border, lineWidth: 0.9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(LiteTheme.Spacing.m)
            }

            VStack(spacing: LiteTheme.Spacing.xl) {
                VStack(spacing: LiteTheme.Spacing.m) {
                    resultStatusIcon(soft: chrome.soft, accent: chrome.accent, icon: chrome.icon)

                    VStack(spacing: LiteTheme.Spacing.xxs) {
                        Text(chrome.title)
                            .font(LiteTheme.Typography.titleLarge())
                            .foregroundColor(LiteTheme.Colors.textPrimary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        if let subtitle = chrome.subtitle {
                            Text(subtitle)
                                .font(LiteTheme.Typography.body())
                                .foregroundColor(LiteTheme.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                if !compact {
                    DashedDivider()

                    switch resolvedKind {
                    case .success:
                        successDetails
                    case .alreadyCompleted:
                        if let id = result.paymentId {
                            referenceIdInline(id)
                        }
                    case .error, .linkInactive, .linkExpired, .cancelled:
                        // Upper details only — no business contact section.
                        if let id = result.paymentId {
                            referenceIdInline(id)
                        }
                    case .processing:
                        if let id = result.paymentId {
                            referenceIdInline(id)
                        }
                    }
                } else if let id = result.paymentId,
                          resolvedKind == .success || resolvedKind == .alreadyCompleted {
                    Text("Reference ID: \(id)")
                        .font(LiteTheme.Typography.body())
                        .foregroundColor(LiteTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, LiteTheme.Spacing.xl)
            .padding(.bottom, compact ? LiteTheme.Spacing.m : LiteTheme.Spacing.xl)

            if onDismiss != nil, !compact {
                Button {
                    onDismiss?()
                } label: {
                    Text(actionLabel)
                        .font(LiteTheme.Typography.bodySemiBold())
                        .foregroundColor(LiteTheme.Colors.textOnPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: LiteTheme.inputHeight)
                        .background(LiteTheme.Colors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: LiteTheme.Radii.pill, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(LiteTheme.Spacing.m)
            }
        }
        .frame(maxWidth: .infinity)
        .background(LiteTheme.Colors.background)
        .liteFixedColorScheme()
    }

    // MARK: - Pieces

    private func resultStatusIcon(soft: Color, accent: Color, icon: Image) -> some View {
        ZStack {
            Circle()
                .fill(soft)
                .frame(width: 64, height: 64)
            Circle()
                .fill(accent)
                .frame(width: 48, height: 48)
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder
    private var successDetails: some View {
        VStack(spacing: LiteTheme.Spacing.m) {
            if let amount = config.amountMinor, let currency = config.currency {
                HStack {
                    Text("Total")
                        .font(LiteTheme.Typography.body())
                        .foregroundColor(LiteTheme.Colors.textSecondary)
                    Spacer()
                    LiteMoneyAmount(
                        amountMinor: amount,
                        currency: currency,
                        font: LiteTheme.Typography.bodyMedium(),
                        color: LiteTheme.Colors.textPrimary,
                        symbolSize: 14
                    )
                }
            }
            if let id = result.paymentId {
                HStack {
                    Text("Reference ID")
                        .font(LiteTheme.Typography.body())
                        .foregroundColor(LiteTheme.Colors.textSecondary)
                    Spacer()
                    HStack(spacing: LiteTheme.Spacing.xs) {
                        Text(id)
                            .font(LiteTheme.Typography.bodyMedium())
                            .foregroundColor(LiteTheme.Colors.textPrimary)
                        Button {
                            UIPasteboard.general.string = id
                        } label: {
                            LiteIcons.copy
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                                .foregroundColor(LiteTheme.Colors.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy")
                    }
                }
            }
        }
    }

    private func referenceIdInline(_ id: String) -> some View {
        HStack(spacing: LiteTheme.Spacing.xs) {
            Text("Reference ID: ")
                .font(LiteTheme.Typography.body())
                .foregroundColor(LiteTheme.Colors.textSecondary)
            Text(id)
                .font(LiteTheme.Typography.bodyMedium())
                .foregroundColor(LiteTheme.Colors.textSecondary)
            Button {
                UIPasteboard.general.string = id
            } label: {
                LiteIcons.copy
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundColor(LiteTheme.Colors.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy")
        }
    }

    // MARK: - Chrome

    private struct ResultChrome {
        let title: String
        let subtitle: String?
        let soft: Color
        let accent: Color
        let icon: Image
        let defaultActionLabel: String
    }

    private static func chrome(for kind: LitePaymentResultKind) -> ResultChrome {
        switch kind {
        case .success:
            return ResultChrome(
                title: "Payment completed successfully! 🎉",
                subtitle: nil,
                soft: LiteTheme.Colors.successSoft,
                accent: LiteTheme.Colors.success,
                icon: LiteIcons.resultCheck,
                defaultActionLabel: "Back to home"
            )
        case .alreadyCompleted:
            return ResultChrome(
                title: "This payment has already been completed",
                subtitle: nil,
                soft: LiteTheme.Colors.successSoft,
                accent: LiteTheme.Colors.success,
                icon: LiteIcons.resultCheck,
                defaultActionLabel: "Back to home"
            )
        case .error:
            return ResultChrome(
                title: "Payment could not be completed",
                subtitle: "We couldn’t process the payment. Please try again or use a different payment method",
                soft: LiteTheme.Colors.failureSoft,
                accent: LiteTheme.Colors.failure,
                icon: LiteIcons.resultX,
                defaultActionLabel: "Close"
            )
        case .cancelled:
            return ResultChrome(
                title: "Payment cancelled",
                subtitle: "You closed checkout before the payment was completed",
                soft: LiteTheme.Colors.border,
                accent: LiteTheme.Colors.textPlaceholder,
                icon: LiteIcons.resultAlert,
                defaultActionLabel: "Close"
            )
        case .linkInactive:
            return ResultChrome(
                title: "This payment link is no longer active",
                subtitle: nil,
                soft: LiteTheme.Colors.border,
                accent: LiteTheme.Colors.textPlaceholder,
                icon: LiteIcons.resultAlert,
                defaultActionLabel: "Back to home"
            )
        case .linkExpired:
            return ResultChrome(
                title: "This payment link has expired",
                subtitle: nil,
                soft: LiteTheme.Colors.border,
                accent: LiteTheme.Colors.textPlaceholder,
                icon: LiteIcons.resultAlert,
                defaultActionLabel: "Back to home"
            )
        case .processing:
            return ResultChrome(
                title: "Payment processing",
                subtitle: nil,
                soft: LiteTheme.Colors.processingSoft,
                accent: LiteTheme.Colors.processing,
                icon: LiteIcons.resultProcessing,
                defaultActionLabel: "Done"
            )
        }
    }
}

private struct DashedDivider: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 0.5))
            path.addLine(to: CGPoint(x: size.width, y: 0.5))
            context.stroke(
                path,
                with: .color(LiteTheme.Colors.border),
                style: StrokeStyle(lineWidth: 1, dash: [6, 4])
            )
        }
        .frame(height: 1)
        .frame(maxWidth: .infinity)
    }
}
#endif
