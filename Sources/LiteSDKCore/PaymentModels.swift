import Foundation

// MARK: - Requests
// Encoded with `.convertToSnakeCase`, so camelCase properties become snake_case JSON keys
// exactly matching the web request bodies (see `packages/sdk/src/session/index.ts`).

/// POST body for `createInstrument` (tokenize). Web:
/// `{ holder_id, type, payment_method, holder_type: 'CUSTOMER', data, future_usage? }`.
/// `type` is lower snake_case (`apple_pay`); `payment_method` is deprecated and keeps the old
/// camelCase (`applePay`).
struct CreateInstrumentRequest: Encodable {
    let holderId: String
    let type: String
    let paymentMethod: String
    let holderType: String
    let data: String
    let futureUsage: String?
}

/// POST body for `authorize` (pay). Mirrors the web `LitePaymentRequest`.
struct LitePaymentRequest: Encodable {
    let amount: Int
    let currency: String
    let processing: Processing
    let order: OrderBody
    let captureOptions: CaptureOptions
    let paymentInstrument: InstrumentRef
    let customer: CustomerBody
    let channelId: String?
    let device: Device

    struct Processing: Encodable { let processingType: String }      // "REGULAR"
    struct CaptureOptions: Encodable { let captureMode: String }     // session.capture_mode, "INSTANT" when absent or unknown
    struct InstrumentRef: Encodable { let id: String }

    struct OrderBody: Encodable {
        let reference: String
        let amount: Int?
        let currency: String?
        let description: String?
        let billingAddress: BillingAddress?
    }

    struct BillingAddress: Encodable {
        let name: String?
        let email: String?
        let street: String?
        let city: String?
        let state: String?
        let country: String?
        let zip: String?
    }

    struct CustomerBody: Encodable {
        let id: String
        let email: String?
        let firstName: String?
        let lastName: String?
        let phoneCountryCode: String?
        let phoneNumber: String?
    }
}

/// Device / browser-info block sent with the authorize request. The web collects a *browser*
/// fingerprint (canvas/webgl/etc.); natively those signals don't exist, so the SDK sends the
/// closest native-derived values (DESIGN §5.8 / open decision #1 — the backend may accept a
/// different native shape later).
public struct Device: Encodable, Sendable {
    public var ip: String?
    public var userAgent: String
    public var acceptHeader: String
    public var language: String
    public var screenHeight: Int
    public var screenWidth: Int
    public var colorDepth: Int
    public var timezone: Int
    public var javaEnabled: Bool
    public var javaScriptEnabled: Bool
    public var deviceFingerprint: String?
    /// Web always sends `device_data` (at least `{}`) — wire parity (IOS-021).
    public var deviceData: [String: String]

    public init(
        ip: String? = nil,
        userAgent: String,
        acceptHeader: String,
        language: String,
        screenHeight: Int,
        screenWidth: Int,
        colorDepth: Int,
        timezone: Int,
        javaEnabled: Bool,
        javaScriptEnabled: Bool,
        deviceFingerprint: String? = nil,
        deviceData: [String: String] = [:]
    ) {
        self.ip = ip
        self.userAgent = userAgent
        self.acceptHeader = acceptHeader
        self.language = language
        self.screenHeight = screenHeight
        self.screenWidth = screenWidth
        self.colorDepth = colorDepth
        self.timezone = timezone
        self.javaEnabled = javaEnabled
        self.javaScriptEnabled = javaScriptEnabled
        self.deviceFingerprint = deviceFingerprint
        self.deviceData = deviceData
    }
}

// MARK: - Responses
// Decoded with explicit CodingKeys (handles `_links`, `next_action`, `merchant_reference`).

/// Response from `createInstrument` as the API sends it (web `CreatedInstrument`). Internal: it also
/// carries the deprecated `display` and `metadata`, which can hold the cardholder name, so it is
/// decoded without them and handed on only as a `LiteInstrument`.
struct CreatedInstrument: Decodable {
    let id: String
    let type: InstrumentType?
    let paymentMethod: String?
    /// Legacy camelCase form of `payment_method`.
    let paymentMethodCamel: String?
    let createdAt: String?
    let merchantId: String?
    let holderId: String?
    let holderType: String?
    let futureUsage: String?
    let card: LiteInstrumentCard?

    enum CodingKeys: String, CodingKey {
        case id, type, card
        case paymentMethod = "payment_method"
        case paymentMethodCamel = "paymentMethod"
        case createdAt = "created_at"
        case merchantId = "merchant_id"
        case holderId = "holder_id"
        case holderType = "holder_type"
        case futureUsage = "future_usage"
    }

    /// Only `id` is required. By the time this decodes the instrument exists, so a field of an
    /// unexpected shape is dropped rather than failing a tokenization that succeeded.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try? container.decodeIfPresent(InstrumentType.self, forKey: .type)
        paymentMethod = try? container.decodeIfPresent(String.self, forKey: .paymentMethod)
        paymentMethodCamel = try? container.decodeIfPresent(String.self, forKey: .paymentMethodCamel)
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        merchantId = try? container.decodeIfPresent(String.self, forKey: .merchantId)
        holderId = try? container.decodeIfPresent(String.self, forKey: .holderId)
        holderType = try? container.decodeIfPresent(String.self, forKey: .holderType)
        futureUsage = try? container.decodeIfPresent(String.self, forKey: .futureUsage)
        card = try? container.decodeIfPresent(LiteInstrumentCard.self, forKey: .card)
    }
}

