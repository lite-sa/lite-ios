import Foundation

/// Pure (PassKit-free) helpers for mapping session Apple Pay config onto native types.
/// The UI layer converts these into `PKPaymentNetwork` / `PKMerchantCapability`.
public enum ApplePayConfig {

    /// Session `amount` is minor units; Apple Pay summary items use major units.
    public static func majorUnitAmount(minorUnits: Int) -> Decimal {
        Decimal(minorUnits) / Decimal(100)
    }

    public enum Network: String, Sendable, CaseIterable {
        case visa
        case masterCard
        case amex
        case discover
        case mada

        public static func parse(_ raw: String) -> Network? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "visa": return .visa
            case "mastercard", "master_card": return .masterCard
            case "amex", "americanexpress", "american_express": return .amex
            case "discover": return .discover
            case "mada": return .mada
            default: return nil
            }
        }
    }

    public enum Capability: String, Sendable, CaseIterable {
        case threeDSecure
        case credit
        case debit
        case emv

        public static func parse(_ raw: String) -> Capability? {
            // Same names as Apple Pay JS / session config; compare case-insensitively
            // so `supports3DS` and `supportscredit` both map (Network.parse style).
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "supports3ds": return .threeDSecure
            case "supportscredit": return .credit
            case "supportsdebit": return .debit
            case "supportsemv": return .emv
            default: return nil
            }
        }
    }

    public static func networks(from raw: [String]) -> [Network] {
        raw.compactMap(Network.parse)
    }

    public static func capabilities(from raw: [String]) -> [Capability] {
        raw.compactMap(Capability.parse)
    }

    /// Prefer Apple Pay config networks when present; otherwise defaults. Either source is then
    /// filtered so schemes explicitly `false` on `payment_methods.card.networks` are excluded
    /// (web `resolveSupportedNetworks`).
    public static func resolveSupportedNetworks(
        applePayNetworks: [String]?,
        cardNetworks: CardNetworks?
    ) -> [String] {
        let candidates: [String]
        if let applePayNetworks, !applePayNetworks.isEmpty {
            candidates = applePayNetworks
        } else {
            candidates = ["amex", "discover", "masterCard", "visa", "mada"]
        }
        guard let cardNetworks else { return candidates }
        return candidates.filter { appleNetwork in
            // Web: exclude only when networks[key] === false; unknown keys (amex/discover) stay.
            switch Network.parse(appleNetwork) {
            case .visa: return cardNetworks.visa != false
            case .masterCard: return cardNetworks.mastercard != false
            case .mada: return cardNetworks.mada != false
            default: return true
            }
        }
    }
}
