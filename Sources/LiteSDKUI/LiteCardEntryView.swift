#if canImport(UIKit)
import SwiftUI
import LiteSDKCore

/// Composite card entry matching Figma form / compact / line layouts.
struct LiteCardEntryView: View {
    @ObservedObject private var lite: Lite
    private let layout: LiteCardLayout
    private let showBrandStrip: Bool
    private let showStoreToggle: Bool

    @State private var numberInvalid = false
    @State private var expiryInvalid = false
    @State private var cvvInvalid = false

    @ScaledMetric(relativeTo: .body) private var expiryWidth: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var cvvWidth: CGFloat = 48

    init(
        lite: Lite,
        layout: LiteCardLayout = .compact,
        showBrandStrip: Bool = true,
        showStoreToggle: Bool = true
    ) {
        self.lite = lite
        self.layout = layout
        self.showBrandStrip = showBrandStrip
        self.showStoreToggle = showStoreToggle
    }

    private var enabledNetworks: [CardNetwork] { lite.getEnabledCardNetworks() }

    var body: some View {
        switch layout {
        case .form:
            formLayout
        case .compact:
            compactLayout
        case .line:
            lineLayout
        }
    }

    // MARK: - Form

    private var formLayout: some View {
        VStack(alignment: .leading, spacing: LiteTheme.Spacing.m) {
            if showBrandStrip, !enabledNetworks.isEmpty {
                LiteBrandStrip(enabledNetworks: enabledNetworks)
            }
            pillField(
                label: "Card number",
                showsInvalid: numberInvalid,
                error: numberInvalid ? "Incorrect card number" : nil
            ) {
                LiteCardNumberField(lite, chrome: .plain, onShowsInvalid: { numberInvalid = $0 })
            }
            HStack(alignment: .top, spacing: LiteTheme.Spacing.m) {
                pillField(
                    label: "Expiry date",
                    showsInvalid: expiryInvalid,
                    error: expiryInvalid ? "Incorrect expiry date" : nil
                ) {
                    LiteExpiryField(lite, chrome: .plain, onShowsInvalid: { expiryInvalid = $0 })
                }
                pillField(
                    label: "CVV",
                    showsInvalid: cvvInvalid,
                    error: cvvInvalid ? "Incorrect CVV" : nil
                ) {
                    LiteCVVField(lite, chrome: .plain, onShowsInvalid: { cvvInvalid = $0 })
                }
            }
            pillField(label: "Cardholder Name", labelSuffix: "(Optional)", showsInvalid: false, error: nil) {
                LiteCardholderNameField(lite, chrome: .plain)
            }
            if showStoreToggle { storeToggle }
        }
    }

    // MARK: - Compact

    private var compactLayout: some View {
        let groupError = compactGroupError
        let hasError = groupError != nil
        let radius = hasError ? LiteTheme.Radii.compactError : LiteTheme.Radii.compact
        let border = hasError ? LiteTheme.Colors.error : LiteTheme.Colors.border

        // Android CompactCardEntry: spacedBy(s) between strip / fields / toggle
        return VStack(alignment: .leading, spacing: LiteTheme.Spacing.s) {
            if showBrandStrip, !enabledNetworks.isEmpty {
                LiteBrandStrip(enabledNetworks: enabledNetworks)
            }
            VStack(alignment: .leading, spacing: LiteTheme.Spacing.xxs) {
                Text("Card Information")
                    .font(LiteTheme.Typography.body())
                    .foregroundColor(LiteTheme.Colors.textSecondary)
                VStack(spacing: 0) {
                    compactCell {
                        LiteCardNumberField(lite, chrome: .plain, onShowsInvalid: { numberInvalid = $0 })
                    }
                    Divider().background(LiteTheme.Colors.border)
                    HStack(spacing: 0) {
                        compactCell {
                            LiteExpiryField(lite, chrome: .plain, onShowsInvalid: { expiryInvalid = $0 })
                        }
                        Rectangle()
                            .fill(LiteTheme.Colors.border)
                            .frame(width: 1, height: LiteTheme.inputHeight)
                        compactCell {
                            LiteCVVField(lite, chrome: .plain, onShowsInvalid: { cvvInvalid = $0 })
                        }
                    }
                    Divider().background(LiteTheme.Colors.border)
                    compactCell {
                        LiteCardholderNameField(lite, chrome: .plain)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))

                if let groupError {
                    Text(groupError)
                        .font(LiteTheme.Typography.captionMedium())
                        .foregroundColor(LiteTheme.Colors.error)
                }
            }
            if showStoreToggle { storeToggle }
        }
    }

