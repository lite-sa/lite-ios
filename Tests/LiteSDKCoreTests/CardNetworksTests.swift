import XCTest
@testable import LiteSDKCore

final class CardNetworksTests: XCTestCase {

    func testMissingNetworksEnablesAll() {
        XCTAssertEqual(
            CardNetworks.enabledNetworks(in: nil),
            [.visa, .mastercard, .mada]
        )
        XCTAssertTrue(CardNetworks.isSchemeEnabled("visa", networks: nil))
        XCTAssertTrue(CardNetworks.isSchemeEnabled("MADA", networks: nil))
    }

    func testExplicitTrueOnly() {
        let networks = CardNetworks(visa: true, mastercard: false, mada: true)
        XCTAssertEqual(CardNetworks.enabledNetworks(in: networks), [.visa, .mada])
        XCTAssertTrue(CardNetworks.isSchemeEnabled("visa", networks: networks))
        XCTAssertFalse(CardNetworks.isSchemeEnabled("mastercard", networks: networks))
        XCTAssertTrue(CardNetworks.isSchemeEnabled("mada", networks: networks))
        XCTAssertTrue(CardNetworks.isSchemeEnabled("MADA", networks: networks))
        XCTAssertTrue(CardNetworks.isSchemeEnabled("Visa", networks: networks))
        XCTAssertFalse(CardNetworks.isSchemeEnabled("MasterCard", networks: networks))
    }

    func testNilFlagIsNotEnabled() {
        let networks = CardNetworks(visa: nil, mastercard: true, mada: nil)
        XCTAssertEqual(CardNetworks.enabledNetworks(in: networks), [.mastercard])
        XCTAssertFalse(CardNetworks.isSchemeEnabled("visa", networks: networks))
    }

    func testUnknownSchemeDisabledWhenNetworksPresent() {
        let networks = CardNetworks(visa: true, mastercard: true, mada: true)
        XCTAssertFalse(CardNetworks.isSchemeEnabled(nil, networks: networks))
        XCTAssertFalse(CardNetworks.isSchemeEnabled("", networks: networks))
        XCTAssertFalse(CardNetworks.isSchemeEnabled("amex", networks: networks))
    }

    func testDecodesNetworksFromSessionJSON() throws {
        let json = """
        {
          "id": "sess_1", "status": "CREATED", "amount": 100, "currency": "SAR",
          "payment_methods": {
            "card": {
              "status": "ACTIVE",
              "networks": { "visa": true, "mastercard": false, "mada": true },
              "config": { "public_key": "x" },
              "stored_instruments": [
                { "id": "inst_visa", "payment_method": "card", "holder_type": "BENEFICIARY",
                  "display": { "expiry_year": "30", "expiry_month": "12", "scheme": "visa", "last_4": "4242" } },
                { "id": "inst_mc", "payment_method": "card", "holder_type": "BENEFICIARY",
                  "display": { "expiry_year": "30", "expiry_month": "01", "scheme": "mastercard", "last_4": "4444" } }
              ]
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
        let networks = session.paymentMethods.card?.networks
        XCTAssertEqual(networks?.visa, true)
        XCTAssertEqual(networks?.mastercard, false)
        XCTAssertEqual(networks?.mada, true)
        XCTAssertEqual(CardNetworks.enabledNetworks(in: networks), [.visa, .mada])
        XCTAssertTrue(CardNetworks.isSchemeEnabled("visa", networks: networks))
        XCTAssertFalse(CardNetworks.isSchemeEnabled("mastercard", networks: networks))
    }
}
