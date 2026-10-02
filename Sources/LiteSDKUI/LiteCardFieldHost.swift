#if canImport(UIKit)
import UIKit
import Combine
import LiteSDKCore

/// Shared host for the four public card fields. The inner `LiteCardField` stays internal so `rawValue` is not on a public type.
/// Use `LiteCardNumberFieldView`, `LiteExpiryFieldView`, `LiteCvvFieldView`, or `LiteCardholderNameFieldView`.
public class LiteCardFieldHost: UIView {
    let elementType: CardElementType
    let lite: Lite
    let inner: LiteCardField

    public var onChange: ((LiteCardFieldChange) -> Void)?

    /// Fires when the customer moves to the next field. This is not pay.
    ///
    /// Keyboard return on the card number, expiry, and cardholder name.
    /// Also when expiry first becomes valid.
    /// A valid card number does not fire this, because 13 digits can already be valid.
    /// CVV uses the number pad, which has no return key, so it does not fire this from the keyboard.
    /// Focus has already moved to the next registered field.
    public var onAdvance: (() -> Void)?

    public var style: LiteFieldStyle {
        didSet { applyStyle() }
    }

    private let stack = UIStackView()
    private let privacyCover = UIView()
    private var attached = false
    private var keptValue = false
    private var cancellables = Set<AnyCancellable>()
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var lastAnnouncedError: LiteFieldError?
    private var displayedFocused = false
    private var heightConstraint: NSLayoutConstraint?
    private var leadingPadding: NSLayoutConstraint?
    private var trailingPadding: NSLayoutConstraint?
    private var topPadding: NSLayoutConstraint?
    private var bottomPadding: NSLayoutConstraint?

    init(lite: Lite, type: CardElementType, style: LiteFieldStyle) {
        self.lite = lite
        self.elementType = type
        self.style = style
        self.inner = LiteCardField(type: type)
        super.init(frame: .zero)
        inner.chrome = .plain
        setup()
        bindLite()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    var layoutWidth: CGFloat = UIView.noIntrinsicMetric

    public override var intrinsicContentSize: CGSize {
        CGSize(width: layoutWidth, height: style.minHeight)
    }

    public func focus() {
        inner.focus()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            suspendKeepingValue()
        } else {
            attach()
        }
    }

    /// The field left the window (a full-screen 3DS challenge covers it, or SwiftUI
    /// swapped the form out). The display is wiped. The typed card stays in the
    /// aggregator and is restored on the next attach.
    func suspendKeepingValue() {
        guard attached else { return }
        attached = false
        lite.retainField(inner)
        inner.onDetailedChange = nil
        inner.onAdvance = nil
        inner.onStateChange = nil
        lite.unregisterKeepingValue(inner)
        inner.wipeDisplay()
        removeWindowObservers()
        keptValue = true
    }

    /// Drops the field and clears its card data. The Flutter plugin calls this
    /// when the platform view is destroyed. Merchants should not.
    @_spi(LitePlugin)
    public func detach() {
        let drop = attached || keptValue
        suspendKeepingValue()
        if drop {
            lite.dropRetainedField(elementType)
            keptValue = false
        }
        inner.wipeDisplay()
    }

    private func attach() {
        guard !attached else { return }
        let claimed = lite.register(inner)
        attached = claimed
        isUserInteractionEnabled = claimed
        if !claimed {
            accessibilityHint = "A field of this type is already on screen"
            return
        }
        accessibilityHint = nil
        inner.onDetailedChange = { [weak self] change in
            self?.handle(change)
        }
        bindSubmit()
        observeAppSwitcher()
        let kept = lite.retainedFieldValue(inner.type)
        if kept.isEmpty {
            return
        }
        inner.restore(kept)
    }