    private var compactGroupError: String? {
        if numberInvalid { return "Incorrect card number" }
        if expiryInvalid { return "Incorrect expiry date" }
        if cvvInvalid { return "Incorrect CVV" }
        return nil
    }

    // MARK: - Line

    private var lineLayout: some View {
        let lineError = compactGroupError
        let border = lineError != nil ? LiteTheme.Colors.error : LiteTheme.Colors.border

        return VStack(alignment: .leading, spacing: LiteTheme.Spacing.m) {
            if showBrandStrip, !enabledNetworks.isEmpty {
                LiteBrandStrip(enabledNetworks: enabledNetworks)
            }
            VStack(alignment: .leading, spacing: LiteTheme.Spacing.xxs) {
                Text("Card Information")
                    .font(LiteTheme.Typography.body())
                    .foregroundColor(LiteTheme.Colors.textSecondary)
                HStack(spacing: LiteTheme.Spacing.s) {
                    LiteIcons.creditCard
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundColor(LiteTheme.Colors.textSecondary)
                    LiteCardNumberField(
                        lite,
                        chrome: .plain,
                        showsBrandAccessory: false,
                        onShowsInvalid: { numberInvalid = $0 }
                    )
                    .frame(maxWidth: .infinity)
                    LiteExpiryField(lite, chrome: .plain, onShowsInvalid: { expiryInvalid = $0 })
                        .frame(minWidth: expiryWidth)
                    LiteCVVField(lite, chrome: .plain, onShowsInvalid: { cvvInvalid = $0 })
                        .frame(minWidth: cvvWidth)
                }
                .padding(.horizontal, LiteTheme.Spacing.m)
                .frame(height: LiteTheme.inputHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: LiteTheme.Radii.pill, style: .continuous)
                        .stroke(border, lineWidth: 1)
                )

                if let lineError {
                    Text(lineError)
                        .font(LiteTheme.Typography.captionMedium())
                        .foregroundColor(LiteTheme.Colors.error)
                }
            }
            pillField(label: "Cardholder Name", labelSuffix: "(Optional)", showsInvalid: false, error: nil) {
                LiteCardholderNameField(lite, chrome: .plain)
            }
            if showStoreToggle { storeToggle }
        }
    }

    // MARK: - Shared chrome

    private var storeToggle: some View {
        HStack {
            Text("Save card for future purchase")
                .font(LiteTheme.Typography.body())
                .foregroundColor(LiteTheme.Colors.textPrimary)
            Spacer(minLength: LiteTheme.Spacing.s)
            LiteSwitch(isOn: $lite.storeForFuture)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Save card for future purchase")
        .accessibilityAddTraits(.isButton)
    }

    private func pillField<Content: View>(
        label: String,
        labelSuffix: String? = nil,
        showsInvalid: Bool,
        error: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LiteTheme.Spacing.xxs) {
            HStack(spacing: LiteTheme.Spacing.xxxs) {
                Text(label)
                    .font(LiteTheme.Typography.body())
                    .foregroundColor(LiteTheme.Colors.textSecondary)
                if let labelSuffix {
                    Text(labelSuffix)
                        .font(LiteTheme.Typography.body())
                        .foregroundColor(LiteTheme.Colors.textSecondary)
                }
            }
            content()
                .padding(.horizontal, LiteTheme.Spacing.m)
                .frame(height: LiteTheme.inputHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: LiteTheme.Radii.pill, style: .continuous)
                        .stroke(showsInvalid ? LiteTheme.Colors.error : LiteTheme.Colors.border, lineWidth: 1)
                )
            if let error {
                Text(error)
                    .font(LiteTheme.Typography.captionMedium())
                    .foregroundColor(LiteTheme.Colors.error)
            }
        }
    }

    private func compactCell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, LiteTheme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: LiteTheme.inputHeight, maxHeight: LiteTheme.inputHeight, alignment: .leading)
    }
}
#endif
