#if canImport(UIKit)
import SwiftUI
import LiteSDKCore

/// Internal SwiftUI card fields used by `LiteCardEntryView` / the payment form.
/// Not a merchant integration API — use `LitePaymentSheet` or `LitePaymentForm`.
struct LiteCardNumberField: View {
    private let lite: Lite
    private let chrome: LiteCardField.Chrome
    private let showsBrandAccessory: Bool
    private let onChange: ((FieldState) -> Void)?
    private let onShowsInvalid: ((Bool) -> Void)?

    init(
        _ lite: Lite,
        chrome: LiteCardField.Chrome = .system,
        showsBrandAccessory: Bool = true,
        onChange: ((FieldState) -> Void)? = nil,
        onShowsInvalid: ((Bool) -> Void)? = nil
    ) {
        self.lite = lite
        self.chrome = chrome
        self.showsBrandAccessory = showsBrandAccessory
        self.onChange = onChange
        self.onShowsInvalid = onShowsInvalid
    }

    var body: some View {
        LiteFieldRepresentable(
            type: .cardNumber,
            lite: lite,
            chrome: chrome,
            showsBrandAccessory: showsBrandAccessory,
            onChange: onChange,
            onShowsInvalid: onShowsInvalid
        )
    }
}

struct LiteExpiryField: View {
    private let lite: Lite
    private let chrome: LiteCardField.Chrome
    private let onChange: ((FieldState) -> Void)?
    private let onShowsInvalid: ((Bool) -> Void)?

    init(
        _ lite: Lite,
        chrome: LiteCardField.Chrome = .system,
        onChange: ((FieldState) -> Void)? = nil,
        onShowsInvalid: ((Bool) -> Void)? = nil
    ) {
        self.lite = lite
        self.chrome = chrome
        self.onChange = onChange
        self.onShowsInvalid = onShowsInvalid
    }

    var body: some View {
        LiteFieldRepresentable(
            type: .expiry,
            lite: lite,
            chrome: chrome,
            showsBrandAccessory: true,
            onChange: onChange,
            onShowsInvalid: onShowsInvalid
        )
    }
}

struct LiteCVVField: View {
    private let lite: Lite
    private let chrome: LiteCardField.Chrome
    private let onChange: ((FieldState) -> Void)?
    private let onShowsInvalid: ((Bool) -> Void)?

    init(
        _ lite: Lite,
        chrome: LiteCardField.Chrome = .system,
        onChange: ((FieldState) -> Void)? = nil,
        onShowsInvalid: ((Bool) -> Void)? = nil
    ) {
        self.lite = lite
        self.chrome = chrome
        self.onChange = onChange
        self.onShowsInvalid = onShowsInvalid
    }

    var body: some View {
        LiteFieldRepresentable(
            type: .cvv,
            lite: lite,
            chrome: chrome,
            showsBrandAccessory: true,
            onChange: onChange,
            onShowsInvalid: onShowsInvalid
        )
    }
}

struct LiteCardholderNameField: View {
    private let lite: Lite
    private let chrome: LiteCardField.Chrome
    private let onChange: ((FieldState) -> Void)?
    private let onShowsInvalid: ((Bool) -> Void)?

    init(
        _ lite: Lite,
        chrome: LiteCardField.Chrome = .system,
        onChange: ((FieldState) -> Void)? = nil,
        onShowsInvalid: ((Bool) -> Void)? = nil
    ) {
        self.lite = lite
        self.chrome = chrome
        self.onChange = onChange
        self.onShowsInvalid = onShowsInvalid
    }

    var body: some View {
        LiteFieldRepresentable(
            type: .cardholderName,
            lite: lite,
            chrome: chrome,
            showsBrandAccessory: true,
            onChange: onChange,
            onShowsInvalid: onShowsInvalid
        )
    }
}

/// Internal bridge from a `LiteCardField` (UIView) into SwiftUI, registering it with `Lite`.
private struct LiteFieldRepresentable: UIViewRepresentable {
    let type: CardElementType
    let lite: Lite
    let chrome: LiteCardField.Chrome
    let showsBrandAccessory: Bool
    let onChange: ((FieldState) -> Void)?
    let onShowsInvalid: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(lite: lite)
    }

    final class Coordinator {
        let lite: Lite
        init(lite: Lite) { self.lite = lite }
    }

    func makeUIView(context: Context) -> LiteCardField {
        let field = LiteCardField(type: type)
        field.chrome = chrome
        field.showsBrandAccessory = showsBrandAccessory
        // Defer SwiftUI `@State` / ObservableObject updates out of the representable lifecycle.
        field.onChange = { state in
            DispatchQueue.main.async { onChange?(state) }
        }
        field.onShowsInvalidChange = { showsInvalid in
            DispatchQueue.main.async { onShowsInvalid?(showsInvalid) }
        }
        context.coordinator.lite.register(field)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    func updateUIView(_ uiView: LiteCardField, context: Context) {
        if uiView.chrome != chrome { uiView.chrome = chrome }
        if uiView.showsBrandAccessory != showsBrandAccessory { uiView.showsBrandAccessory = showsBrandAccessory }
        uiView.onChange = { state in
            DispatchQueue.main.async { onChange?(state) }
        }
        uiView.onShowsInvalidChange = { showsInvalid in
            DispatchQueue.main.async { onShowsInvalid?(showsInvalid) }
        }
    }

    static func dismantleUIView(_ uiView: LiteCardField, coordinator: Coordinator) {
        // Clear without notifying SwiftUI parents during teardown; aggregator unregister is deferred.
        uiView.onChange = nil
        uiView.onShowsInvalidChange = nil
        uiView.onStateChange = nil
        uiView.clear()
        coordinator.lite.unregister(uiView)
    }
}
#endif
