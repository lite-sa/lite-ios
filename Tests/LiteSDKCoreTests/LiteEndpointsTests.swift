import XCTest
@testable import LiteSDKCore

final class LiteEndpointsTests: XCTestCase {

    func testSecureOriginInjectsSdkAfterScheme() {
        XCTAssertEqual(LiteEndpoints(iss: "https://lite.sa").secureOrigin, "https://sdk.lite.sa")
        XCTAssertEqual(LiteEndpoints(iss: "https://dev.lite.sa").secureOrigin, "https://sdk.dev.lite.sa")
        XCTAssertEqual(LiteEndpoints(iss: "https://staging.lite.sa").secureOrigin, "https://sdk.staging.lite.sa")
        XCTAssertEqual(LiteEndpoints(iss: "http://localhost:3002").secureOrigin, "http://sdk.localhost:3002")
    }

    func testResourcesPerIss() {
        XCTAssertEqual(LiteEndpoints(iss: "https://lite.sa").resources, "https://sdk.lite.sa/public/p/fields")
        XCTAssertEqual(LiteEndpoints(iss: "https://staging.lite.sa").resources, "https://sdk.staging.lite.sa/public/p/fields")
        XCTAssertEqual(LiteEndpoints(iss: "https://dev.lite.sa").resources, "https://sdk.dev.lite.sa/public/rc/fields")
        // unknown iss → empty suffix
        XCTAssertEqual(LiteEndpoints(iss: "https://unknown.example").resources, "https://sdk.unknown.example")
    }

    func testApiIsRawIss() {
        XCTAssertEqual(LiteEndpoints(iss: "https://lite.sa").api, "https://lite.sa")
    }

    func testSessionURL() {
        let url = LiteEndpoints(iss: "https://dev.lite.sa").sessionURL(sessionId: "sess_1")
        XCTAssertEqual(url?.absoluteString, "https://dev.lite.sa/api/v1/checkout/sessions/sess_1")
    }

    func testSessionURLPercentEncodesReservedCharacters() {
        let url = LiteEndpoints(iss: "https://dev.lite.sa").sessionURL(sessionId: "a/b?x#y")
        XCTAssertEqual(
            url?.absoluteString,
            "https://dev.lite.sa/api/v1/checkout/sessions/a%2Fb%3Fx%23y"
        )
        XCTAssertNil(LiteEndpoints(iss: "https://dev.lite.sa").sessionURL(sessionId: ""))
    }

    func testSessionURLRejectsEmptySessionId() {
        XCTAssertNil(LiteEndpoints(iss: "https://lite.sa").sessionURL(sessionId: ""))
    }

    func testSecureOriginWithoutHTTPSchemePrefix() {
        XCTAssertEqual(LiteEndpoints(iss: "lite.sa").secureOrigin, "lite.sa")
        XCTAssertEqual(LiteEndpoints(iss: "not-a-url").secureOrigin, "not-a-url")
    }
}
