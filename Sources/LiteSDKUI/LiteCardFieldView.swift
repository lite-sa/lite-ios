#if canImport(UIKit)
import SwiftUI
import LiteSDKCore

/// SwiftUI card number field. The typed number stays inside the SDK view.
///
/// `onAdvance` fires on keyboard return. It does not fire when the number first becomes valid, and it does not pay.
public struct LiteCardNumberField: View {
    private let lite: Lite
    private let style: LiteFieldStyle
    private let showsBrandIcon: Bool
    private let onChange: ((LiteCardFieldChange) -> Void)?
    private let onAdvance: (() -> Void)?

    public init(
        lite: Lite,
        style: LiteFieldStyle = .standard,
        showsBrandIcon: Bool = true,
        onChange: ((LiteCardFieldChange) -> Void)? = nil,
        onAdvance: (() -> Void)? = nil
    ) {
        self.lite = lite
        self.style = style
        self.showsBrandIcon = showsBrandIcon
        self.onChange = onChange
        self.onAdvance = onAdvance
    }

    public var body: some View {
        LiteCardFieldRepresentable(
            style: style,
            showsBrandIcon: showsBrandIcon,
            onChange: onChange,
            onAdvance: onAdvance,
            make: { LiteCardNumberFieldView(lite: lite, style: style) }
        )
        .frame(minHeight: style.minHeight)
    }
}

/// SwiftUI expiry field (`MM/YY`).
///
/// `onAdvance` fires on keyboard return and when the date first becomes valid. It does not pay.
public struct LiteExpiryField: View {
    private let lite: Lite
    private let style: LiteFieldStyle
    private let onChange: ((LiteCardFieldChange) -> Void)?
    private let onAdvance: (() -> Void)?

    public init(
        lite: Lite,
        style: LiteFieldStyle = .standard,
        onChange: ((LiteCardFieldChange) -> Void)? = nil,
        onAdvance: (() -> Void)? = nil
    ) {
        self.lite = lite
        self.style = style
        self.onChange = onChange
        self.onAdvance = onAdvance
    }

    public var body: some View {
        LiteCardFieldRepresentable(
            style: style,
            showsBrandIcon: true,
            onChange: onChange,
            onAdvance: onAdvance,
            make: { LiteExpiryFieldView(lite: lite, style: style) }
        )
        .frame(minHeight: style.minHeight)
    }
}

/// SwiftUI CVV field.
///
/// The number pad has no return key, so `onAdvance` does not fire from the keyboard. It does not pay.
public struct LiteCvvField: View {
    private let lite: Lite
    private let style: LiteFieldStyle
    private let onChange: ((LiteCardFieldChange) -> Void)?
    private let onAdvance: (() -> Void)?

    public init(
        lite: Lite,
        style: LiteFieldStyle = .standard,
        onChange: ((LiteCardFieldChange) -> Void)? = nil,
        onAdvance: (() -> Void)? = nil
    ) {
        self.lite = lite
        self.style = style
        self.onChange = onChange
        self.onAdvance = onAdvance
    }

    public var body: some View {
        LiteCardFieldRepresentable(
            style: style,
            showsBrandIcon: true,
            onChange: onChange,
            onAdvance: onAdvance,
            make: { LiteCvvFieldView(lite: lite, style: style) }
        )
        .frame(minHeight: style.minHeight)
    }
}

/// SwiftUI cardholder name field. Optional for pay.
///
/// `onAdvance` fires on keyboard return. It does not pay.
public struct LiteCardholderNameField: View {
    private let lite: Lite
    private let style: LiteFieldStyle
    private let onChange: ((LiteCardFieldChange) -> Void)?
    private let onAdvance: (() -> Void)?

    public init(
        lite: Lite,
        style: LiteFieldStyle = .standard,
        onChange: ((LiteCardFieldChange) -> Void)? = nil,
        onAdvance: (() -> Void)? = nil
    ) {
        self.lite = lite
        self.style = style
        self.onChange = onChange
        self.onAdvance = onAdvance
    }

    public var body: some View {
        LiteCardFieldRepresentable(
            style: style,
            showsBrandIcon: true,
            onChange: onChange,
            onAdvance: onAdvance,
            make: { LiteCardholderNameFieldView(lite: lite, style: style) }
        )
        .frame(minHeight: style.minHeight)
    }
}

private struct LiteCardFieldRepresentable: UIViewRepresentable {
    let style: LiteFieldStyle
    let showsBrandIcon: Bool
    let onChange: ((LiteCardFieldChange) -> Void)?
    let onAdvance: (() -> Void)?
    let make: () -> LiteCardFieldHost

    func makeUIView(context _: Context) -> LiteCardFieldHost {
        let view = make()
        apply(view)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: LiteCardFieldHost, context _: Context) {
        apply(uiView)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: LiteCardFieldHost,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        uiView.layoutWidth = width
        let height: CGFloat
        if let proposed = proposal.height, proposed.isFinite, proposed > 0 {
            height = proposed
        } else {
            height = uiView.style.minHeight
        }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ uiView: LiteCardFieldHost, coordinator _: ()) {
        uiView.suspendKeepingValue()
    }

    private func apply(_ view: LiteCardFieldHost) {
        view.style = style
        if let number = view as? LiteCardNumberFieldView {
            number.showsBrandIcon = showsBrandIcon
        }
        view.onChange = { change in
            DispatchQueue.main.async { onChange?(change) }
        }
        view.onAdvance = {
            DispatchQueue.main.async { onAdvance?() }
        }
    }
}
#endif
