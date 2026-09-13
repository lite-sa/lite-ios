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
    private var lastCardNumberRaw: String = ""

    /// True when all required fields are currently valid.
    var isComplete: Bool {
        Self.requiredFields.allSatisfy { validity[$0] == true }
    }

    /// Detected brand from the live card-number field (`.unknown` when empty / unrecognized).
    var detectedCardBrand: CardType {
        fields[.cardNumber]?.value?.cardBrand ?? .unknown
    }

    /// Register a field.
    func register(_ field: LiteCardField) {
        if let existing = fields[field.type]?.value, existing !== field {
            #if DEBUG
            assertionFailure(
                "LiteCardAggregator: replacing live \(field.type) field — only one field per type per Lite instance (IOS-016)."
            )
            #endif
        }
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
    }

    /// Remove a field when its view is dismantled (e.g. navigating away from the payment screen).
    func unregister(_ field: LiteCardField) {
        guard fields[field.type]?.value === field else { return }
        let type = field.type
        fields.removeValue(forKey: type)
        publishValidity(type, nil)
    }

    /// Clear all registered fields and reset validity — used when the SDK is reset.
    func reset() {
        lastCardNumberRaw = ""
        for (_, weak) in fields {
            weak.value?.clear()
        }
        for type in fields.keys {
            publishValidity(type, false)
        }
    }

    /// Snapshot the current field values into `CardData` (expiry is split on `/` in the initializer).
    func collect() -> CardData {
        func value(_ type: CardElementType) -> String { fields[type]?.value?.rawValue ?? "" }
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
        let dangling = Self.requiredFields.filter { fields[$0]?.value == nil }
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
