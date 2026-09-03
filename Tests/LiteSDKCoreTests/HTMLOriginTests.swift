import XCTest
@testable import LiteSDKCore

final class HTMLOriginTests: XCTestCase {

    func testOmitsDefaultHttpsPort() {
        XCTAssertEqual(
            HTMLOrigin.serialized(for: URL(string: "https://acs.example.com:443/challenge")!),
            "https://acs.example.com"
        )
        XCTAssertEqual(
            HTMLOrigin.serialized(for: URL(string: "https://acs.example.com/challenge")!),
            "https://acs.example.com"
        )
    }

    func testKeepsNonDefaultPort() {
        XCTAssertEqual(
            HTMLOrigin.serialized(for: URL(string: "https://acs.example.com:8443/c")!),
            "https://acs.example.com:8443"
        )
    }

    func testLowercasesSchemeAndHost() {
        XCTAssertEqual(
            HTMLOrigin.serialized(for: URL(string: "HTTPS://ACS.Example.COM/c")!),
            "https://acs.example.com"
        )
    }

    func testOmitsDefaultHttpPort() {
        XCTAssertEqual(
            HTMLOrigin.serialized(scheme: "HTTP", host: "LocalHost", port: 80),
            "http://localhost"
        )
    }

    func testRejectsMissingHost() {
        XCTAssertNil(HTMLOrigin.serialized(scheme: "https", host: nil, port: nil))
        XCTAssertNil(HTMLOrigin.serialized(scheme: "https", host: "", port: 443))
    }
}

final class LiteHTTPURLTests: XCTestCase {

    func testAcceptsHttpAndHttpsWithHost() {
        XCTAssertEqual(LiteHTTPURL.parse("https://lite.sa/privacy")?.absoluteString, "https://lite.sa/privacy")
        XCTAssertEqual(LiteHTTPURL.parse("http://example.com/p")?.host, "example.com")
    }

    func testRejectsJavascriptAndCustomSchemes() {
        XCTAssertNil(LiteHTTPURL.parse("javascript:alert(1)"))
        XCTAssertNil(LiteHTTPURL.parse("myapp://privacy"))
        XCTAssertNil(LiteHTTPURL.parse("file:///tmp/x"))
        XCTAssertNil(LiteHTTPURL.parse("https://"))
        XCTAssertNil(LiteHTTPURL.parse("  "))
    }
}
