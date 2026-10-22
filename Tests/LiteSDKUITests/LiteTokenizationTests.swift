#if canImport(UIKit)
import XCTest
import Security
import SwiftUI
@testable import LiteSDKUI
@testable import LiteSDKCrypto
@testable import LiteSDKCore
import LiteSDKTestSupport

/// `Lite` on a tokenization session: start, the pay refusals, the pay UI refusal and `tokenize()`.
/// `Lite` talks through `URLSession.shared`, so the stub is registered process-wide.
@MainActor
final class LiteTokenizationTests: XCTestCase {

    private static let sessionURL = "https://dev.lite.sa/api/v1/checkout/sessions/sess_tok"
    private static let tokenizeURL = "https://dev.lite.sa/api/v1/checkout/instruments"
    private static let instrumentResponse = """
    {"id":"inst_tok","type":"card","payment_method":"card","holder_id":"cust_8f3a91","holder_type":"CUSTOMER","card":{"scheme":"visa","last4":"1111","expiry_month":"12","expiry_year":"2030","bin":"411111","funding":null,"issuer":null,"issuer_country":null},"display":{"scheme":"VISA","last_4":"1111"}}
    """

    private var fields: [LiteCardField] = []

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
        URLProtocol.registerClass(HTTPStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(HTTPStub.self)
        fields = []
        super.tearDown()
    }

    // MARK: Start

