import XCTest
@testable import LiteSDKCore

final class OpenedCheckoutTests: XCTestCase {

    func testCheckoutSessionStatusFromWire() {
        XCTAssertEqual(CheckoutSessionStatus.fromWire("pending"), .pending)
        XCTAssertEqual(CheckoutSessionStatus.fromWire("ACTIVE"), .pending)
        XCTAssertEqual(CheckoutSessionStatus.fromWire(nil), .pending)
        XCTAssertEqual(CheckoutSessionStatus.fromWire("completed"), .completed)
        XCTAssertEqual(CheckoutSessionStatus.fromWire("COMPLETE"), .completed)
        XCTAssertEqual(CheckoutSessionStatus.fromWire("failed"), .failed)
        XCTAssertEqual(CheckoutSessionStatus.fromWire("FAILURE"), .failed)
        XCTAssertTrue(CheckoutSessionStatus.isTerminal("completed"))
        XCTAssertFalse(CheckoutSessionStatus.isTerminal("pending"))
        XCTAssertFalse(CheckoutSessionStatus.isTerminal("ACTIVE"))
    }

    func testClassifyPendingShowsFormWithoutPaymentGet() async throws {
        ClassifyHTTPStub.reset()
        let opened = try await classify("pending")
        XCTAssertEqual(opened, .showForm)
        XCTAssertEqual(ClassifyHTTPStub.urls.count, 0)
    }

    func testClassifyLegacyActiveShowsForm() async throws {
        ClassifyHTTPStub.reset()
        let opened = try await classify("ACTIVE")
        XCTAssertEqual(opened, .showForm)
        XCTAssertEqual(ClassifyHTTPStub.urls.count, 0)
    }

    func testClassifyFailedSkipsPaymentGet() async throws {
        ClassifyHTTPStub.reset()
        let opened = try await classify("failed")
        XCTAssertEqual(
            opened,
            .terminal(status: .failure, paymentId: nil, error: CheckoutSessionStatus.sessionFailedMessage)
        )
        XCTAssertEqual(ClassifyHTTPStub.urls.count, 0)
    }

    func testClassifyCompletedCapturedIsAlreadyPaid() async throws {
        ClassifyHTTPStub.reset()
        ClassifyHTTPStub.canned = [(200, #"{"payment":{"id":"pay_1","status":"CAPTURED"}}"#)]
        let opened = try await classify("completed")
        XCTAssertEqual(
            opened,
            .terminal(
                status: .alreadyCompleted,
                paymentId: "pay_1",
                error: CheckoutSessionStatus.alreadyCompletedMessage
            )
        )
        XCTAssertEqual(ClassifyHTTPStub.urls.count, 1)
        XCTAssertTrue(ClassifyHTTPStub.urls[0].hasSuffix("/payment"))
    }

    func testClassifyCompletedAuthorizedIsAlreadyPaid() async throws {
        ClassifyHTTPStub.reset()
        ClassifyHTTPStub.canned = [(200, #"{"payment":{"id":"pay_9","status":"AUTHORIZED"}}"#)]
        let opened = try await classify("COMPLETE")
        XCTAssertEqual(
            opened,
            .terminal(
                status: .alreadyCompleted,
                paymentId: "pay_9",
                error: CheckoutSessionStatus.alreadyCompletedMessage
            )
        )
    }

    func testClassifyCompletedFailedPaymentIsError() async throws {
        ClassifyHTTPStub.reset()
        ClassifyHTTPStub.canned = [(200, #"{"payment":{"id":"pay_1","status":"FAILED"}}"#)]
        let opened = try await classify("completed")
        XCTAssertEqual(
            opened,
            .terminal(
                status: .failure,
                paymentId: "pay_1",
                error: CheckoutSessionStatus.sessionFailedMessage
            )
        )
    }

    func testClassifyCompletedUnknownPaymentStatus() async throws {
        ClassifyHTTPStub.reset()
        ClassifyHTTPStub.canned = [(200, #"{"payment":{"id":"pay_1","status":"NOT_A_REAL_STATUS"}}"#)]
        let opened = try await classify("completed")
        XCTAssertEqual(
            opened,
            .terminal(
                status: .failure,
                paymentId: "pay_1",
                error: PaymentStatus.unknownStatusMessage
            )
        )
    }

    func testClassifyCompletedPaymentGetFailureStillNoForm() async throws {
        ClassifyHTTPStub.reset()
        ClassifyHTTPStub.canned = [(500, #"{"error":"nope"}"#)]
        let opened = try await classify("completed")
        XCTAssertEqual(
            opened,
            .terminal(
                status: .failure,
                paymentId: nil,
                error: LiteError.http(status: 500, body: nil).customerSafeMessage
            )
        )
        XCTAssertEqual(ClassifyHTTPStub.urls.count, 1)
        XCTAssertTrue(ClassifyHTTPStub.urls[0].hasSuffix("/payment"))
    }

    private func classify(_ sessionStatus: String) async throws -> OpenedCheckout {
        let started = try startedSession(status: sessionStatus)
        return try await SessionService.classifyOpenedCheckout(
            started: started,
            urlSession: Self.stubbedURLSession()
        )
    }

    private func startedSession(status: String) throws -> SessionService.StartedSession {
        let json = """
        {
          "id": "sess_1",
          "status": "\(status)",
          "amount": 1050,
          "currency": "SAR",
          "payment_methods": {
            "card": { "status": "ACTIVE", "config": { "public_key": "x" } }
          },
          "_links": {
            "tokenize": { "href": "https://dev.lite.sa/api/v1/tokenize", "method": "POST" },
            "authorize": { "href": "https://dev.lite.sa/api/v1/authorize", "method": "POST" },
            "self": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_1", "method": "GET" },
            "payment": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_1/payment", "method": "GET" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        let claims = LiteJWTClaims(
            sessionId: "sess_1",
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
        config.protocolClasses = [ClassifyHTTPStub.self]
        return URLSession(configuration: config)
    }
}

private final class ClassifyHTTPStub: URLProtocol {
    static var canned: [(Int, String)] = []
    static var urls: [String] = []

    static func reset() {
        canned = []
        urls = []
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.urls.append(request.url?.absoluteString ?? "")
        let (status, payload) = Self.canned.isEmpty
            ? (500, "{}")
            : Self.canned.removeFirst()
        let data = Data(payload.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Responses are delivered synchronously, so there is no work to cancel.
    }
}
