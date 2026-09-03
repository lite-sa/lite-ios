#if canImport(UIKit)
import UIKit
import LiteSDKCore

/// A single secure card input field.
///
/// It **is** a `UIView` — native apps add it to their view hierarchy directly; there is no
/// `mount(selector)` (that is a web/DOM concept — DESIGN §6.1). The field's raw text stays
/// inside the view; only `{ valid }` is exposed publicly via `onChange`. The unformatted value
/// is `internal` so the SDK's pay flow can collect it, but merchant code cannot read it.
final class LiteCardField: UIView, UITextFieldDelegate {

    /// Visual chrome — `.system` draws its own border; `.plain` leaves borders to a parent container.
    enum Chrome: Sendable, Equatable {
        case system
        case plain
    }

    /// Which card field this is.
    let type: CardElementType

    /// Fired on every edit with the current validity — matches the web `change` event
    /// (payload `FieldState { valid }`).
    var onChange: ((FieldState) -> Void)?

    /// Fired when invalid chrome should appear (`!valid && value.nonEmpty`).
    /// Cardholder name never shows invalid chrome (always optional / valid).
    var onShowsInvalidChange: ((Bool) -> Void)?

    /// Internal hook used by `LiteCardAggregator` to observe validity without clobbering the
    /// public `onChange` a merchant may have set.
    var onStateChange: ((FieldState) -> Void)?

    /// Current validity. Empty is invalid for required fields; cardholder name is optional
    /// (empty is valid). `showsInvalid` gates chrome so an untouched field never looks like an
    /// error (matches web `!valid && value.length > 0`).
    private(set) var isValid: Bool = false

    /// True when the field has content and is invalid — parent pill/compact chrome uses this.
    private(set) var showsInvalid: Bool = false

    /// Detected card brand for the card-number field (web `cardType` state).
    private(set) var cardBrand: CardType = .unknown

    /// Field chrome. `.plain` clears the system border so styled containers can draw it.
    var chrome: Chrome = .system {
        didSet { applyChrome() }
    }

    /// When false, the card-number brand accessory is hidden (e.g. line layout draws its own icon).
    var showsBrandAccessory: Bool = true {
        didSet {
            if type == .cardNumber { updateBrandIcon(for: cardBrand) }
        }
    }

    private let textField = UITextField()

    /// Unformatted value collected at pay time. `internal` on purpose (PCI encapsulation).
    var rawValue: String {
        let text = textField.text ?? ""
        switch type {
        case .cardNumber:
            return text.filter { !$0.isWhitespace }
        case .expiry, .cvv, .cardholderName:
            return text
        }
    }

    // MARK: Init