    private func setup() {
        inner.translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(inner)
        addSubview(stack)
        privacyCover.isHidden = true
        privacyCover.isAccessibilityElement = false
        privacyCover.translatesAutoresizingMaskIntoConstraints = false
        privacyCover.backgroundColor = .white
        addSubview(privacyCover)

        let height = inner.heightAnchor.constraint(greaterThanOrEqualToConstant: style.minHeight)
        heightConstraint = height
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.padding.left)
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.padding.right)
        let top = stack.topAnchor.constraint(equalTo: topAnchor, constant: style.padding.top)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -style.padding.bottom)
        leadingPadding = leading
        trailingPadding = trailing
        topPadding = top
        bottomPadding = bottom
        NSLayoutConstraint.activate([
            height,
            leading,
            trailing,
            top,
            bottom,
            privacyCover.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            privacyCover.topAnchor.constraint(equalTo: inner.topAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
        ])

        inner.onDetailedChange = { [weak self] change in
            self?.handle(change)
        }
        bindSubmit()
    }

    private func bindSubmit() {
        inner.onAdvance = { [weak self] in
            guard let self else { return }
            self.lite.focusField(after: self.elementType)
            self.onAdvance?()
        }
    }

    private func bindLite() {
        lite.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.inner.editingEnabled = phase != .paying
            }
            .store(in: &cancellables)
        lite.$session
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.inner.revalidate()
            }
            .store(in: &cancellables)
    }

    private func applyStyle() {
        heightConstraint?.constant = style.minHeight
        backgroundColor = style.backgroundColor
        layer.cornerRadius = style.cornerRadius
        layer.borderWidth = style.borderWidth
        clipsToBounds = style.cornerRadius > 0
        inner.applyContentStyle(
            textColor: style.textColor,
            placeholderColor: style.placeholderColor,
            font: style.font
        )
        leadingPadding?.constant = style.padding.left
        trailingPadding?.constant = -style.padding.right
        topPadding?.constant = style.padding.top
        bottomPadding?.constant = -style.padding.bottom
        let coverColor: UIColor
        if style.backgroundColor.cgColor.alpha > 0.99 {
            coverColor = style.backgroundColor
        } else {
            coverColor = .white
        }
        privacyCover.backgroundColor = coverColor
        refreshBorder(error: lastAnnouncedError, focused: displayedFocused)
    }

    private func handle(_ change: LiteCardFieldChange) {
        displayedFocused = change.focused
        refreshBorder(error: change.error, focused: change.focused)
        if let message = change.message, change.error != lastAnnouncedError {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        lastAnnouncedError = change.error
        onChange?(change)
    }

    private func refreshBorder(error: LiteFieldError?, focused: Bool) {
        guard style.borderWidth > 0 else {
            layer.borderWidth = 0
            return
        }
        layer.borderWidth = style.borderWidth
        if error != nil {
            layer.borderColor = style.errorColor.cgColor
        } else if focused {
            layer.borderColor = style.focusedBorderColor.cgColor
        } else {
            layer.borderColor = style.borderColor.cgColor
        }
    }

    private func removeWindowObservers() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        resignObserver = nil
        activeObserver = nil
    }

    private func observeAppSwitcher() {
        let center = NotificationCenter.default
        resignObserver = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.privacyCover.isHidden = false
        }
        activeObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.privacyCover.isHidden = true
        }
    }
}

/// Card number. Add this view to your hierarchy. The typed number never leaves the SDK.
public final class LiteCardNumberFieldView: LiteCardFieldHost {
    public var showsBrandIcon: Bool {
        get { inner.showsBrandAccessory }
        set { inner.showsBrandAccessory = newValue }
    }

    public init(lite: Lite, style: LiteFieldStyle = .standard) {
        super.init(lite: lite, type: .cardNumber, style: style)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Expiry, `MM/YY`. Digits stay left-to-right.
public final class LiteExpiryFieldView: LiteCardFieldHost {
    public init(lite: Lite, style: LiteFieldStyle = .standard) {
        super.init(lite: lite, type: .expiry, style: style)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// CVV. Secure entry, and copy/cut are disabled.
public final class LiteCvvFieldView: LiteCardFieldHost {
    public init(lite: Lite, style: LiteFieldStyle = .standard) {
        super.init(lite: lite, type: .cvv, style: style)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Optional cardholder name.
public final class LiteCardholderNameFieldView: LiteCardFieldHost {
    public init(lite: Lite, style: LiteFieldStyle = .standard) {
        super.init(lite: lite, type: .cardholderName, style: style)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
