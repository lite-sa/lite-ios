#if canImport(UIKit)
import UIKit

/// Typed style for an individual card field. There is no raw CSS or HTML.
public struct LiteFieldStyle {
    public var textColor: UIColor
    public var placeholderColor: UIColor
    public var font: UIFont
    public var backgroundColor: UIColor
    public var borderColor: UIColor
    public var borderWidth: CGFloat
    public var cornerRadius: CGFloat
    public var padding: UIEdgeInsets
    /// Height will not go below [minimumHeight]. Android uses the same floor.
    public var minHeight: CGFloat
    public var errorColor: UIColor
    public var focusedBorderColor: UIColor

    /// Text and chrome colors, grouped so the field initializer stays within seven parameters.
    public struct Colors {
        public var text: UIColor
        public var placeholder: UIColor
        public var background: UIColor
        public var border: UIColor
        public var error: UIColor
        public var focusedBorder: UIColor

        public init(
            text: UIColor = LiteTheme.Colors.textPrimaryUIColor,
            placeholder: UIColor = LiteTheme.Colors.textPlaceholderUIColor,
            background: UIColor = .white,
            border: UIColor = LiteTheme.Colors.borderUIColor,
            error: UIColor = LiteTheme.Colors.errorUIColor,
            focusedBorder: UIColor = LiteTheme.Colors.primaryUIColor
        ) {
            self.text = text
            self.placeholder = placeholder
            self.background = background
            self.border = border
            self.error = error
            self.focusedBorder = focusedBorder
        }

        public static let standard = Colors()
    }

    public init(
        font: UIFont = .systemFont(ofSize: 17),
        colors: Colors = .standard,
        borderWidth: CGFloat = 1,
        cornerRadius: CGFloat = 8,
        padding: UIEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12),
        minHeight: CGFloat = 48
    ) {
        self.textColor = colors.text
        self.placeholderColor = colors.placeholder
        self.font = font
        self.backgroundColor = colors.background
        self.borderColor = colors.border
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.minHeight = max(Self.minimumHeight, minHeight)
        self.errorColor = colors.error
        self.focusedBorderColor = colors.focusedBorder
    }

    /// Shared with Android. A requested height below this is raised to it.
    public static let minimumHeight: CGFloat = 48

    /// No border. The payment form draws its own chrome around this.
    public static let plain = LiteFieldStyle(
        colors: Colors(background: .clear),
        borderWidth: 0,
        cornerRadius: 0,
        padding: .zero
    )

    public static let standard = LiteFieldStyle()
}
#endif
