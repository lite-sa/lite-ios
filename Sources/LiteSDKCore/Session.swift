import Foundation
import os

/// Native model of the `GET /api/v1/checkout/sessions/{id}` response.
/// Mirrors the web `LiteCheckoutSession` (see `packages/sdk/src/types/index.ts`). Snake_case JSON
/// keys are mapped to camelCase Swift properties. Fields the SDK doesn't yet consume (theme, full
/// order items) are omitted — `Decodable` ignores unknown keys.
public struct LiteCheckoutSession: Decodable, Sendable {
    public let id: String
    public let status: String
    public let amount: Int
    public let currency: String
    public let paymentMethods: PaymentMethodLookup
    public let links: SessionLinks

    public let expiresOn: String?
    public let channelId: String?
    public let orderId: String?
    public let customer: Customer?
    public let order: Order?
    public let product: Product?
    public let checkoutConfig: CheckoutConfig?

    enum CodingKeys: String, CodingKey {
        case id, status, amount, currency, customer, order, product
        case paymentMethods = "payment_methods"
        case links = "_links"
        case expiresOn = "expires_on"
        case channelId = "channel_id"
        case orderId = "order_id"
        case checkoutConfig = "checkout_config"
    }

    /// The RSA public key (base64-wrapped PEM) used to encrypt card data, when card is configured.
    /// Package-scoped so merchants cannot read it via `lite.session` (IOS-018).
    package var cardPublicKey: String? { paymentMethods.card?.config?.publicKey }

    public struct Product: Decodable, Sendable {
        public let name: String
        public let image: String?
    }

    public struct CheckoutConfig: Decodable, Sendable {
        public let locale: String?
        public let redirectUrls: RedirectUrls?
        enum CodingKeys: String, CodingKey {
            case locale
            case redirectUrls = "redirect_urls"
        }
        public struct RedirectUrls: Decodable, Sendable {
            public let success: String?
            public let failure: String?
        }
    }
}

/// HATEOAS links returned with the session. All pay-flow requests use these hrefs (never hardcode).
public struct SessionLinks: Decodable, Sendable {
    /// Optional — native Apple Pay does not call this; card-only sessions may omit it (IOS-014).
    public let startPaymentSession: Link?
    public let tokenize: Link
    public let authorize: Link
    public let selfLink: Link
    public let payment: Link
    enum CodingKeys: String, CodingKey {
        case startPaymentSession = "start_payment_session"
        case tokenize, authorize, payment
        case selfLink = "self"
    }
}

public struct Link: Decodable, Sendable {
    public let href: String
    public let method: String
}

public struct Customer: Decodable, Sendable {
    public let id: String
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let phoneNumber: String?
    public let phoneCountryCode: String?
    public let billingAddress: Address?
    enum CodingKeys: String, CodingKey {
        case id, email
        case firstName = "first_name"
        case lastName = "last_name"
        case phoneNumber = "phone_number"
        case phoneCountryCode = "phone_country_code"
        case billingAddress = "billing_address"
    }
    public struct Address: Decodable, Sendable {
        public let line1: String?
        public let line2: String?
        public let city: String?
        public let state: String?
        public let postalCode: String?
        public let country: String?
        enum CodingKeys: String, CodingKey {
            case line1, line2, city, state, country
            case postalCode = "postal_code"
        }
    }
}

public struct Order: Decodable, Sendable {
    public let reference: String?
    public let amount: Int?
    public let currency: String?
    public let description: String?
    public let billingAddress: OrderAddress?
    enum CodingKeys: String, CodingKey {
        case reference, amount, currency, description
        case billingAddress = "billing_address"
    }
    public struct OrderAddress: Decodable, Sendable {
        public let name: String?
        public let email: String?
        public let street: String?
        public let city: String?
        public let state: String?
        public let zip: String?
        public let country: String?
    }
}

public enum MethodStatus: String, Decodable, Sendable {
    case active = "ACTIVE"
    case inactive = "INACTIVE"
}

