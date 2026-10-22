import XCTest
@testable import LiteSDKCore

final class SessionDecodingTests: XCTestCase {

    // Representative session payload. Apple Pay uses the runtime wire key `apple_pay`
    // (what hosted checkout / ApplePayButton read), not the TS enum value `applePay`.
    private let json = """
    {
      "id": "sess_123",
      "status": "CREATED",
      "expires_on": "2026-07-03T12:00:00Z",
      "channel_id": "chan_1",
      "order_id": "order_9",
      "capture_mode": "MANUAL",
      "amount": 15099,
      "currency": "SAR",
      "payment_methods": {
        "card": {
          "status": "ACTIVE",
          "config": { "public_key": "TFMwdExTMUNSVWRKVGc9PQ==" },
          "stored_instruments": [
            { "id": "inst_1", "payment_method": "card", "holder_type": "BENEFICIARY",
              "display": { "expiry_year": "30", "expiry_month": "12", "scheme": "visa", "last_4": "4242" } }
          ]
        },
        "apple_pay": {
          "status": "INACTIVE",
          "dependencies": { "merchant_identifier": "merchant.sa.lite", "_merchant_identifier": "x" },
          "config": { "countryCode": "SA", "merchantCapabilities": ["supports3DS"], "supportedNetworks": ["visa","mada"], "version": 3 }
        }
      },
      "customer": { "id": "cust_1", "first_name": "Jane", "email": "jane@example.com" },
      "_links": {
        "start_payment_session": { "href": "https://dev.lite.sa/api/v1/.../start", "method": "POST" },
        "tokenize": { "href": "https://dev.lite.sa/api/v1/.../tokenize", "method": "POST" },
        "authorize": { "href": "https://dev.lite.sa/api/v1/.../authorize", "method": "POST" },
        "self": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_123", "method": "GET" },
        "payment": { "href": "https://dev.lite.sa/api/v1/.../payment", "method": "GET" }
      },
      "product": { "name": "Pro Plan", "image": "https://img/x.png" },
      "checkout_config": { "locale": "en", "redirect_urls": { "success": "https://ok", "failure": "https://no" } },
      "some_unknown_future_field": { "nested": true }
    }
    """