/// A tokenized instrument, as the API's create response describes it (web `LiteInstrument`). Show
/// the customer what it is from this, but re-fetch it from your server before acting on its card
/// details: it passed through the customer's device on the way to you.
///
/// If the customer already has this card stored, the API answers with that instrument, so
/// `futureUsage` can be set even when `storeForFuture` was off.
public struct LiteInstrument: Sendable, Equatable {
    public let id: String
    public let type: InstrumentType
    public let createdAt: String?
    public let merchantId: String?
    /// The session's customer.
    public let holderId: String?
    public let holderType: String?
    /// Set for an instrument kept for later payments (e.g. `unscheduled_card_on_file`); nil when single use.
    public let futureUsage: String?
    /// The card and its BIN details. Nil for instruments that aren't card-backed, and from
    /// deployments that predate it.
    public let card: LiteInstrumentCard?
    /// The deprecated `payment_method` as the API sent it, e.g. `"card"`; nil when it sent none.
    /// Kept so a minor upgrade doesn't break integrators. Removed in the next major.
    @available(*, deprecated, message: "Use type.")
    public var paymentMethod: String? { legacyPaymentMethod }
    private let legacyPaymentMethod: String?

    public init(
        id: String,
        type: InstrumentType,
        createdAt: String? = nil,
        merchantId: String? = nil,
        holderId: String? = nil,
        holderType: String? = nil,
        futureUsage: String? = nil,
        card: LiteInstrumentCard? = nil,
        paymentMethod: String? = nil
    ) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.merchantId = merchantId
        self.holderId = holderId
        self.holderType = holderType
        self.futureUsage = futureUsage
        self.card = card
        self.legacyPaymentMethod = paymentMethod
    }

    /// The create response as the public instrument (web `toLiteInstrument`). Built field by field,
    /// so `display` and `metadata` stay out. Without `type`, it comes from `payment_method`, then
    /// from the method that was tokenized.
    init(_ created: CreatedInstrument, tokenized method: PaymentMethod) {
        let legacyMethod = created.paymentMethod ?? created.paymentMethodCamel
        let type: InstrumentType
        if let wireType = created.type {
            type = wireType
        } else if let legacyMethod {
            type = InstrumentType(wire: legacyMethod)
        } else {
            type = method.instrumentType
        }
        self.init(
            id: created.id,
            type: type,
            createdAt: created.createdAt,
            merchantId: created.merchantId,
            holderId: created.holderId,
            holderType: created.holderType,
            futureUsage: created.futureUsage,
            card: created.card,
            paymentMethod: legacyMethod
        )
    }
}

/// The real card behind an instrument (web `LiteInstrumentCard`). Any field the API doesn't know
/// is nil, never an empty string.
public struct LiteInstrumentCard: Decodable, Sendable, Equatable {
    /// Lowercase scheme: `mada`, `visa`, `mastercard`, `amex`, `discover`, `jcb`, `upi`, `gccnet`,
    /// `maestro`. A string, so a scheme added later still decodes.
    public let scheme: String?
    /// The last 4 digits printed on the card.
    public let last4: String?
    /// Two digits, zero-padded: `"01"`–`"12"`.
    public let expiryMonth: String?
    /// Four digits, e.g. `"2028"`.
    public let expiryYear: String?
    /// 6 or 8 digits.
    public let bin: String?
    /// `credit`, `debit`, `prepaid` or `charge`.
    public let funding: String?
    /// The issuing bank's name.
    public let issuer: String?
    /// ISO 3166-1 alpha-2, e.g. `SA`.
    public let issuerCountry: String?

    enum CodingKeys: String, CodingKey {
        case scheme, last4, bin, funding, issuer
        case expiryMonth = "expiry_month"
        case expiryYear = "expiry_year"
        case issuerCountry = "issuer_country"
    }

    public init(
        scheme: String? = nil,
        last4: String? = nil,
        expiryMonth: String? = nil,
        expiryYear: String? = nil,
        bin: String? = nil,
        funding: String? = nil,
        issuer: String? = nil,
        issuerCountry: String? = nil
    ) {
        self.scheme = scheme
        self.last4 = last4
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.bin = bin
        self.funding = funding
        self.issuer = issuer
        self.issuerCountry = issuerCountry
    }
}

/// Response from `authorize` and `pollPayment`. Mirrors the web `PaymentResponse`.
public struct PaymentResponse: Decodable, Sendable {
    public let payment: Payment
    public let nextAction: NextAction?

    enum CodingKeys: String, CodingKey {
        case payment
        case nextAction = "next_action"
    }

    public struct Payment: Decodable, Sendable {
        public let id: String
        public let status: PaymentStatus
        public let merchantReference: String?
        enum CodingKeys: String, CodingKey {
            case id, status
            case merchantReference = "merchant_reference"
        }
    }

    public struct NextAction: Decodable, Sendable {
        public let redirect: Redirect?
    }

    public struct Redirect: Decodable, Sendable {
        public let method: String
        public let url: String
    }
}

/// Result of a poll cycle (web `PaymentPollingResult`): the mapped operation status, the raw
/// payment response (for `next_action`), and an optional error message.
public struct PaymentPollingResult: Sendable {
    public let status: PaymentOperationStatus
    public let payment: PaymentResponse?
    public let error: String?

    public init(status: PaymentOperationStatus, payment: PaymentResponse? = nil, error: String? = nil) {
        self.status = status
        self.payment = payment
        self.error = error
    }
}
