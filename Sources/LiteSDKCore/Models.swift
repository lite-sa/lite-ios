import Foundation

// MARK: - Card brand

/// Mirrors the web SDK `CardType` union: only these four brands exist.
/// (No Amex/Discover/JCB/Diners — see DESIGN §5.3.)
public enum CardType: String, Equatable, Sendable, CaseIterable {
    case visa
    case mastercard
    case mada
    case unknown

    /// Matches web `getCardTypeName` (empty for `.unknown`).
    public var displayName: String {
        switch self {
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case .mada: return "Mada"
        case .unknown: return ""
        }
    }

    /// Asset name in `CardBrands.xcassets` (nil for `.unknown`).
    public var iconAssetName: String? {
        switch self {
        case .visa: return "card-brand-visa"
        case .mastercard: return "card-brand-mastercard"
        case .mada: return "card-brand-mada"
        case .unknown: return nil
        }
    }

    /// Maps a stored-instrument `display.scheme` to a brand (web `StoredCard` icon lookup).
    public static func from(scheme: String) -> CardType {
        CardNetwork.from(scheme: scheme)?.cardType ?? .unknown
    }
}

/// Schemes gated by `payment_methods.card.networks` (web `CardNetwork`).
public enum CardNetwork: String, Equatable, Sendable, CaseIterable {
    case visa
    case mastercard
    case mada

    public var cardType: CardType {
        switch self {
        case .visa: return .visa
        case .mastercard: return .mastercard
        case .mada: return .mada
        }
    }

    public static func from(scheme: String?) -> CardNetwork? {
        guard let scheme else { return nil }
        switch scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "visa": return .visa
        case "mastercard", "master_card": return .mastercard
        case "mada": return .mada
        default: return nil
        }
    }
}

/// `payment_methods.card.networks` — when omitted, every known scheme is enabled.
public struct CardNetworks: Decodable, Sendable, Equatable {
    public let visa: Bool?
    public let mastercard: Bool?
    public let mada: Bool?

    public init(visa: Bool? = nil, mastercard: Bool? = nil, mada: Bool? = nil) {
        self.visa = visa
        self.mastercard = mastercard
        self.mada = mada
    }

    /// Web `getEnabledCardNetworks`: missing map → all; else only keys explicitly `true`.
    public static func enabledNetworks(in networks: CardNetworks?) -> [CardNetwork] {
        let all = CardNetwork.allCases
        guard let networks else { return all }
        return all.filter { networks.isExplicitlyEnabled($0) }
    }

    /// Web `isCardSchemeEnabled`: missing map → true; unknown/empty scheme → false; else key === true.
    public static func isSchemeEnabled(_ scheme: String?, networks: CardNetworks?) -> Bool {
        guard let networks else { return true }
        guard let network = CardNetwork.from(scheme: scheme) else { return false }
        return networks.isExplicitlyEnabled(network)
    }

    private func isExplicitlyEnabled(_ network: CardNetwork) -> Bool {
        switch network {
        case .visa: return visa == true
        case .mastercard: return mastercard == true
        case .mada: return mada == true
        }
    }
}

// MARK: - Element types

/// The four card field types. Wallets (Apple Pay) are modeled separately.
public enum CardElementType: String, Sendable, CaseIterable {
    case cardholderName
    case cardNumber
    case expiry
    case cvv
}

// MARK: - Payment method

/// Canonical payment-method identifier sent as `payment_method` on tokenize (`card`, `applePay`).
///
/// The web SDK also has an `elements.create()` token (`apple_pay`). Native does not expose that
/// API; these cases are the wire/config values used by `createInstrument`.
public enum PaymentMethod: String, Sendable {
    case card
    case applePay
}

// MARK: - Backend payment status

/// Backend `payment.status` values (string == key), from the web SDK `PaymentStatus`.
public enum PaymentStatus: String, Sendable, Decodable {
    case created = "CREATED"
    case pending = "PENDING"
    case requiresAction = "REQUIRES_ACTION"
    case authorized = "AUTHORIZED"
    case captured = "CAPTURED"
    case partiallyCaptured = "PARTIALLY_CAPTURED"
    case failed = "FAILED"
    case voided = "VOIDED"
    case partiallyRefunded = "PARTIALLY_REFUNDED"
    case refunded = "REFUNDED"
    case rejected = "REJECTED"
    /// Unrecognized wire value — terminal failure, never treated as pending (Android `UNKNOWN`).
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaymentStatus(rawValue: raw) ?? .unknown
    }

    /// Statuses that terminate polling.
    /// Includes `REJECTED` (web `FINAL_STATUSES` omits it — DESIGN §10 #3 / IOS-004)
    /// and `UNKNOWN` so a novel status cannot keep the poller running.
    public static let finalStatuses: Set<PaymentStatus> = [
        .authorized, .failed, .voided, .captured, .rejected, .unknown,
    ]

    public static let unknownStatusMessage =
        "Something went wrong confirming this payment. Please try again."

    /// Maps a backend status to the merchant-facing operation status
    /// (web `LiteSession.operationStatus`).
    public var operationStatus: PaymentOperationStatus {
        switch self {
        case .captured, .authorized: return .success
        case .failed, .voided, .rejected, .unknown: return .failure
        default: return .processing
        }
    }
}

// MARK: - Operation status (merchant-facing)

/// Status merchants branch on for `pay()` / sheet results.
/// The web SDK has a dead, misspelled `PEDNING='pending'` member — intentionally omitted
/// (DESIGN §10 #1). `cancelled` is a native sheet/user-abort status (IOS-013).
public enum PaymentOperationStatus: String, Sendable, Equatable {
    case success
    case failure
    case processing
    case cancelled
}

// MARK: - Checkout session status

/// Checkout session `status` (not payment status). Unknown / legacy values (e.g. `ACTIVE`) behave as pending.
public enum CheckoutSessionStatus: Sendable, Equatable {
    case pending
    case completed
    case failed

    public static let alreadyCompletedMessage = "Payment already completed"
    public static let sessionFailedMessage = "Payment could not be completed"

    public static func fromWire(_ value: String?) -> CheckoutSessionStatus {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "COMPLETED", "COMPLETE": return .completed
        case "FAILED", "FAILURE": return .failed
        default: return .pending
        }
    }

    public static func isTerminal(_ value: String?) -> Bool {
        fromWire(value) != .pending
    }
}

// MARK: - Field state

/// Payload of the field `change` event — a single boolean, matching web `FieldState`.
public struct FieldState: Sendable, Equatable {
    public let valid: Bool
    public init(valid: Bool) { self.valid = valid }
}
