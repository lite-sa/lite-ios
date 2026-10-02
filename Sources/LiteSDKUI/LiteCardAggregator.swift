#if canImport(UIKit)
import Foundation
import LiteSDKCore
import LiteSDKCrypto

/// In-process replacement for the web SDK's hidden "collect" iframe. **Internal** — merchants
/// never touch it; they interact only with `Lite`. Card fields register with the aggregator; at
/// pay time it reads their values, builds `CardData`, and produces the compact JWE via
/// `CardEncryptor`. Raw card values never leave this boundary — only the JWE does (DESIGN §5.2, §9).
final class LiteCardAggregator: ObservableObject {

    enum AggregatorError: Error, Equatable {
        case missingRequiredFields([CardElementType])
    }

    /// Fields required for a card payment. Cardholder name is collected but optional.
    static let requiredFields: [CardElementType] = [.cardNumber, .expiry, .cvv]

    /// Live per-field validity.
    @Published private(set) var validity: [CardElementType: Bool] = [:]

    /// Fired when the card-number **digits** change (used to unlock pay after
    /// `PAYMENT_METHOD_NOT_SUPPORTED`). Validity-only emits do not unlock.
    var onCardNumberEdited: (() -> Void)?

    private var fields: [CardElementType: Weak] = [:]
    private let owners = FieldOwnerTable()
    private var lastCardNumberRaw: String = ""
    /// Card text kept when a field leaves the window (full-screen 3DS) so a
    /// cancelled challenge can restore it. Cleared on permanent disposal and reset.
    private var retainedValues: [CardElementType: String] = [:]

    /// True when all required fields are currently valid.
    var isComplete: Bool {
        Self.requiredFields.allSatisfy { validity[$0] == true }
    }

    /// Detected brand from the live card-number field (`.unknown` when empty / unrecognized).
    var detectedCardBrand: CardType {
        fields[.cardNumber]?.value?.cardBrand ?? .unknown
    }

    /// Register a field. A second live field of the same type does not replace the first.
    @discardableResult
    func register(_ field: LiteCardField) -> Bool {
        guard owners.claim(field.type, owner: field) else { return false }
        if fields[field.type]?.value === field { return true }
        fields[field.type] = Weak(field)
        // Capture the field *type* (a value), never `field` itself: the closure is stored on
        // `field.onStateChange`, so capturing `field` would form a `field → closure → field`
        // retain cycle and leak every card field for the process lifetime.
        let type = field.type
        field.onStateChange = { [weak self] state in
            guard let self else { return }
            self.publishValidity(type, state.valid)
            if type == .cardNumber {
                let current = self.fields[.cardNumber]?.value?.rawValue ?? ""
                guard current != self.lastCardNumberRaw else { return }
                self.lastCardNumberRaw = current
                self.onCardNumberEdited?()
            }
        }
        // Defer — `makeUIView` runs inside a SwiftUI update; publishing here warns.
        publishValidity(type, field.isValid)
        return true
    }

    /// Move the keyboard to the next registered field. No-op when that field is not on screen.
    func focusField(after type: CardElementType) {
        let next: CardElementType?
        switch type {
        case .cardNumber:
            next = .expiry
        case .expiry:
            next = .cvv
        case .cvv:
            next = .cardholderName
        case .cardholderName:
            next = nil
        }
        guard let next else { return }
        let field = fields[next]?.value
        DispatchQueue.main.async {
            field?.focus()
        }
    }

    /// Remember [field]'s text before its display is wiped for a window detach.
    func retain(_ field: LiteCardField) {
        retainedValues[field.type] = field.rawValue
    }

    func dropRetained(_ type: CardElementType) {
        retainedValues.removeValue(forKey: type)
    }

    func retainedValue(for type: CardElementType) -> String {
        retainedValues[type] ?? ""
    }

    /// Remove a field when its view leaves the window or is dismantled.
    /// A window detach keeps the retained text and validity. Permanent disposal does not.
    func unregister(_ field: LiteCardField, keepingValue: Bool) {
        owners.release(field.type, owner: field)
        guard fields[field.type]?.value === field else { return }
        let type = field.type
        fields.removeValue(forKey: type)
        if keepingValue {
            return
        }
        retainedValues.removeValue(forKey: type)
        publishValidity(type, nil)
    }

    /// Clear all registered fields and reset validity — used when the SDK is reset.
    func reset() {
        lastCardNumberRaw = ""
        retainedValues.removeAll()
        for (_, weak) in fields {
            weak.value?.clear()
        }
        for type in fields.keys {
            publishValidity(type, false)
        }
    }

    /// Snapshot the current field values into `CardData` (expiry is split on `/` in the initializer).
    func collect() -> CardData {
        func value(_ type: CardElementType) -> String {
            if let live = fields[type]?.value {
                return live.rawValue
            }
            return retainedValues[type] ?? ""
        }
        return CardData(
            cardNumber: value(.cardNumber),
            expiry: value(.expiry),
            cvv: value(.cvv),
            cardholderName: value(.cardholderName)
        )
    }

    /// Collect + encrypt into the compact JWE using the session's base64-wrapped PEM public key.
    func encrypt(base64WrappedPEMPublicKey: String) throws -> String {
        let missing = Self.requiredFields.filter { validity[$0] != true }
        guard missing.isEmpty else { throw AggregatorError.missingRequiredFields(missing) }
        let dangling = Self.requiredFields.filter { type in
            if fields[type]?.value != nil {
                return false
            }
            let kept = retainedValues[type] ?? ""
            return kept.isEmpty
        }
        guard dangling.isEmpty else { throw AggregatorError.missingRequiredFields(dangling) }
        return try CardEncryptor.encrypt(collect(), base64WrappedPEMPublicKey: base64WrappedPEMPublicKey)
    }

    /// Always hop to the next main-queue turn so `@Published` never fires mid view-update.
    private func publishValidity(_ type: CardElementType, _ valid: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let valid {
                if self.validity[type] != valid {
                    self.validity[type] = valid
                }
            } else if self.validity[type] != nil {
                self.validity.removeValue(forKey: type)
            }
        }
    }

    private final class Weak {
        weak var value: LiteCardField?
        init(_ value: LiteCardField) { self.value = value }
    }
}
#endif
