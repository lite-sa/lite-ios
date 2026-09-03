import Foundation

// MARK: - Requests
// Encoded with `.convertToSnakeCase`, so camelCase properties become snake_case JSON keys
// exactly matching the web request bodies (see `packages/sdk/src/session/index.ts`).

/// POST body for `createInstrument` (tokenize). Web:
/// `{ holder_id, payment_method, holder_type: 'CUSTOMER', data, future_usage? }`.
struct CreateInstrumentRequest: Encodable {
    let holderId: String
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
    struct CaptureOptions: Encodable { let captureMode: String }     // "INSTANT"
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

/// Response from `createInstrument`. Web `LiteInstrument = { id, paymentMethod }` (camelCase).
public struct LiteInstrument: Decodable, Sendable {
    public let id: String
    public let paymentMethod: String?
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
