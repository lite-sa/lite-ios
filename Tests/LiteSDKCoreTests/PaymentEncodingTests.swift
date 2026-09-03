import XCTest
@testable import LiteSDKCore

final class PaymentEncodingTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try LiteHTTP.snakeCaseEncoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testCreateInstrumentRequestBody() throws {
        let obj = try encode(CreateInstrumentRequest(
            holderId: "cust_1",
            paymentMethod: "card",
            holderType: "CUSTOMER",
            data: "JWE.PAYLOAD",
            futureUsage: "unscheduled"
        ))
        XCTAssertEqual(obj["holder_id"] as? String, "cust_1")
        XCTAssertEqual(obj["payment_method"] as? String, "card")
        XCTAssertEqual(obj["holder_type"] as? String, "CUSTOMER")
        XCTAssertEqual(obj["data"] as? String, "JWE.PAYLOAD")
        XCTAssertEqual(obj["future_usage"] as? String, "unscheduled")
    }

    func testCreateInstrumentOmitsFutureUsageWhenNil() throws {
        let obj = try encode(CreateInstrumentRequest(
            holderId: "c", paymentMethod: "card", holderType: "CUSTOMER", data: "x", futureUsage: nil
        ))
        XCTAssertNil(obj["future_usage"])
    }

    func testAuthorizeRequestBody() throws {
        let device = Device(
            userAgent: "LiteSDK-iOS", acceptHeader: "*/*", language: "en-SA",
            screenHeight: 2556, screenWidth: 1179, colorDepth: 32,
            timezone: -180, javaEnabled: false, javaScriptEnabled: true,
            deviceFingerprint: "IDFV-XYZ"
        )
        let req = LitePaymentRequest(
            amount: 15099,
            currency: "SAR",
            processing: .init(processingType: "REGULAR"),
            order: .init(reference: "order_9", amount: 15099, currency: "SAR", description: "Pro", billingAddress:
                .init(name: "Jane Doe", email: "j@e.com", street: "1 St", city: "Riyadh", state: "RY", country: "SA", zip: "12345")),
            captureOptions: .init(captureMode: "INSTANT"),
            paymentInstrument: .init(id: "inst_1"),
            customer: .init(id: "cust_1", email: "j@e.com", firstName: "Jane", lastName: "Doe", phoneCountryCode: "+966", phoneNumber: "500000000"),
            channelId: "chan_1",
            device: device
        )
        let obj = try encode(req)

        XCTAssertEqual(obj["amount"] as? Int, 15099)
        XCTAssertEqual(obj["currency"] as? String, "SAR")
        XCTAssertEqual(obj["channel_id"] as? String, "chan_1")

        XCTAssertEqual((obj["processing"] as? [String: Any])?["processing_type"] as? String, "REGULAR")
        XCTAssertEqual((obj["capture_options"] as? [String: Any])?["capture_mode"] as? String, "INSTANT")
        XCTAssertEqual((obj["payment_instrument"] as? [String: Any])?["id"] as? String, "inst_1")

        let order = obj["order"] as? [String: Any]
        XCTAssertEqual(order?["reference"] as? String, "order_9")
        XCTAssertEqual((order?["billing_address"] as? [String: Any])?["zip"] as? String, "12345")

        let customer = obj["customer"] as? [String: Any]
        XCTAssertEqual(customer?["first_name"] as? String, "Jane")
        XCTAssertEqual(customer?["phone_country_code"] as? String, "+966")

        let dev = obj["device"] as? [String: Any]
        XCTAssertEqual(dev?["java_script_enabled"] as? Bool, true)
        XCTAssertEqual(dev?["screen_height"] as? Int, 2556)
        XCTAssertEqual(dev?["device_fingerprint"] as? String, "IDFV-XYZ")
        XCTAssertEqual((dev?["device_data"] as? [String: Any])?.isEmpty, true)
    }

    func testPaymentResponseDecodesNextActionRedirect() throws {
        let json = """
        {
          "payment": { "id": "pay_1", "status": "REQUIRES_ACTION", "merchant_reference": "m1" },
          "_links": { "self": { "href": "x", "method": "GET" } },
          "next_action": { "redirect": { "method": "GET", "url": "https://acs/challenge" } }
        }
        """
        let response = try JSONDecoder().decode(PaymentResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.payment.id, "pay_1")
        XCTAssertEqual(response.payment.status, .requiresAction)
        XCTAssertEqual(response.nextAction?.redirect?.url, "https://acs/challenge")
    }

    func testUnknownPaymentStatusIsTerminalFailure() throws {
        let json = """
        {
          "payment": { "id": "pay_1", "status": "NOT_A_REAL_STATUS" },
          "next_action": null
        }
        """
        let response = try JSONDecoder().decode(PaymentResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.payment.status, .unknown)
        XCTAssertTrue(PaymentStatus.finalStatuses.contains(.unknown))
        XCTAssertEqual(response.payment.status.operationStatus, .failure)
    }
}
