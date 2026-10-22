import XCTest
@testable import LiteSDKCore
import LiteSDKTestSupport

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
        HTTPStub.reset()
        let opened = try await classify("pending")
        XCTAssertEqual(opened, .showForm)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testClassifyLegacyActiveShowsForm() async throws {
        HTTPStub.reset()
        let opened = try await classify("ACTIVE")
        XCTAssertEqual(opened, .showForm)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testClassifyFailedSkipsPaymentGet() async throws {
        HTTPStub.reset()
        let opened = try await classify("failed")
        XCTAssertEqual(
            opened,
            .terminal(status: .failure, paymentId: nil, error: CheckoutSessionStatus.sessionFailedMessage)
        )
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testClassifyCompletedCapturedIsAlreadyPaid() async throws {
        HTTPStub.reset()
        HTTPStub.canned = [(200, #"{"payment":{"id":"pay_1","status":"CAPTURED"}}"#)]
        let opened = try await classify("completed")
        XCTAssertEqual(
            opened,
            .terminal(
                status: .alreadyCompleted,
                paymentId: "pay_1",
                error: CheckoutSessionStatus.alreadyCompletedMessage
            )
        )
        XCTAssertEqual(HTTPStub.requests.count, 1)
        XCTAssertTrue(HTTPStub.requests[0].url.hasSuffix("/payment"))
    }

    func testClassifyCompletedAuthorizedIsAlreadyPaid() async throws {
        HTTPStub.reset()
        HTTPStub.canned = [(200, #"{"payment":{"id":"pay_9","status":"AUTHORIZED"}}"#)]
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
        HTTPStub.reset()
        HTTPStub.canned = [(200, #"{"payment":{"id":"pay_1","status":"FAILED"}}"#)]
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
        HTTPStub.reset()
        HTTPStub.canned = [(200, #"{"payment":{"id":"pay_1","status":"NOT_A_REAL_STATUS"}}"#)]
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
        HTTPStub.reset()
        HTTPStub.canned = [(500, #"{"error":"nope"}"#)]
        let opened = try await classify("completed")
        XCTAssertEqual(
            opened,
            .terminal(
                status: .failure,
                paymentId: nil,
                error: LiteError.http(status: 500, body: nil).customerSafeMessage
            )
        )
        XCTAssertEqual(HTTPStub.requests.count, 1)
        XCTAssertTrue(HTTPStub.requests[0].url.hasSuffix("/payment"))
    }

    func testClassifyTokenizationSessionSkipsStatusBranch() async throws {
        // A tokenization session has no payment to read: no GET, no already_completed.
        HTTPStub.reset()
        HTTPStub.canned = [(200, #"{"payment":{"id":"pay_1","status":"CAPTURED"}}"#)]
        for status in ["completed", "failed", "OPEN"] {
            let opened = try await classify(status, type: "tokenization")
            XCTAssertEqual(opened, .showForm, status)
        }
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testClassifyTokenizationSessionWhoseCardCarriesNoStatus() async throws {
        HTTPStub.reset()
        let started = try startedSession(json: """
        {
          "id": "sess_1", "type": "tokenization", "status": "OPEN",
          "payment_methods": {
            "card": { "config": { "public_key": "x" }, "stored_instruments": [] }
          },
          "_links": {
            "tokenize": { "href": "https://dev.lite.sa/api/v1/tokenize", "method": "POST" },
            "self": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_1", "method": "GET" }
          }
        }
        """)
        XCTAssertNotNil(started.session.paymentMethods.card)
        let opened = try await SessionService.classifyOpenedCheckout(
            started: started,
            urlSession: Self.stubbedURLSession()
        )
        XCTAssertEqual(opened, .showForm)
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    func testFetchPaymentOnTokenizationSessionSendsNothing() async throws {
        HTTPStub.reset()
        let started = try startedSession(status: "completed", type: "tokenization")
        do {
            _ = try await SessionService.fetchPayment(started: started, urlSession: Self.stubbedURLSession())
            XCTFail("expected sessionTypeUnsupported")
        } catch LiteError.sessionTypeUnsupported {
            // expected
        }
        XCTAssertEqual(HTTPStub.requests.count, 0)
    }

    private func classify(_ sessionStatus: String, type: String? = nil) async throws -> OpenedCheckout {
        let started = try startedSession(status: sessionStatus, type: type)
        return try await SessionService.classifyOpenedCheckout(
            started: started,
            urlSession: Self.stubbedURLSession()
        )
    }

    private func startedSession(status: String, type: String? = nil) throws -> SessionService.StartedSession {
        let json: String
        if let type {
            json = """
            {
              "id": "sess_1",
              "type": "\(type)",
              "status": "\(status)",
              "payment_methods": {
                "card": { "status": "ACTIVE", "config": { "public_key": "x" } }
              },
              "_links": {
                "tokenize": { "href": "https://dev.lite.sa/api/v1/tokenize", "method": "POST" },
                "self": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_1", "method": "GET" }
              }
            }
            """
        } else {
            json = paymentSessionJSON(status: status)
        }
        return try startedSession(json: json)
    }

    private func paymentSessionJSON(status: String) -> String {
        """
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
    }

    private func startedSession(json: String) throws -> SessionService.StartedSession {
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
        config.protocolClasses = [HTTPStub.self]
        return URLSession(configuration: config)
    }
}