    func testStartSkipsPaymentStatusOnTokenizationSession() async throws {
        // `completed` would GET `_links.payment` on a payment session; a tokenization session has none.
        let lite = try await started(tokenizationSession(status: "completed"))
        XCTAssertEqual(lite.phase, .ready)
        XCTAssertNil(lite.lastPayResult)
        XCTAssertEqual(lite.session?.type, .tokenization)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    func testSessionWhoseCardCarriesNoStatusStartsAndTokenizes() async throws {
        // The live tokenization session sends the card method with only its key and stored cards.
        let lite = try await started(tokenizationSessionWithoutCardStatus())
        XCTAssertNotNil(lite.session?.paymentMethods.card)
        XCTAssertNil(lite.session?.paymentMethods.card?.status)
        try await fillCard(lite)
        HTTPStub.canned.append((201, Self.instrumentResponse))

        let result = await lite.tokenize()
        XCTAssertEqual(result.status, .success)
        XCTAssertNil(result.errorCode)
        XCTAssertEqual(result.instrument?.id, "inst_tok")
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL, Self.tokenizeURL])
    }

    func testTokenizationSessionOffersNoStoredInstrumentsOrApplePay() async throws {
        let lite = try await started(tokenizationSession())
        XCTAssertEqual(lite.getStoredInstruments(), [])
        XCTAssertFalse(lite.isApplePayEnabledInSession)
        XCTAssertFalse(lite.isApplePayAvailable)
    }

    // MARK: Paying is refused

    func testEveryPayPathIsRefusedBeforeAnythingIsSent() async throws {
        let lite = try await started(tokenizationSession())
        try await fillCard(lite)

        let refusals = [
            await lite.pay(),
            await lite.pay(storeForFuture: true),
            await lite.pay(instrumentId: "inst_1"),
        ]
        for result in refusals {
            XCTAssertEqual(result.status, .failure)
            XCTAssertEqual(result.errorCode, TokenizeErrorCode.sessionTypeUnsupported)
            XCTAssertNil(result.paymentId)
        }
        XCTAssertNil(lite.lastPayResult)
        XCTAssertEqual(lite.phase, .ready)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    func testApplePayIsRefusedBeforeTheTokenIsSent() async throws {
        let lite = try await started(tokenizationSession())
        var passKitSuccess: [Bool] = []
        let result = await lite.payWithApplePay(tokenJSON: #"{"paymentData":{}}"#) { success in
            passKitSuccess.append(success)
        }
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.sessionTypeUnsupported)
        XCTAssertEqual(passKitSuccess, [false])
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    func testPaymentUIIsRefusedOnlyOnTokenizationSession() async throws {
        let tokenization = try await started(tokenizationSession())
        XCTAssertEqual(tokenization.paymentUIRefusal?.status, .failure)
        XCTAssertEqual(tokenization.paymentUIRefusal?.errorCode, TokenizeErrorCode.sessionTypeUnsupported)

        let payment = try await started(paymentSession())
        XCTAssertNil(payment.paymentUIRefusal)
    }

    func testEmbeddedFormCompletesWithRefusal() async throws {
        HTTPStub.canned.append((200, tokenizationSession()))
        let lite = Lite()
        var results: [Lite.PayResult] = []
        let form = LitePaymentForm(lite: lite, clientSecret: try Self.token(), showResultInline: true) { result in
            results.append(result)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: form)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        try await waitUntil { !results.isEmpty }
        XCTAssertEqual(results, [Lite.sessionTypeUnsupportedResult])
        XCTAssertEqual(results.first?.errorCode, TokenizeErrorCode.sessionTypeUnsupported)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    func testPaymentSessionStillPays() async throws {
        let lite = try await started(paymentSession())
        try await fillCard(lite)
        HTTPStub.canned += [
            (201, #"{"id":"inst_pay","payment_method":"card"}"#),
            (200, #"{"payment":{"id":"pay_1","status":"CREATED"}}"#),
            (200, #"{"payment":{"id":"pay_1","status":"CAPTURED"}}"#),
            (200, paymentSession()),
        ]
        let result = await lite.pay()
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.paymentId, "pay_1")
        XCTAssertEqual(HTTPStub.requests.map(\.url), [
            Self.sessionURL,
            Self.tokenizeURL,
            "https://dev.lite.sa/api/v1/authorize",
            "https://dev.lite.sa/api/v1/payment",
            Self.sessionURL,
        ])
        XCTAssertEqual(HTTPStub.requests[1].json?["type"] as? String, "card")
    }

    func testPaymentSessionWithInactiveCardStillRefusesPay() async throws {
        let lite = try await started(paymentSession(cardStatus: "INACTIVE"))
        try await fillCard(lite)
        let result = await lite.pay()
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.error, LiteError.cardNotActive.customerSafeMessage)
        XCTAssertNil(result.paymentId)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    // MARK: Paying with an instrument id

    func testPaysAnInstrumentTheSessionDoesNotList() async throws {
        // A single-use card from tokenize() is not among the payment session's stored instruments.
        let lite = try await started(paymentSession())
        lite.selectStoredInstrument("inst_tok")
        XCTAssertEqual(lite.cardSelection, .storedInstrument(id: "inst_tok"))
        XCTAssertTrue(lite.isReadyToPay)
        HTTPStub.canned += [
            (200, #"{"payment":{"id":"pay_1","status":"CREATED"}}"#),
            (200, #"{"payment":{"id":"pay_1","status":"CAPTURED"}}"#),
            (200, paymentSession()),
        ]

        let result = await lite.pay()

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.paymentId, "pay_1")
        XCTAssertEqual(HTTPStub.requests[1].url, "https://dev.lite.sa/api/v1/authorize")
        XCTAssertEqual(
            (HTTPStub.requests[1].json?["payment_instrument"] as? [String: Any])?["id"] as? String,
            "inst_tok"
        )
    }

    func testRefusesAMotoSessionAtStart() async throws {
        let moto = paymentSession().replacingOccurrences(
            of: #""status": "pending","#,
            with: #""status": "pending", "processing_type": "MOTO","#
        )
        HTTPStub.canned.append((200, moto))
        let lite = Lite()
        await lite.start(clientSecret: try Self.token())

        XCTAssertEqual(lite.phase, .failed(LiteError.motoUnsupported.customerSafeMessage))
        XCTAssertNil(lite.session)
        try await fillCard(lite)
        let paid = await lite.pay()
        let paidWithInstrument = await lite.pay(instrumentId: "inst_tok")
        let tokenized = await lite.tokenize()
        XCTAssertEqual(paid.status, .failure)
        XCTAssertEqual(paidWithInstrument.status, .failure)
        XCTAssertEqual(tokenized.status, .failure)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    func testRefusesAListedCardWhoseSchemeIsOffBeforeAnythingIsSent() async throws {
        let lite = try await started(paymentSession(cardExtras: Self.storedVisaWithVisaOff))
        lite.selectStoredInstrument("inst_1")
        XCTAssertEqual(lite.cardSelection, .newCard)

        let result = await lite.pay(instrumentId: "inst_1")

        XCTAssertEqual(result.status, .failure)
        XCTAssertNil(result.paymentId)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    // MARK: tokenize

    func testTokenizeRefusedOnPaymentSession() async throws {
        let lite = try await started(paymentSession())
        try await fillCard(lite)
        let result = await lite.tokenize()
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.sessionTypeUnsupported)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    func testTokenizeWithIncompleteCardSendsNothing() async throws {
        let lite = try await started(tokenizationSession())
        let result = await lite.tokenize()
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.tokenizeFailed)
        XCTAssertEqual(result.error, LiteError.fieldsIncomplete([]).customerSafeMessage, "the same copy pay() gives")
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL])
    }

    func testTokenizeSavesOneCardPerSession() async throws {
        let lite = try await started(tokenizationSession())
        try await fillCard(lite)
        HTTPStub.canned.append((201, Self.instrumentResponse))

        let saved = await lite.tokenize(storeForFuture: true)
        XCTAssertEqual(saved.status, .success)
        XCTAssertEqual(saved.instrument?.id, "inst_tok")
        XCTAssertEqual(saved.instrument?.card?.last4, "1111")
        XCTAssertNil(saved.instrument?.card?.funding)
        XCTAssertNil(lite.lastPayResult, "tokenizing is not a payment")

        // Only the tokenize POST: never authorize, never poll.
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL, Self.tokenizeURL])
        let body = try XCTUnwrap(HTTPStub.requests.last?.json)
        XCTAssertEqual(body["type"] as? String, "card")
        XCTAssertEqual(body["payment_method"] as? String, "card")
        XCTAssertEqual(body["holder_id"] as? String, "cust_8f3a91")
        XCTAssertEqual(body["future_usage"] as? String, "unscheduled")
        XCTAssertEqual((body["data"] as? String)?.split(separator: ".").count, 5, "a compact JWE")

        let again = await lite.tokenize()
        XCTAssertEqual(again.errorCode, TokenizeErrorCode.sessionConsumed)
        XCTAssertEqual(HTTPStub.requests.count, 2)
    }

    func testTokenizeSendsNothingWhileAReplacementSessionLoads() async throws {
        let lite = try await started(tokenizationSession())
        try await fillCard(lite)

        // Hold the replacement's session GET open, and tokenize while it loads.
        HTTPStub.delay = 0.5
        HTTPStub.canned.append((200, tokenizationSession()))
        let secret = try Self.token()
        let replacing = Task { await lite.start(clientSecret: secret) }
        try await waitUntil {
            if case .loadingSession = lite.phase { return true }
            return false
        }
        let result = await lite.tokenize()
        await replacing.value

        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.tokenizeFailed)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL, Self.sessionURL])
    }

    func testNewSessionCanTokenizeAgain() async throws {
        let lite = try await started(tokenizationSession())
        try await fillCard(lite)
        HTTPStub.canned.append((201, Self.instrumentResponse))
        let first = await lite.tokenize()
        XCTAssertEqual(first.status, .success)

        HTTPStub.canned.append((200, tokenizationSession()))
        await lite.start(clientSecret: try Self.token())
        HTTPStub.canned.append((201, Self.instrumentResponse))
        let second = await lite.tokenize()
        XCTAssertEqual(second.status, .success)
    }

    func testRefusedTokenizeCanBeRetried() async throws {
        let lite = try await started(tokenizationSession())
        try await fillCard(lite)
        HTTPStub.canned += [
            (422, #"{"errors":[{"code":"CARD_DECLINED"}]}"#),
            (201, Self.instrumentResponse),
        ]
        let refused = await lite.tokenize()
        XCTAssertEqual(refused.errorCode, TokenizeErrorCode.tokenizeFailed)
        XCTAssertEqual(refused.apiErrorCode, "CARD_DECLINED")

        let retried = await lite.tokenize()
        XCTAssertEqual(retried.status, .success)
    }

    func testDoubleTapSharesTheTokenizationInFlight() async throws {
        let lite = try await started(tokenizationSession())
        try await fillCard(lite)
        HTTPStub.canned.append((201, Self.instrumentResponse))
        HTTPStub.delay = 0.3

        async let first = lite.tokenize()
        async let second = lite.tokenize()
        let (a, b) = await (first, second)
        XCTAssertEqual(a.status, .success)
        XCTAssertEqual(a, b)
        XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.sessionURL, Self.tokenizeURL])
    }

    // MARK: Helpers

    private func started(_ sessionJSON: String) async throws -> Lite {
        HTTPStub.canned.append((200, sessionJSON))
        let lite = Lite()
        await lite.start(clientSecret: try Self.token())
        XCTAssertEqual(lite.phase, .ready)
        return lite
    }

    /// Fill the card fields the way a customer would, and wait for `Lite` to see them valid.
    private func fillCard(_ lite: Lite) async throws {
        let values: [CardElementType: String] = [.cardNumber: "4111111111111111", .expiry: "1230", .cvv: "123"]
        for (type, value) in values {
            let field = LiteCardField(type: type)
            XCTAssertTrue(lite.register(field))
            field.restore(value)
            fields.append(field)
        }
        for _ in 0..<100 where !lite.isComplete {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(lite.isComplete)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private static func token() throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sessionId": "sess_tok",
            "merchantId": "m",
            "iss": "https://dev.lite.sa",
        ])
        return "e30.\(base64url(payload)).sig"
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A base64-wrapped SPKI PEM, the session's `public_key` wire format.
    private static let publicKey: String = {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let pkcs1 = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        let pem = DER.pemFromDER(DER.spkiFromPKCS1([UInt8](pkcs1)), label: "PUBLIC KEY")
        return Data(pem.utf8).base64EncodedString()
    }()

    private func tokenizationSession(status: String = "OPEN") -> String {
        """
        {
          "id": "sess_tok", "type": "tokenization", "status": "\(status)",
          "customer": { "id": "cust_8f3a91" },
          "payment_methods": {
            "card": {
              "status": "ACTIVE",
              "networks": { "visa": true, "mastercard": true, "mada": true },
              "config": { "public_key": "\(Self.publicKey)" },
              "stored_instruments": [
                { "id": "inst_1", "payment_method": "card", "holder_type": "CUSTOMER",
                  "display": { "expiry_year": "30", "expiry_month": "12", "scheme": "visa", "last_4": "4242" } }
              ]
            },
            "apple_pay": {
              "status": "ACTIVE",
              "dependencies": { "merchant_identifier": "merchant.sa.lite" },
              "config": { "supportedNetworks": ["visa"] }
            }
          },
          "_links": {
            "self": { "href": "\(Self.sessionURL)", "method": "GET" },
            "tokenize": { "href": "\(Self.tokenizeURL)", "method": "POST" }
          }
        }
        """
    }

    private func tokenizationSessionWithoutCardStatus() -> String {
        """
        {
          "id": "sess_tok", "type": "tokenization", "status": "OPEN",
          "customer": { "id": "cust_8f3a91" },
          "payment_methods": {
            "card": {
              "config": { "public_key": "\(Self.publicKey)" },
              "stored_instruments": []
            }
          },
          "_links": {
            "self": { "href": "\(Self.sessionURL)", "method": "GET" },
            "tokenize": { "href": "\(Self.tokenizeURL)", "method": "POST" }
          }
        }
        """
    }

    private static let storedVisaWithVisaOff = """
    , "networks": { "visa": false, "mastercard": true, "mada": true },
    "stored_instruments": [
      { "id": "inst_1", "payment_method": "card", "holder_type": "CUSTOMER",
        "display": { "expiry_year": "30", "expiry_month": "12", "scheme": "visa", "last_4": "4242" } }
    ]
    """

    private func paymentSession(cardStatus: String = "ACTIVE", cardExtras: String = "") -> String {
        """
        {
          "id": "sess_tok", "status": "pending", "amount": 1050, "currency": "SAR",
          "customer": { "id": "cust_8f3a91" },
          "payment_methods": {
            "card": { "status": "\(cardStatus)", "config": { "public_key": "\(Self.publicKey)" }\(cardExtras) }
          },
          "_links": {
            "self": { "href": "\(Self.sessionURL)", "method": "GET" },
            "tokenize": { "href": "\(Self.tokenizeURL)", "method": "POST" },
            "authorize": { "href": "https://dev.lite.sa/api/v1/authorize", "method": "POST" },
            "payment": { "href": "https://dev.lite.sa/api/v1/payment", "method": "GET" }
          }
        }
        """
    }
}
#endif
