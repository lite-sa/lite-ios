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
    /// merchant `onDetailedChange`.
    var onStateChange: ((FieldState) -> Void)?

    /// Merchant-facing change. The payload never includes the typed text.
    var onDetailedChange: ((LiteCardFieldChange) -> Void)?

    /// Called when the user advances from the keyboard, and when expiry becomes valid.
    var onAdvance: (() -> Void)?

    var editingEnabled: Bool = true {
        didSet { textField.isEnabled = editingEnabled }
    }

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

    private let textField = SecureCardTextField()
    private var hasFocus = false

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
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

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
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.delegate = self
        textField.restorationIdentifier = nil
        textField.adjustsFontForContentSizeCategory = true
        textField.allowsCopyOrCut = { [weak self] in
            guard let self else { return false }
            return LiteFieldClipboard.allowsCopyOrCut(self.type)
        }
        textField.announcedValue = { [weak self] in
            guard let self else { return "" }
            return LiteFieldCopy.accessibilityValue(brand: self.cardBrand, error: self.currentError)
        }
        textField.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
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

    func focus() {
        textField.becomeFirstResponder()
    }

    func applyContentStyle(textColor: UIColor, placeholderColor: UIColor, font: UIFont) {
        textField.textColor = textColor
        textField.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
        let placeholder = textField.attributedPlaceholder?.string ?? ""
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor, .font: textField.font as Any]
        )
    }

    func revalidate() {
        emitState(notifySubmit: false)
    }

    private var currentError: LiteFieldError?

    private func configureForType() {
        textField.keyboardType = .numberPad
        textField.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17))
        let label = LiteFieldCopy.label(for: type)
        textField.accessibilityLabel = label
        textField.accessibilityHint = nil
        switch type {
        case .cardNumber:
            applyPlaceholder(LiteFieldCopy.placeholder(for: .cardNumber))
            textField.textContentType = .creditCardNumber
            textField.semanticContentAttribute = .forceLeftToRight
            textField.textAlignment = .left
        case .expiry:
            applyPlaceholder(LiteFieldCopy.placeholder(for: .expiry))
            if #available(iOS 17.0, *) { textField.textContentType = .creditCardExpiration }
            textField.semanticContentAttribute = .forceLeftToRight
            textField.textAlignment = .left
        case .cvv:
            applyPlaceholder(LiteFieldCopy.placeholder(for: .cvv))
            textField.isSecureTextEntry = true
            if #available(iOS 17.0, *) { textField.textContentType = .creditCardSecurityCode }
            textField.semanticContentAttribute = .forceLeftToRight
            textField.textAlignment = .left
            if let image = UIImage(named: "ic-cvv", in: LiteResourceBundle.current, compatibleWith: nil) {
                textField.rightView = CardBrandIcons.cardNumberRightView(
                    image: image.withRenderingMode(.alwaysTemplate),
                    accessibilityLabel: label
                )
                textField.rightViewMode = .always
                textField.rightView?.tintColor = LiteTheme.Colors.textSecondaryUIColor
            }
        case .cardholderName:
            applyPlaceholder(LiteFieldCopy.placeholder(for: .cardholderName))
            textField.keyboardType = .default
            textField.returnKeyType = .done
            textField.autocapitalizationType = .words
            textField.textContentType = .name
        }
        emitState(notifySubmit: false)
    }

    private func applyPlaceholder(_ text: String) {
        textField.attributedPlaceholder = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: LiteTheme.Colors.textPlaceholderUIColor]
        )
    }

    // MARK: Keyboard

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if type == .cardNumber || type == .expiry || type == .cardholderName {
            onAdvance?()
        }
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_: UITextField) {
        hasFocus = true
        emitState(notifySubmit: false)
    }

    func textFieldDidEndEditing(_: UITextField) {
        hasFocus = false
        emitState(notifySubmit: false)
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
        emitState(notifySubmit: true)
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

    private func emitState(notifySubmit: Bool) {
        let value = textField.text ?? ""
        let formatValid: Bool
        switch type {
        case .cardNumber:     formatValid = CardValidation.validateCardNumber(value)
        case .expiry:         formatValid = CardValidation.validateExpiry(value)
        case .cvv:            formatValid = CardValidation.validateCVV(value)
        case .cardholderName: formatValid = true
        }
        let brand = type == .cardNumber ? CardValidation.detectCardType(value) : cardBrand
        if type == .cardNumber { cardBrand = brand }
        let change = LiteCardFieldState.resolve(
            type: type,
            isEmpty: value.isEmpty,
            formatValid: formatValid,
            brand: brand,
            focused: hasFocus
        )
        let wasValid = isValid
        isValid = change.valid
        currentError = change.error
        if let error = change.error {
            textField.accessibilityHint = LiteFieldCopy.message(for: error)
        } else {
            textField.accessibilityHint = nil
        }
        updateInvalidStyling(showsInvalid: change.error != nil)
        let state = FieldState(valid: change.valid)
        onChange?(state)
        onStateChange?(state)
        onDetailedChange?(change)
        if notifySubmit && !wasValid && change.valid && type == .expiry {
            onAdvance?()
        }
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

    /// Clear the visible text without telling listeners. Used when the field leaves
    /// the window; the aggregator still holds the value for restore.
    func wipeDisplay() {
        textField.text = ""
        if type == .cardNumber {
            updateBrandIcon(for: .unknown)
        }
    }

    /// Put a retained value back into the field after it returns to a window.
    func restore(_ raw: String) {
        if raw.isEmpty {
            return
        }
        let formatted: String
        switch type {
        case .cardNumber:
            formatted = CardValidation.formatCardNumber(raw)
        case .expiry:
            formatted = CardValidation.formatExpiry(raw)
        case .cvv:
            formatted = CardValidation.sanitizeCVV(raw)
        case .cardholderName:
            formatted = raw
        }
        textField.text = formatted
        if type == .cardNumber {
            updateBrandIcon(for: CardValidation.detectCardType(formatted))
        }
        emitState(notifySubmit: false)
    }

    /// Clear the field value and reset validity — used when the checkout flow restarts.
    func clear() {
        textField.text = ""
        if type == .cardNumber { updateBrandIcon(for: .unknown) }
        emitState(notifySubmit: false)
    }
}

/// PAN and CVV cannot be copied. The accessibility value is the brand or the error, never the typed text.
private final class SecureCardTextField: UITextField {
    var allowsCopyOrCut: () -> Bool = { true }
    var announcedValue: () -> String = { "" }

    override var accessibilityValue: String? {
        get { announcedValue() }
        set { _ = newValue }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let isCopyOrCut = action == #selector(copy(_:)) || action == #selector(cut(_:))
        if isCopyOrCut && !allowsCopyOrCut() {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif
