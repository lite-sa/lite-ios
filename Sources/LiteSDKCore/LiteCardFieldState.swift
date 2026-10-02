import Foundation

/// Why a card field is showing an error. Empty fields are incomplete (`valid == false`) and have no error.
public enum LiteFieldError: String, Sendable, Equatable {
    case invalidNumber
    case invalidExpiry
    case invalidCvv
}

/// Merchant callback for an individual card field.
///
/// Never includes the typed value, its length, or the last four digits.
public struct LiteCardFieldChange: Sendable, Equatable {
    public let valid: Bool
    public let brand: CardType
    public let error: LiteFieldError?
    /// Validation text for [error]. Nil when the field has no error.
    /// The field does not draw this; the host can.
    public let message: String?
    public let focused: Bool

    public init(
        valid: Bool,
        brand: CardType,
        error: LiteFieldError?,
        focused: Bool,
        message: String? = nil
    ) {
        self.valid = valid
        self.brand = brand
        self.error = error
        self.focused = focused
        if let message {
            self.message = message
        } else if let error {
            self.message = LiteFieldCopy.message(for: error)
        } else {
            self.message = nil
        }
    }
}

/// One live field per type. A second owner does not replace the first.
package final class FieldOwnerTable {
    package init() {}

    private var owners: [CardElementType: ObjectIdentifier] = [:]

    package func claim(_ type: CardElementType, owner: AnyObject) -> Bool {
        let id = ObjectIdentifier(owner)
        if let existing = owners[type] {
            return existing == id
        }
        owners[type] = id
        return true
    }

    package func release(_ type: CardElementType, owner: AnyObject) {
        if owners[type] == ObjectIdentifier(owner) {
            owners.removeValue(forKey: type)
        }
    }
}

package enum LiteCardFieldState {
    package static func resolve(
        type: CardElementType,
        isEmpty: Bool,
        formatValid: Bool,
        brand: CardType,
        focused: Bool
    ) -> LiteCardFieldChange {
        // A disabled scheme is not a field error. Authorize rejects it
        // (`PAYMENT_METHOD_NOT_SUPPORTED`), matching the JS card field.
        let valid: Bool
        if type == .cardholderName {
            valid = true
        } else {
            valid = formatValid
        }

        let error: LiteFieldError?
        if type == .cardholderName || isEmpty || valid {
            error = nil
        } else {
            switch type {
            case .cardNumber:
                error = .invalidNumber
            case .expiry:
                error = .invalidExpiry
            case .cvv:
                error = .invalidCvv
            case .cardholderName:
                error = nil
            }
        }

        let reportedBrand: CardType = type == .cardNumber ? brand : .unknown
        let message: String?
        if let error {
            message = LiteFieldCopy.message(for: error)
        } else {
            message = nil
        }
        return LiteCardFieldChange(
            valid: valid,
            brand: reportedBrand,
            error: error,
            focused: focused,
            message: message
        )
    }
}

/// Copy and cut are refused for the PAN and CVV. Paste stays allowed.
package enum LiteFieldClipboard {
    package static func allowsCopyOrCut(_ type: CardElementType) -> Bool {
        switch type {
        case .cardNumber, .cvv:
            return false
        case .expiry, .cardholderName:
            return true
        }
    }
}

/// English labels, placeholders, and errors. The announced value is the brand or the error, never the PAN.
package enum LiteFieldCopy {
    package static func label(for type: CardElementType) -> String {
        switch type {
        case .cardNumber:
            return "Card number"
        case .expiry:
            return "Expiration"
        case .cvv:
            return "CVV security code"
        case .cardholderName:
            return "Cardholder Name"
        }
    }

    /// Visible placeholder. Matches the JS field placeholders. Not a length limit.
    package static func placeholder(for type: CardElementType) -> String {
        switch type {
        case .cardNumber:
            return "1234 1234 1234 1234 123"
        case .expiry:
            return "MM/YY"
        case .cvv:
            return "CVV"
        case .cardholderName:
            return "Name on card"
        }
    }

    package static func message(for error: LiteFieldError) -> String {
        switch error {
        case .invalidNumber:
            return "Incorrect card number"
        case .invalidExpiry:
            return "Incorrect expiry date"
        case .invalidCvv:
            return "Incorrect CVV"
        }
    }

    /// VoiceOver value. Does not take the typed text, so it cannot echo the PAN.
    package static func accessibilityValue(brand: CardType, error: LiteFieldError?) -> String {
        if let error {
            return message(for: error)
        }
        return brand.displayName
    }
}