    init(type: CardElementType) {
        self.type = type
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: chrome == .plain ? 48 : 44)
    }

    // MARK: Setup

    private func setup() {
        overrideUserInterfaceStyle = .light
        textField.overrideUserInterfaceStyle = .light
        textField.textColor = LiteTheme.Colors.textPrimaryUIColor
        textField.tintColor = LiteTheme.Colors.primaryUIColor
        textField.keyboardAppearance = .light
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.delegate = self
        textField.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        attachDismissAccessory()
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configureForType()
        applyChrome()
    }

    private func applyChrome() {
        switch chrome {
        case .system:
            textField.borderStyle = .roundedRect
            textField.backgroundColor = nil
        case .plain:
            textField.borderStyle = .none
            textField.backgroundColor = .clear
        }
        updateInvalidStyling(showsInvalid: showsInvalid)
    }

    private func configureForType() {
        textField.keyboardType = .numberPad
        switch type {
        case .cardNumber:
            applyPlaceholder("1234 1234 1234 1234")
            textField.textContentType = .creditCardNumber
            textField.accessibilityLabel = "Card number"
        case .expiry:
            applyPlaceholder("MM/YY")
            if #available(iOS 17.0, *) { textField.textContentType = .creditCardExpiration }
            textField.accessibilityLabel = "Expiration"
        case .cvv:
            applyPlaceholder("CVV")
            textField.isSecureTextEntry = true
            if #available(iOS 17.0, *) { textField.textContentType = .creditCardSecurityCode }
            textField.accessibilityLabel = "CVV security code"
            if let image = UIImage(named: "ic-cvv", in: LiteResourceBundle.current, compatibleWith: nil) {
                textField.rightView = CardBrandIcons.cardNumberRightView(
                    image: image.withRenderingMode(.alwaysTemplate),
                    accessibilityLabel: "CVV"
                )
                textField.rightViewMode = .always
                textField.rightView?.tintColor = LiteTheme.Colors.textSecondaryUIColor
            }
        case .cardholderName:
            applyPlaceholder("Cardholder name (optional)")
            textField.keyboardType = .default
            textField.returnKeyType = .done
            textField.autocapitalizationType = .words
            textField.textContentType = .name
            textField.accessibilityLabel = "Cardholder name"
        }
        emitState()
    }

    private func applyPlaceholder(_ text: String) {
        textField.attributedPlaceholder = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: LiteTheme.Colors.textPlaceholderUIColor]
        )
    }

    // MARK: Keyboard

    /// Number pads have no Return key; without this, the keyboard covers Pay and cannot be dismissed.
    private func attachDismissAccessory() {
        let toolbar = UIToolbar()
        toolbar.overrideUserInterfaceStyle = .light
        toolbar.barTintColor = LiteTheme.Colors.backgroundUIColor
        toolbar.tintColor = LiteTheme.Colors.primaryUIColor
        toolbar.isTranslucent = false
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissKeyboard)
        )
        done.accessibilityLabel = "Done"
        toolbar.items = [flex, done]
        toolbar.sizeToFit()
        textField.inputAccessoryView = toolbar
    }

    @objc private func dismissKeyboard() {
        textField.resignFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Editing

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        // Allow deletions / empty replacement.
        if string.isEmpty { return true }

        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return false }
        let proposed = current.replacingCharacters(in: swiftRange, with: string)

        switch type {
        case .cardNumber:
            // Digits only; cap unformatted length at 19 (13–19 PAN).
            let digits = proposed.filter { $0.isASCII && $0.isNumber }
            guard string.filter({ !($0.isASCII && $0.isNumber) && !$0.isWhitespace }).isEmpty else { return false }
            return digits.count <= 19
        case .expiry:
            let digits = proposed.filter(\.isNumber)
            guard string.filter({ !$0.isNumber && $0 != "/" }).isEmpty else { return false }
            return digits.count <= 4
        case .cvv:
            guard string.allSatisfy(\.isNumber) else { return false }
            return proposed.filter(\.isNumber).count <= 4
        case .cardholderName:
            return true
        }
    }

    @objc private func editingChanged() {
        let current = textField.text ?? ""
        let cursorOffset = textField.offset(from: textField.beginningOfDocument, to: textField.selectedTextRange?.start ?? textField.endOfDocument)
        let significantBefore: Int = {
            let idx = min(max(cursorOffset, 0), current.count)
            let prefix = String(current.prefix(idx))
            switch type {
            case .cardholderName: return idx
            case .cardNumber, .expiry, .cvv: return prefix.filter(\.isNumber).count
            }
        }()
        let formatted: String
        switch type {
        case .cardNumber:     formatted = CardValidation.formatCardNumber(current)
        case .expiry:         formatted = CardValidation.formatExpiry(current)
        case .cvv:            formatted = CardValidation.sanitizeCVV(current)
        case .cardholderName: formatted = current
        }
        // Reassigning text does not re-fire .editingChanged, so there is no recursion.
        if formatted != current {
            textField.text = formatted
            let newOffset: Int = {
                switch type {
                case .cardholderName:
                    return min(significantBefore, formatted.count)
                case .cardNumber, .expiry, .cvv:
                    var seen = 0
                    if significantBefore <= 0 { return 0 }
                    for (i, ch) in formatted.enumerated() {
                        if ch.isNumber {
                            seen += 1
                            if seen == significantBefore { return i + 1 }
                        }
                    }
                    return formatted.count
                }
            }()
            if let start = textField.position(from: textField.beginningOfDocument, offset: newOffset) {
                textField.selectedTextRange = textField.textRange(from: start, to: start)
            }
        }
        if type == .cardNumber {
            updateBrandIcon(for: CardValidation.detectCardType(formatted))
        }
        emitState()
    }

    private func updateBrandIcon(for brand: CardType) {
        cardBrand = brand
        guard showsBrandAccessory,
              brand != .unknown,
              let image = CardBrandIcons.image(for: brand)
        else {
            textField.rightView = nil
            textField.rightViewMode = .never
            return
        }
        textField.rightView = CardBrandIcons.cardNumberRightView(
            image: image,
            accessibilityLabel: brand.displayName
        )
        textField.rightViewMode = .always
    }

    private func emitState() {
        let value = textField.text ?? ""
        let valid: Bool
        switch type {
        case .cardNumber:     valid = CardValidation.validateCardNumber(value)
        case .expiry:         valid = CardValidation.validateExpiry(value)
        case .cvv:            valid = CardValidation.validateCVV(value)
        case .cardholderName: valid = true // optional — empty allowed
        }
        isValid = valid
        updateInvalidStyling(showsInvalid: !valid && !value.isEmpty)
        let state = FieldState(valid: valid)
        onChange?(state)
        onStateChange?(state)
    }

    private func updateInvalidStyling(showsInvalid: Bool) {
        let changed = self.showsInvalid != showsInvalid
        self.showsInvalid = showsInvalid
        if changed { onShowsInvalidChange?(showsInvalid) }

        // Parent draws borders in `.plain` mode.
        guard chrome == .system else {
            textField.layer.borderWidth = 0
            textField.layer.borderColor = nil
            textField.layer.cornerRadius = 0
            return
        }
        textField.layer.borderWidth = showsInvalid ? 1 : 0
        textField.layer.borderColor = showsInvalid ? LiteTheme.Colors.errorUIColor.cgColor : nil
        textField.layer.cornerRadius = showsInvalid ? 5 : 0
    }

    /// Clear the field value and reset validity — used when the checkout flow restarts.
    func clear() {
        textField.text = ""
        if type == .cardNumber { updateBrandIcon(for: .unknown) }
        emitState()
    }
}
#endif
