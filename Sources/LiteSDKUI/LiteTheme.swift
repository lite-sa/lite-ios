#if canImport(UIKit)
import SwiftUI
import UIKit

/// Figma Final Checkout Mobile tokens (Business Dashboard).
/// Poppins when registered on the device; otherwise the system UI font stack.
public enum LiteTheme {

    public enum Colors {
        public static let primary = Color(liteHex: 0x6335EA)
        public static let textPrimary = Color(liteHex: 0x161616)
        public static let textSecondary = Color(liteHex: 0x737373)
        public static let textPlaceholder = Color(liteHex: 0xA2A2A2)
        public static let textOnPrimary = Color(liteHex: 0xF4F4F4)
        public static let border = Color(liteHex: 0xDEDEDE)
        /// Web `--input` / inactive switch track (oklch 0.922 ≈ #EBEBEB).
        public static let input = Color(liteHex: 0xEBEBEB)
        public static let background = Color.white
        public static let muted = Color(liteHex: 0xF4F4F4)
        public static let error = Color(liteHex: 0xCD0202)
        public static let success = Color(liteHex: 0x02CDC6)
        public static let successSoft = Color(liteHex: 0xE6FAF9)
        public static let failure = Color(liteHex: 0xCD0202)
        public static let failureSoft = Color(liteHex: 0xFAE6E6)
        public static let processing = Color(liteHex: 0x6335EA)
        public static let processingSoft = Color(liteHex: 0xF0EBFF)

        public static var primaryUIColor: UIColor { UIColor(liteHex: 0x6335EA) }
        public static var textPrimaryUIColor: UIColor { UIColor(liteHex: 0x161616) }
        public static var textSecondaryUIColor: UIColor { UIColor(liteHex: 0x737373) }
        public static var textPlaceholderUIColor: UIColor { UIColor(liteHex: 0xA2A2A2) }
        public static var borderUIColor: UIColor { UIColor(liteHex: 0xDEDEDE) }
        public static var errorUIColor: UIColor { UIColor(liteHex: 0xCD0202) }
        public static var successUIColor: UIColor { UIColor(liteHex: 0x02CDC6) }
        public static var mutedUIColor: UIColor { UIColor(liteHex: 0xF4F4F4) }
        public static var backgroundUIColor: UIColor { .white }
    }

    public enum Radii {
        public static let pill: CGFloat = 100
        public static let sheet: CGFloat = 12
        public static let compact: CGFloat = 8
        public static let compactError: CGFloat = 12
        public static let card: CGFloat = 8
        public static let iconWell: CGFloat = 8
        /// Express payment button (Apple Pay) — Figma `rounded-[10px]`.
        public static let express: CGFloat = 10
    }

    public enum Spacing {
        public static let xxxs: CGFloat = 2
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 20
        public static let xl: CGFloat = 24
    }

    public static let inputHeight: CGFloat = 48
    /// Express payment CTA height — Figma Payment Option `h-[44px]`.
    public static let expressButtonHeight: CGFloat = 44

    public enum Typography {
        public static func title() -> Font { semiBold(size: 16) }
        public static func titleLarge() -> Font { semiBold(size: 18) }
        public static func body() -> Font { regular(size: 14) }
        public static func bodyMedium() -> Font { medium(size: 14) }
        public static func bodySemiBold() -> Font { semiBold(size: 14) }
        public static func caption() -> Font { regular(size: 12) }
        public static func captionMedium() -> Font { medium(size: 12) }
        public static func captionSemiBold() -> Font { semiBold(size: 12) }

        public static func regular(size: CGFloat) -> Font {
            if UIFont(name: "Poppins-Regular", size: size) != nil {
                return .custom("Poppins-Regular", size: size)
            }
            return .system(size: size, weight: .regular)
        }

        public static func medium(size: CGFloat) -> Font {
            if UIFont(name: "Poppins-Medium", size: size) != nil {
                return .custom("Poppins-Medium", size: size)
            }
            return .system(size: size, weight: .medium)
        }

        public static func semiBold(size: CGFloat) -> Font {
            if UIFont(name: "Poppins-SemiBold", size: size) != nil {
                return .custom("Poppins-SemiBold", size: size)
            }
            return .system(size: size, weight: .semibold)
        }

        public static func uiRegular(size: CGFloat) -> UIFont {
            UIFont(name: "Poppins-Regular", size: size) ?? .systemFont(ofSize: size, weight: .regular)
        }

        public static func uiMedium(size: CGFloat) -> UIFont {
            UIFont(name: "Poppins-Medium", size: size) ?? .systemFont(ofSize: size, weight: .medium)
        }

        public static func uiSemiBold(size: CGFloat) -> UIFont {
            UIFont(name: "Poppins-SemiBold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        }
    }
}

/// Formats session minor-unit amount as a plain string (`"125.00 SAR"`).
/// Prefer `LiteMoneyAmount` in UI so SAR uses the bundled riyal font, not this string.
public func formatLiteAmount(amountMinor: Int, currency: String) -> String {
    let major = formatLiteMajorAmount(amountMinor: amountMinor)
    if currency.uppercased() == "SAR" {
        return "\(major) SAR"
    }
    return "\(major) \(currency)"
}

// MARK: - Color helpers

extension Color {
    init(liteHex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((liteHex >> 16) & 0xFF) / 255,
            green: Double((liteHex >> 8) & 0xFF) / 255,
            blue: Double(liteHex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension UIColor {
    convenience init(liteHex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((liteHex >> 16) & 0xFF) / 255,
            green: CGFloat((liteHex >> 8) & 0xFF) / 255,
            blue: CGFloat(liteHex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    /// Checkout chrome is designed for a light canvas. Ignore the host app / system dark mode.
    func liteFixedColorScheme() -> some View {
        preferredColorScheme(.light)
    }
}
#endif
