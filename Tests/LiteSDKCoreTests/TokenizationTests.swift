import XCTest
@testable import LiteSDKCore
import LiteSDKTestSupport

@MainActor
final class TokenizationTests: XCTestCase {

    /// The HOM-3116 create response, with the deprecated `display` and a `metadata` holding the
    /// cardholder name, neither of which may reach the merchant.
    private static let contractResponse = """
    {"id":"550e8400-e29b-41d4-a716-446655440000","created_at":"2026-10-18T10:00:00Z","merchant_id":"merch_123","holder_id":"holder_123","type":"card","payment_method":"card","holder_type":"CUSTOMER","future_usage":"unscheduled_card_on_file","card":{"scheme":"mada","last4":"1234","expiry_month":"03","expiry_year":"2028","bin":"45717360","funding":"debit","issuer":"Saudi National Bank","issuer_country":"SA"},"display":{"scheme":"MADA","last_4":"1234"},"metadata":{"cardholderName":"x"}}
    """

    private static let tokenizeHref = "https://dev.lite.sa/api/v1/checkout/instruments"

    private var encryptCalls = 0

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
        encryptCalls = 0
    }

    // MARK: Refusals

    func testRefusesOnPaymentSession() async throws {
        let result = await tokenize(TokenizeCoordinator(), started: try started(type: nil))
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.sessionTypeUnsupported)
        XCTAssertNil(result.instrument)
        XCTAssertEqual(encryptCalls, 0)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testRefusesWithoutPublicKey() async throws {
        let cards = [
            #"{ "status": "ACTIVE" }"#,
            #"{ "stored_instruments": [] }"#,
            #"{ "status": "ACTIVE", "config": { "public_key": "" } }"#,
            #"{ "config": { "public_key": "" }, "stored_instruments": [] }"#,
        ]
        for card in cards {
            encryptCalls = 0
            let result = await tokenize(TokenizeCoordinator(), started: try started(card: card))
            XCTAssertEqual(result.errorCode, TokenizeErrorCode.cardNotConfigured, card)
            XCTAssertEqual(result.error, "This session has no key to encrypt a card with.", card)
            XCTAssertEqual(encryptCalls, 0, card)
        }
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testTokenizesWithoutACardStatusOrWhenActive() async throws {
        // The live session sends the card without a status; a missing status doesn't switch cards off.
        let cards = [
            #"{ "config": { "public_key": "PEM" }, "stored_instruments": [] }"#,
            #"{ "status": "ACTIVE", "config": { "public_key": "PEM" } }"#,
        ]
        for card in cards {
            HTTPStub.reset()
            HTTPStub.canned = [(201, Self.contractResponse)]
            let result = await tokenize(TokenizeCoordinator(), started: try started(card: card))
            XCTAssertEqual(result.status, .success, card)
            XCTAssertNil(result.errorCode, card)
            XCTAssertEqual(HTTPStub.requests.map(\.url), [Self.tokenizeHref], card)
        }
    }

    func testRefusesWhenCardsAreInactive() async throws {
        let card = #"{ "status": "INACTIVE", "config": { "public_key": "PEM" } }"#
        let result = await tokenize(TokenizeCoordinator(), started: try started(card: card))
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.cardNotConfigured)
        XCTAssertEqual(result.error, "Cards are not active on this session.")
        XCTAssertEqual(encryptCalls, 0)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testRefusesWithoutCardMethod() async throws {
        let result = await tokenize(TokenizeCoordinator(), started: try started(card: nil))
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.cardNotConfigured)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testFailsBeforeStart() async {
        let result = await tokenize(TokenizeCoordinator(), started: nil)
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.tokenizeFailed)
        XCTAssertEqual(encryptCalls, 0)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    // MARK: Success

    func testTokenizesWithoutPaying() async throws {
        HTTPStub.canned = [(201, Self.contractResponse)]
        let result = await tokenize(TokenizeCoordinator(), started: try started(), storeForFuture: true)

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.isSuccess)
        XCTAssertNil(result.errorCode)
        XCTAssertEqual(result.instrument?.id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(encryptCalls, 1)

        // One POST to `_links.tokenize` — no authorize, no poll.
        XCTAssertEqual(HTTPStub.requests.count, 1)
        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, Self.tokenizeHref)
        XCTAssertEqual(request.authorization, "Bearer secret")
        let body = try XCTUnwrap(request.json)
        XCTAssertEqual(body["type"] as? String, "card")
        XCTAssertEqual(body["payment_method"] as? String, "card")
        XCTAssertEqual(body["holder_id"] as? String, "cust_8f3a91")
        XCTAssertEqual(body["holder_type"] as? String, "CUSTOMER")
        XCTAssertEqual(body["data"] as? String, "JWE.PAYLOAD")
        XCTAssertEqual(body["future_usage"] as? String, "unscheduled")
    }

    func testEncryptsWithSessionPublicKey() async throws {
        HTTPStub.canned = [(201, Self.contractResponse)]
        var keys: [String] = []
        _ = await TokenizeCoordinator().tokenize(
            started: try started(),
            storeForFuture: false,
            urlSession: Self.stubbedURLSession()
        ) { key in
            keys.append(key)
            return "JWE.PAYLOAD"
        }
        XCTAssertEqual(keys, ["PEM"])
        XCTAssertNil(HTTPStub.requests.first?.json?["future_usage"])
    }

    func testSecondTokenizeIsConsumed() async throws {
        HTTPStub.canned = [(201, Self.contractResponse)]
        let coordinator = TokenizeCoordinator()
        let started = try started()
        let first = await tokenize(coordinator, started: started)
        XCTAssertEqual(first.status, .success)

        let second = await tokenize(coordinator, started: started)
        XCTAssertEqual(second.status, .failure)
        XCTAssertEqual(second.errorCode, TokenizeErrorCode.sessionConsumed)
        XCTAssertEqual(encryptCalls, 1)
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }

    func testResetAllowsAnotherTokenization() async throws {
        HTTPStub.canned = [(201, Self.contractResponse), (201, Self.contractResponse)]
        let coordinator = TokenizeCoordinator()
        let started = try started()
        let first = await tokenize(coordinator, started: started)
        XCTAssertEqual(first.status, .success)

        coordinator.reset()
        let again = await tokenize(coordinator, started: started)
        XCTAssertEqual(again.status, .success)
        XCTAssertEqual(HTTPStub.requests.count, 2)
    }

    func testConcurrentCallsShareTheRequestInFlight() async throws {
        HTTPStub.canned = [(201, Self.contractResponse)]
        HTTPStub.delay = 0.3
        let coordinator = TokenizeCoordinator()
        let started = try started()

        async let first = tokenize(coordinator, started: started)
        async let second = tokenize(coordinator, started: started)
        let (a, b) = await (first, second)

        XCTAssertEqual(a.status, .success)
        XCTAssertEqual(a, b)
        XCTAssertEqual(encryptCalls, 1)
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }

    // MARK: Failures

    func testUnauthorizedIsSessionExpired() async throws {
        HTTPStub.canned = [(401, #"{"errors":[{"code":"TOKEN_EXPIRED"}]}"#)]
        let result = await tokenize(TokenizeCoordinator(), started: try started())
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.sessionExpired)
        XCTAssertEqual(result.apiErrorCode, "TOKEN_EXPIRED")
        XCTAssertNil(result.instrument)
    }

    func testForbiddenIsSessionExpired() async throws {
        HTTPStub.canned = [(403, "{}")]
        let result = await tokenize(TokenizeCoordinator(), started: try started())
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.sessionExpired)
        XCTAssertNil(result.apiErrorCode)
    }

    func testRefusedRequestDoesNotConsumeSession() async throws {
        HTTPStub.canned = [
            (400, #"{"errors":[{"code":"PAYMENT_METHOD_NOT_SUPPORTED","message":"nope"}]}"#),
            (201, Self.contractResponse),
        ]
        let coordinator = TokenizeCoordinator()
        let started = try started()

        let refused = await tokenize(coordinator, started: started)
        XCTAssertEqual(refused.status, .failure)
        XCTAssertEqual(refused.errorCode, TokenizeErrorCode.tokenizeFailed)
        XCTAssertEqual(refused.apiErrorCode, LiteAPIError.paymentMethodNotSupported)
        XCTAssertFalse(refused.error?.contains("nope") ?? true, "API bodies never reach the error text")

        // The customer corrects the card and retries on the same session.
        let retried = await tokenize(coordinator, started: started)
        XCTAssertEqual(retried.status, .success)
        XCTAssertEqual(HTTPStub.requests.count, 2)
    }

    func testServerErrorWithoutCodeIsTokenizeFailed() async throws {
        HTTPStub.canned = [(500, "oops")]
        let result = await tokenize(TokenizeCoordinator(), started: try started())
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.tokenizeFailed)
        XCTAssertNil(result.apiErrorCode)
    }

    func testEncryptFailureSendsNothing() async throws {
        let result = await TokenizeCoordinator().tokenize(
            started: try started(),
            storeForFuture: false,
            urlSession: Self.stubbedURLSession()
        ) { _ in
            throw LiteError.fieldsIncomplete([.cardNumber])
        }
        XCTAssertEqual(result.errorCode, TokenizeErrorCode.tokenizeFailed)
        XCTAssertEqual(result.error, LiteError.fieldsIncomplete([.cardNumber]).customerSafeMessage)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    // MARK: Response parsing

    func testParsesContractResponse() throws {
        let instrument = try parse(Self.contractResponse)
        XCTAssertEqual(instrument, LiteInstrument(
            id: "550e8400-e29b-41d4-a716-446655440000",
            type: .card,
            createdAt: "2026-10-18T10:00:00Z",
            merchantId: "merch_123",
            holderId: "holder_123",
            holderType: "CUSTOMER",
            futureUsage: "unscheduled_card_on_file",
            card: LiteInstrumentCard(
                scheme: "mada",
                last4: "1234",
                expiryMonth: "03",
                expiryYear: "2028",
                bin: "45717360",
                funding: "debit",
                issuer: "Saudi National Bank",
                issuerCountry: "SA"
            ),
            paymentMethod: "card"
        ))
    }

    /// `paymentMethod` stays readable, deprecated, until the next major.
    @available(*, deprecated)
    func testKeepsTheDeprecatedPaymentMethod() throws {
        XCTAssertEqual(try parse(Self.contractResponse).paymentMethod, "card")
        XCTAssertNil(try parse(#"{"id":"i","type":"card"}"#).paymentMethod)
    }

    func testDoesNotExposeDisplayOrMetadata() throws {
        let instrument = try parse(Self.contractResponse)
        let labels = Mirror(reflecting: instrument).children.compactMap(\.label)
        XCTAssertFalse(labels.contains("display"))
        XCTAssertFalse(labels.contains("metadata"))
        XCTAssertFalse(String(describing: instrument).contains("cardholderName"))
        XCTAssertFalse(String(describing: instrument).contains("MADA"))
    }

    func testKeepsNullCardFields() throws {
        let instrument = try parse("""
        {"id":"i","type":"card","future_usage":null,"card":{"scheme":null,"last4":"1234","expiry_month":null,"expiry_year":null,"bin":null,"funding":null,"issuer":null,"issuer_country":null}}
        """)
        XCTAssertNil(instrument.futureUsage)
        XCTAssertEqual(instrument.card, LiteInstrumentCard(last4: "1234"))
    }

    func testUnknownSchemeAndFundingStillDecode() throws {
        let instrument = try parse(#"{"id":"i","type":"card","card":{"scheme":"elo","funding":"deferred_debit"}}"#)
        XCTAssertEqual(instrument.card?.scheme, "elo")
        XCTAssertEqual(instrument.card?.funding, "deferred_debit")
    }

    func testDerivesTypeFromLegacyPaymentMethod() throws {
        XCTAssertEqual(try parse(#"{"id":"i","payment_method":"card"}"#).type, .card)
        XCTAssertEqual(try parse(#"{"id":"i","payment_method":"applePay"}"#).type, .applePay)
        XCTAssertEqual(try parse(#"{"id":"i","paymentMethod":"applePay"}"#).type, .applePay)
        XCTAssertEqual(try parse(#"{"id":"i","paymentMethod":"card"}"#).type, .card)
        // Nothing on the wire: the method that was tokenized.
        XCTAssertEqual(try parse(#"{"id":"i"}"#, tokenized: .applePay).type, .applePay)
        XCTAssertEqual(try parse(#"{"id":"i"}"#).type, .card)
    }

    func testTypeWinsOverPaymentMethod() throws {
        XCTAssertEqual(try parse(#"{"id":"i","type":"apple_pay","payment_method":"card"}"#).type, .applePay)
        XCTAssertEqual(try parse(#"{"id":"i","type":"masked_pan"}"#).type, .maskedPan)
        XCTAssertEqual(try parse(#"{"id":"i","type":"iban"}"#).type, .iban)
        XCTAssertEqual(try parse(#"{"id":"i","type":"a_new_type"}"#).type, .unknown)
    }

    func testMalformedCardKeepsInstrument() throws {
        // The instrument exists once the API answers; a card of an unexpected shape is dropped.
        let instrument = try parse(#"{"id":"i","type":"card","card":{"expiry_month":3}}"#)
        XCTAssertEqual(instrument.id, "i")
        XCTAssertNil(instrument.card)
    }

    func testMissingIdFailsDecode() {
        XCTAssertThrowsError(try parse(#"{"type":"card"}"#))
    }

    // MARK: Apple Pay + paying a tokenization session

    func testApplePayCreateInstrumentSendsSnakeCaseType() async throws {
        HTTPStub.canned = [(201, #"{"id":"inst_ap","payment_method":"applePay"}"#)]
        let service = PaymentService(started: try started(type: nil), urlSession: Self.stubbedURLSession())
        let instrument = try await service.createInstrument(paymentMethod: .applePay, data: "{}", storeForFuture: false)
        XCTAssertEqual(instrument.id, "inst_ap")
        XCTAssertEqual(instrument.type, .applePay)
        let body = try XCTUnwrap(HTTPStub.requests.first?.json)
        XCTAssertEqual(body["type"] as? String, "apple_pay")
        XCTAssertEqual(body["payment_method"] as? String, "applePay")
    }

    func testAuthorizeOnTokenizationSessionSendsNothing() async throws {
        let service = PaymentService(started: try started(), urlSession: Self.stubbedURLSession())
        let device = Device(
            userAgent: "ua", acceptHeader: "*/*", language: "en", screenHeight: 1, screenWidth: 1,
            colorDepth: 32, timezone: 0, javaEnabled: false, javaScriptEnabled: true
        )
        do {
            _ = try await service.authorize(instrumentId: "inst_1", device: device)
            XCTFail("expected sessionTypeUnsupported")
        } catch LiteError.sessionTypeUnsupported {
            // expected
        }
        do {
            _ = try await service.pollPayment(handledActions: [])
            XCTFail("expected sessionTypeUnsupported")
        } catch LiteError.sessionTypeUnsupported {
            // expected
        }
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testAuthorizeChecksEachPaymentFieldWhereItUsesIt() async throws {
        // A malformed payment session missing one of them still sends nothing.
        let missingLink = try startedSession(json: """
        {
          "id": "s", "status": "OPEN", "amount": 1050, "currency": "SAR",
          "payment_methods": {},
          "_links": {
            "self": { "href": "https://dev.lite.sa/self", "method": "GET" },
            "tokenize": { "href": "\(Self.tokenizeHref)", "method": "POST" }
          }
        }
        """)
        let missingAmount = try startedSession(json: """
        {
          "id": "s", "status": "OPEN",
          "payment_methods": {},
          "_links": {
            "self": { "href": "https://dev.lite.sa/self", "method": "GET" },
            "tokenize": { "href": "\(Self.tokenizeHref)", "method": "POST" },
            "authorize": { "href": "https://dev.lite.sa/api/v1/authorize", "method": "POST" }
          }
        }
        """)
        let device = Device(
            userAgent: "ua", acceptHeader: "*/*", language: "en", screenHeight: 1, screenWidth: 1,
            colorDepth: 32, timezone: 0, javaEnabled: false, javaScriptEnabled: true
        )
        for started in [missingLink, missingAmount] {
            let service = PaymentService(started: started, urlSession: Self.stubbedURLSession())
            do {
                _ = try await service.authorize(instrumentId: "inst_1", device: device)
                XCTFail("expected sessionTypeUnsupported")
            } catch LiteError.sessionTypeUnsupported {
                // expected
            }
        }
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    // MARK: Helpers

    private func tokenize(
        _ coordinator: TokenizeCoordinator,
        started: SessionService.StartedSession?,
        storeForFuture: Bool = false
    ) async -> TokenizeResult {
        await coordinator.tokenize(
            started: started,
            storeForFuture: storeForFuture,
            urlSession: Self.stubbedURLSession()
        ) { [self] _ in
            encryptCalls += 1
            return "JWE.PAYLOAD"
        }
    }

    private func parse(_ json: String, tokenized: PaymentMethod = .card) throws -> LiteInstrument {
        let created = try JSONDecoder().decode(CreatedInstrument.self, from: Data(json.utf8))
        return LiteInstrument(created, tokenized: tokenized)
    }

    /// A tokenization session by default; `type: nil` is a payment session without `type`.
    private func started(
        type: String? = "tokenization",
        card: String? = #"{ "status": "ACTIVE", "config": { "public_key": "PEM" }, "stored_instruments": [] }"#
    ) throws -> SessionService.StartedSession {
        let typeField = type.map { #""type": "\#($0)","# } ?? ""
        let cardField = card.map { #""card": \#($0)"# } ?? ""
        let paymentFields: String
        if type == nil {
            paymentFields = """
            "amount": 1050, "currency": "SAR",
            """
        } else {
            paymentFields = ""
        }
        let paymentLinks: String
        if type == nil {
            paymentLinks = """
            "authorize": { "href": "https://dev.lite.sa/api/v1/authorize", "method": "POST" },
            "payment": { "href": "https://dev.lite.sa/api/v1/payment", "method": "GET" },
            """
        } else {
            paymentLinks = ""
        }
        let json = """
        {
          "id": "sess_tok", \(typeField) "status": "OPEN", \(paymentFields)
          "customer": { "id": "cust_8f3a91" },
          "payment_methods": { \(cardField) },
          "_links": {
            \(paymentLinks)
            "self": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_tok", "method": "GET" },
            "tokenize": { "href": "\(Self.tokenizeHref)", "method": "POST" }
          }
        }
        """
        return try startedSession(json: json)
    }

    private func startedSession(json: String) throws -> SessionService.StartedSession {
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        let claims = LiteJWTClaims(
            sessionId: "sess_tok",
            merchantId: "m",
            iss: "https://dev.lite.sa",
            channelId: nil,
            orderId: nil,
            amount: nil,
            currency: nil
        )
        return SessionService.StartedSession(
            clientSecret: "secret",
            claims: claims,
            endpoints: LiteEndpoints(iss: claims.iss),
            session: session
        )
    }

    private static func stubbedURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        return URLSession(configuration: config)
    }
}
