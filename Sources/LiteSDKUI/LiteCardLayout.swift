#if canImport(UIKit)
import Foundation

/// Configurable card field layouts matching Figma “Add a new card” variants.
/// Same aggregator / validation / JWE path for every layout — only arrangement and chrome change.
public enum LiteCardLayout: String, CaseIterable, Sendable {
    /// Compact field — denser stacked “Card Information” group (8–12px radii). Default.
    case compact
    /// Separate fields — number, expiry | CVV, optional cardholder (pill inputs).
    case form
    /// One line — single combined card entry row (+ optional cardholder).
    case line
}
#endif