/// Per-payment-method config from the session.
///
/// Runtime wire key for Apple Pay is **`apple_pay`** — that is what hosted checkout and the web
/// `ApplePayButton` look up (`usePaymentMethodStatus('apple_pay')`,
/// `paymentMethodConfig('apple_pay')`). The TypeScript `PaymentMethod.APPLE_PAY = 'applePay'`
/// enum value does not match the live session payload (known web camelCase/snake_case split).
public struct PaymentMethodLookup: Decodable, Sendable {
    public let card: CardMethod?
    public let applePay: ApplePayMethod?

    enum CodingKeys: String, CodingKey {
        case card
        case applePayWire = "apple_pay"
        case applePayCamel = "applePay"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Soft-decode card like Apple Pay so an INACTIVE / partial object cannot fail the session
        // (IOS-015). Missing key → cardNotConfigured at pay time.
        card = Self.softDecode(CardMethod.self, from: container, key: .card)
        applePay =
            Self.softDecode(ApplePayMethod.self, from: container, key: .applePayWire)
            ?? Self.softDecode(ApplePayMethod.self, from: container, key: .applePayCamel)
    }

    private static let sessionLog = Logger(subsystem: "sa.lite.checkout", category: "session")

    private static func softDecode<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> T? {
        guard container.contains(key) else { return nil }
        if (try? container.decodeNil(forKey: key)) == true { return nil }
        do {
            return try container.decode(T.self, forKey: key)
        } catch {
            sessionLog.error("Failed to decode payment_methods.\(key.stringValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public struct CardMethod: Decodable, Sendable {
        public let status: MethodStatus
        public let config: Config?
        /// Optional scheme gate: `{ visa, mastercard, mada }` booleans (web `networks`).
        public let networks: CardNetworks?
        public let storedInstruments: [StoredInstrument]?
        enum CodingKeys: String, CodingKey {
            case status, config, networks
            case storedInstruments = "stored_instruments"
        }
        public struct Config: Decodable, Sendable {
            public let publicKey: String
            enum CodingKeys: String, CodingKey { case publicKey = "public_key" }
        }
    }

    /// Shape used when Apple Pay is fully configured (ACTIVE). Matches web
    /// `PaymentMethodLookup[PaymentMethod.APPLE_PAY]` field names under the `apple_pay` session key.
    public struct ApplePayMethod: Decodable, Sendable {
        public let status: MethodStatus
        public let dependencies: Dependencies?
        public let config: Config?

        public struct Dependencies: Decodable, Sendable {
            public let merchantIdentifier: String
            public let merchantIdentifierHash: String?
            enum CodingKeys: String, CodingKey {
                case merchantIdentifier = "merchant_identifier"
                case merchantIdentifierHash = "_merchant_identifier"
            }
        }

        public struct Config: Decodable, Sendable {
            public let countryCode: String?
            public let merchantCapabilities: [String]?
            public let supportedNetworks: [String]?
            public let version: Int?
        }
    }
}

public struct StoredInstrument: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let paymentMethod: String
    public let holderType: String
    public let display: Display
    /// Set by `Lite.getStoredInstruments` from `card.networks` (not on the wire).
    public var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, display
        case paymentMethod = "payment_method"
        case holderType = "holder_type"
    }

    public init(
        id: String,
        paymentMethod: String,
        holderType: String,
        display: Display,
        enabled: Bool = true
    ) {
        self.id = id
        self.paymentMethod = paymentMethod
        self.holderType = holderType
        self.display = display
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        paymentMethod = try container.decode(String.self, forKey: .paymentMethod)
        holderType = try container.decode(String.self, forKey: .holderType)
        display = try container.decode(Display.self, forKey: .display)
        enabled = false
    }

    public struct Display: Decodable, Sendable, Equatable {
        public let expiryYear: String
        public let expiryMonth: String
        public let scheme: String
        public let last4: String
        enum CodingKeys: String, CodingKey {
            case scheme
            case expiryYear = "expiry_year"
            case expiryMonth = "expiry_month"
            case last4 = "last_4"
        }
    }
}
