#if canImport(UIKit)
import UIKit
import LiteSDKCore

/// Bundled card-brand logos — same artwork as the web hosted fields (`visa.svg`, etc.).
public enum CardBrandIcons {
    private static let bundle = LiteResourceBundle.current

    public static func image(for brand: CardType) -> UIImage? {
        guard let name = brand.iconAssetName else { return nil }
        return UIImage(named: name, in: bundle, compatibleWith: nil)
    }

    /// Builds the trailing accessory view for the card-number field (icon + padding).
    static func cardNumberRightView(image: UIImage, accessibilityLabel: String) -> UIView {
        let height: CGFloat = 24
        let iconWidth: CGFloat = 32
        let iconHeight: CGFloat = 20
        let leadingPadding: CGFloat = 8
        let trailingPadding: CGFloat = 8
        let width = leadingPadding + iconWidth + trailingPadding

        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(
            x: leadingPadding,
            y: (height - iconHeight) / 2,
            width: iconWidth,
            height: iconHeight
        )
        imageView.accessibilityLabel = accessibilityLabel
        container.addSubview(imageView)
        return container
    }
}
#endif
