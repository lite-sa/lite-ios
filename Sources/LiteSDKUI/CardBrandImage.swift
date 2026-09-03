#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import LiteSDKCore

/// SwiftUI card-brand logo — same sizes as Android `brandLogoModifier` / web checkout.
public struct CardBrandImage: View {
    private let brand: CardType

    public init(brand: CardType) {
        self.brand = brand
    }

    public init(scheme: String) {
        self.brand = CardType.from(scheme: scheme)
    }

    public var body: some View {
        let size = Self.logoSize(for: brand)
        if let uiImage = CardBrandIcons.image(for: brand) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .accessibilityLabel(brand.displayName)
        } else {
            Color.clear.frame(width: size.width, height: size.height)
        }
    }

    /// Web: mada/visa `h-8.5 w-12` → 48×34; mastercard `h-7 w-10` → 40×28.
    static func logoSize(for brand: CardType) -> CGSize {
        switch brand {
        case .mastercard: return CGSize(width: 40, height: 28)
        default: return CGSize(width: 48, height: 34)
        }
    }
}

/// Left-aligned mada / visa / mastercard strip — mirrors Android `LiteBrandStrip`.
/// Only shows schemes enabled on the session (`payment_methods.card.networks`).
struct LiteBrandStrip: View {
    var enabledNetworks: [CardNetwork]

    init(enabledNetworks: [CardNetwork] = CardNetwork.allCases) {
        self.enabledNetworks = enabledNetworks
    }

    var body: some View {
        HStack(spacing: LiteTheme.Spacing.m) {
            // Web order: mada → visa → mastercard
            ForEach([CardNetwork.mada, .visa, .mastercard], id: \.self) { network in
                if enabledNetworks.contains(network) {
                    CardBrandImage(brand: network.cardType)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
