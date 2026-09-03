import XCTest
@testable import LiteSDKCore

final class LiteAPIErrorTests: XCTestCase {

    func testParsesFirstErrorCode() {
        let body = #"{"errors":[{"code":"PAYMENT_METHOD_NOT_SUPPORTED","message":"nope"},{"code":"OTHER","message":"later"}]}"#
        XCTAssertEqual(
            LiteAPIError.errorCode(fromHTTPBody: body),
            LiteAPIError.paymentMethodNotSupported
        )
    }

    func testMissingErrorsReturnsNil() {
        XCTAssertNil(LiteAPIError.errorCode(fromHTTPBody: #"{"message":"fail"}"#))
        XCTAssertNil(LiteAPIError.errorCode(fromHTTPBody: nil))
        XCTAssertNil(LiteAPIError.errorCode(fromHTTPBody: "not-json"))
    }

    func testLiteErrorHttpExposesApiErrorCode() {
        let body = #"{"errors":[{"code":"PAYMENT_METHOD_NOT_SUPPORTED"}]}"#
        let error = LiteError.http(status: 400, body: body)
        XCTAssertEqual(error.apiErrorCode, LiteAPIError.paymentMethodNotSupported)
    }

    func testHttpDescriptionDoesNotIncludeBody() {
        let error = LiteError.http(status: 500, body: "{\"secret\":\"nope\"}")
        XCTAssertEqual(String(describing: error), "Http(status=500)")
        XCTAssertFalse(error.customerSafeMessage.contains("secret"))
        XCTAssertFalse(error.merchantMessage.contains("secret"))
    }
}
