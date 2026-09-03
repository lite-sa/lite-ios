#if canImport(UIKit)
import SwiftUI
import UIKit
import CoreText

/// Bundled Lite UI icons from Figma / web checkout (same artwork as Android).
enum LiteIcons {
    private static let bundle = LiteResourceBundle.current

    static func image(_ name: String) -> Image {
        if let ui = UIImage(named: name, in: bundle, compatibleWith: nil) {
            return Image(uiImage: ui).renderingMode(.template)
        }
        return Image(systemName: "questionmark")
    }

    /// For icons that must keep authored colors (result wells, teal lock, wordmark).
    static func originalImage(_ name: String) -> Image {
        if let ui = UIImage(named: name, in: bundle, compatibleWith: nil) {
            return Image(uiImage: ui).renderingMode(.original)
        }
        return Image(systemName: "questionmark")
    }

    static var close: Image { image("ic-close") }
    static var copy: Image { image("ic-copy") }
    static var mail: Image { image("ic-mail") }
    static var phone: Image { image("ic-phone") }
    static var creditCard: Image { image("ic-credit-card") }
    static var payWithNewCard: Image { image("ic-pay-with-new-card") }
    static var cvv: Image { image("ic-cvv") }
    static var flash: Image { image("ic-flash") }

    static var resultCheck: Image { originalImage("ic-result-check") }
    static var resultX: Image { originalImage("ic-result-x") }
    static var resultAlert: Image { originalImage("ic-result-alert") }
    static var resultProcessing: Image { originalImage("ic-result-processing") }
    static var secureCheckout: Image { originalImage("ic-secure-checkout") }
    static var liteLogo: Image { originalImage("ic-lite-logo") }
}

/// Registers the bundled Saudi Riyal font once (SPM resource).
public enum LiteFonts {
    private static var didRegister = false
    private static let saudiRiyalGlyph = "\u{E900}"

    public static var saudiRiyalSymbol: String { saudiRiyalGlyph }

    public static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        guard let url = LiteResourceBundle.current.url(forResource: "saudi_riyal", withExtension: "ttf", subdirectory: "Fonts")
                ?? LiteResourceBundle.current.url(forResource: "saudi_riyal", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    public static func saudiRiyal(size: CGFloat) -> Font {
        registerIfNeeded()
        if UIFont(name: "saudi_riyal", size: size) != nil {
            return .custom("saudi_riyal", size: size)
        }
        return .custom("saudi_riyal", size: size)
    }
}
#endif