    func testDecodesSession() throws {
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))

        XCTAssertEqual(session.id, "sess_123")
        XCTAssertEqual(session.amount, 15099)
        XCTAssertEqual(session.currency, "SAR")
        XCTAssertEqual(session.orderId, "order_9")
        XCTAssertEqual(session.channelId, "chan_1")
        XCTAssertEqual(session.expiresOn, "2026-07-03T12:00:00Z")
        XCTAssertEqual(session.captureMode, .manual)

        XCTAssertEqual(session.paymentMethods.card?.status, .active)
        XCTAssertEqual(session.cardPublicKey, "TFMwdExTMUNSVWRKVGc9PQ==")
        XCTAssertEqual(session.paymentMethods.card?.storedInstruments?.first?.display.last4, "4242")
        XCTAssertNil(session.processingType)

        XCTAssertEqual(session.paymentMethods.applePay?.status, .inactive)
        XCTAssertEqual(session.paymentMethods.applePay?.dependencies?.merchantIdentifier, "merchant.sa.lite")
        XCTAssertEqual(session.paymentMethods.applePay?.dependencies?.merchantIdentifierHash, "x")
        XCTAssertEqual(session.paymentMethods.applePay?.config?.countryCode, "SA")
        XCTAssertEqual(session.paymentMethods.applePay?.config?.supportedNetworks, ["visa", "mada"])

        XCTAssertEqual(session.links.tokenize.href, "https://dev.lite.sa/api/v1/.../tokenize")
        XCTAssertEqual(session.links.selfLink.method, "GET")
        XCTAssertNotNil(session.links.startPaymentSession)
        XCTAssertEqual(session.customer?.firstName, "Jane")
        XCTAssertEqual(session.product?.name, "Pro Plan")
        XCTAssertEqual(session.checkoutConfig?.redirectUrls?.success, "https://ok")
    }

    func testDecodesUnrecognizedCaptureModeAsUnknown() throws {
        let payload = json.replacingOccurrences(
            of: #""capture_mode": "MANUAL""#, with: #""capture_mode": "DEFERRED""#
        )
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(payload.utf8))
        XCTAssertEqual(session.captureMode, .unknown)
    }

    func testDecodesSessionWithoutStartPaymentSessionLink() throws {
        let json = """
        {
          "id": "sess_1", "status": "CREATED", "amount": 10000, "currency": "SAR",
          "payment_methods": {
            "card": { "status": "ACTIVE", "config": { "public_key": "x" } }
          },
          "_links": {
            "tokenize": { "href": "https://x/tokenize", "method": "POST" },
            "authorize": { "href": "https://x/authorize", "method": "POST" },
            "self": { "href": "https://x/self", "method": "GET" },
            "payment": { "href": "https://x/payment", "method": "GET" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertNil(session.links.startPaymentSession)
        XCTAssertEqual(session.links.tokenize.href, "https://x/tokenize")
    }

    func testSoftDecodesInactiveCardWithoutConfig() throws {
        let json = """
        {
          "id": "sess_1", "status": "CREATED", "amount": 10000, "currency": "SAR",
          "payment_methods": {
            "card": { "status": "INACTIVE" }
          },
          "_links": {
            "tokenize": { "href": "https://x/tokenize", "method": "POST" },
            "authorize": { "href": "https://x/authorize", "method": "POST" },
            "self": { "href": "https://x/self", "method": "GET" },
            "payment": { "href": "https://x/payment", "method": "GET" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.paymentMethods.card?.status, .inactive)
        XCTAssertNil(session.paymentMethods.card?.config)
        XCTAssertNil(session.cardPublicKey)
    }

    func testMissingRequiredFieldThrows() {
        let bad = #"{ "id": "x", "status": "CREATED" }"# // no amount/currency/payment_methods/_links
        XCTAssertThrowsError(try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(bad.utf8)))
    }

    func testDecodesApplePayWireKeyWhenActive() throws {
        let json = """
        {
          "id": "sess_1", "status": "CREATED", "amount": 10000, "currency": "SAR",
          "payment_methods": {
            "card": { "status": "ACTIVE", "config": { "public_key": "x" } },
            "apple_pay": {
              "status": "ACTIVE",
              "dependencies": { "merchant_identifier": "merchant.sa.lite", "_merchant_identifier": "hash" },
              "config": {
                "countryCode": "SA",
                "merchantCapabilities": ["supports3DS", "supportsCredit", "supportsDebit"],
                "supportedNetworks": ["amex", "discover", "masterCard", "visa", "mada"],
                "version": 3
              }
            }
          },
          "_links": {
            "start_payment_session": { "href": "https://x/start", "method": "POST" },
            "tokenize": { "href": "https://x/tokenize", "method": "POST" },
            "authorize": { "href": "https://x/authorize", "method": "POST" },
            "self": { "href": "https://x/self", "method": "GET" },
            "payment": { "href": "https://x/payment", "method": "GET" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        let applePay = try XCTUnwrap(session.paymentMethods.applePay)
        XCTAssertEqual(applePay.status, .active)
        XCTAssertEqual(applePay.dependencies?.merchantIdentifier, "merchant.sa.lite")
        XCTAssertEqual(applePay.config?.version, 3)
        XCTAssertEqual(applePay.config?.supportedNetworks?.count, 5)
    }

    func testDecodesApplePayStatusOnlyWithoutConfig() throws {
        // INACTIVE payloads often omit config/dependencies — must not fail the session.
        let json = """
        {
          "id": "sess_1", "status": "CREATED", "amount": 10000, "currency": "SAR",
          "payment_methods": {
            "card": { "status": "ACTIVE", "config": { "public_key": "x" } },
            "apple_pay": { "status": "INACTIVE" }
          },
          "_links": {
            "start_payment_session": { "href": "https://x/start", "method": "POST" },
            "tokenize": { "href": "https://x/tokenize", "method": "POST" },
            "authorize": { "href": "https://x/authorize", "method": "POST" },
            "self": { "href": "https://x/self", "method": "GET" },
            "payment": { "href": "https://x/payment", "method": "GET" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.paymentMethods.applePay?.status, .inactive)
        XCTAssertNil(session.paymentMethods.applePay?.config)
        XCTAssertNil(session.paymentMethods.applePay?.dependencies)
    }

    func testFallsBackToCamelCaseApplePayKey() throws {
        let json = """
        {
          "id": "sess_1", "status": "CREATED", "amount": 10000, "currency": "SAR",
          "payment_methods": {
            "applePay": {
              "status": "ACTIVE",
              "dependencies": { "merchant_identifier": "merchant.sa.lite", "_merchant_identifier": "hash" },
              "config": {
                "countryCode": "SA",
                "merchantCapabilities": ["supports3DS"],
                "supportedNetworks": ["visa"],
                "version": 3
              }
            }
          },
          "_links": {
            "start_payment_session": { "href": "https://x/start", "method": "POST" },
            "tokenize": { "href": "https://x/tokenize", "method": "POST" },
            "authorize": { "href": "https://x/authorize", "method": "POST" },
            "self": { "href": "https://x/self", "method": "GET" },
            "payment": { "href": "https://x/payment", "method": "GET" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.paymentMethods.applePay?.status, .active)
        XCTAssertEqual(session.paymentMethods.applePay?.dependencies?.merchantIdentifier, "merchant.sa.lite")
    }

    func testDecodesTokenizationSession() throws {
        // No amount, currency, order or payment links — only self and tokenize.
        let json = """
        {
          "id": "sess_tok", "type": "tokenization", "status": "OPEN", "expires_on": "2026-10-21T12:00:00Z",
          "customer": { "id": "cust_8f3a91" },
          "payment_methods": {
            "card": {
              "status": "ACTIVE",
              "networks": { "visa": true, "mastercard": true, "mada": true },
              "config": { "public_key": "x" },
              "stored_instruments": [
                { "id": "inst_1", "payment_method": "card", "holder_type": "CUSTOMER",
                  "display": { "expiry_year": "30", "expiry_month": "12", "scheme": "visa", "last_4": "4242" } }
              ]
            }
          },
          "_links": {
            "self": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_tok", "method": "GET" },
            "tokenize": { "href": "https://dev.lite.sa/api/v1/checkout/instruments", "method": "POST" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.type, .tokenization)
        XCTAssertTrue(session.isTokenization)
        XCTAssertNil(session.amount)
        XCTAssertNil(session.currency)
        XCTAssertNil(session.orderId)
        XCTAssertNil(session.order)
        XCTAssertNil(session.links.authorize)
        XCTAssertNil(session.links.payment)
        XCTAssertNil(session.links.startPaymentSession)
        XCTAssertEqual(session.links.tokenize.href, "https://dev.lite.sa/api/v1/checkout/instruments")
        XCTAssertEqual(session.customer?.id, "cust_8f3a91")
        XCTAssertEqual(session.cardPublicKey, "x")
        // Whatever the API lists, a tokenization session offers no stored cards.
        XCTAssertEqual(session.paymentMethods.card?.storedInstruments?.count, 1)
        XCTAssertEqual(session.storedCardInstruments, [])
    }

    func testDecodesTokenizationSessionWhoseCardCarriesNoStatus() throws {
        // The live tokenization session sends the card method with neither `status` nor `networks`.
        let json = """
        {
          "id": "sess_tok", "type": "tokenization", "status": "OPEN",
          "payment_methods": {
            "card": {
              "config": { "public_key": "-----BEGIN PUBLIC KEY-----x" },
              "stored_instruments": []
            }
          },
          "_links": {
            "self": { "href": "https://dev.lite.sa/api/v1/checkout/sessions/sess_tok", "method": "GET" },
            "tokenize": { "href": "https://dev.lite.sa/api/v1/checkout/instruments", "method": "POST" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.type, .tokenization)
        let card = try XCTUnwrap(session.paymentMethods.card, "the card method must decode, not soft-fail to nil")
        XCTAssertNil(card.status)
        XCTAssertNil(card.networks)
        XCTAssertEqual(card.storedInstruments?.count, 0)
        XCTAssertEqual(session.cardPublicKey, "-----BEGIN PUBLIC KEY-----x")
    }

    func testSessionWithoutTypeIsPayment() throws {
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.type, .payment)
        XCTAssertFalse(session.isTokenization)
        XCTAssertEqual(session.links.authorize?.href, "https://dev.lite.sa/api/v1/.../authorize")
        XCTAssertEqual(session.links.payment?.href, "https://dev.lite.sa/api/v1/.../payment")
        XCTAssertEqual(session.storedCardInstruments.map(\.id), ["inst_1"])
    }

    func testDecodesPaymentSessionType() throws {
        let typed = json.replacingOccurrences(of: #""id": "sess_123","#, with: #""id": "sess_123", "type": "payment","#)
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(typed.utf8))
        XCTAssertEqual(session.type, .payment)
        XCTAssertEqual(session.amount, 15099)
    }

    func testUnknownSessionTypeIsPayment() throws {
        // Web `isTokenizationSession`: a session that is not `tokenization` is a payment session.
        let typed = json.replacingOccurrences(of: #""id": "sess_123","#, with: #""id": "sess_123", "type": "subscription","#)
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(typed.utf8))
        XCTAssertEqual(session.type, .payment)
    }

    func testMotoSessionOffersNoStoredInstruments() throws {
        let moto = json.replacingOccurrences(of: #""id": "sess_123","#, with: #""id": "sess_123", "processing_type": "MOTO","#)
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(moto.utf8))
        XCTAssertEqual(session.storedCardInstruments, [])
    }

    func testDecodesProcessingType() throws {
        let json = """
        {
          "id": "sess_1", "status": "CREATED", "amount": 10000, "currency": "SAR",
          "processing_type": "MOTO",
          "payment_methods": { "card": { "status": "ACTIVE" } },
          "_links": {
            "tokenize": { "href": "https://x/tokenize", "method": "POST" },
            "authorize": { "href": "https://x/authorize", "method": "POST" },
            "self": { "href": "https://x/self", "method": "GET" },
            "payment": { "href": "https://x/payment", "method": "GET" }
          }
        }
        """
        let session = try JSONDecoder().decode(LiteCheckoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.processingType, "MOTO")
    }
}
