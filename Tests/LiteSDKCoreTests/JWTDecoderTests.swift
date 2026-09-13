import XCTest
@testable import LiteSDKCore

final class JWTDecoderTests: XCTestCase {

    /// Build an unsigned JWT-shaped token (`header.payload.sig`) with a base64url payload.
    private func makeToken(payload: [String: Any], signature: String = "sig") throws -> String {
        let header = base64url(try JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"]))
        let body = base64url(try JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).\(signature)"
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testDecodesRequiredAndOptionalClaims() throws {
        let token = try makeToken(payload: [
            "sessionId": "sess_123",
            "merchantId": "merch_456",
            "iss": "https://dev.lite.sa",
            "channelId": "chan_789",
            "amount": 1500,
            "currency": "SAR",
        ])
        let claims = try JWTDecoder.decodeClaims(token)
        XCTAssertEqual(claims.sessionId, "sess_123")
        XCTAssertEqual(claims.merchantId, "merch_456")
        XCTAssertEqual(claims.iss, "https://dev.lite.sa")
        XCTAssertEqual(claims.channelId, "chan_789")
        XCTAssertEqual(claims.currency, "SAR")
    }

    func testDecodesWithoutOptionalClaims() throws {
        let token = try makeToken(payload: [
            "sessionId": "s",
            "merchantId": "m",
            "iss": "https://lite.sa",
        ])
        let claims = try JWTDecoder.decodeClaims(token)
        XCTAssertNil(claims.channelId)
        XCTAssertNil(claims.amount)
    }

    func testMissingRequiredClaimThrows() throws {
        let token = try makeToken(payload: ["merchantId": "m", "iss": "https://lite.sa"]) // no sessionId
        XCTAssertThrowsError(try JWTDecoder.decodeClaims(token)) { error in
            XCTAssertEqual(error as? JWTError, .missingRequiredClaims)
        }
    }

    func testMalformedTokenThrows() {
        XCTAssertThrowsError(try JWTDecoder.decodeClaims("onlyonesegment")) { error in
            XCTAssertEqual(error as? JWTError, .malformed)
        }
    }

    func testDoesNotVerifySignature() throws {
        // A garbage signature must still decode — decode is unverified (matches web).
        let token = try makeToken(
            payload: ["sessionId": "s", "merchantId": "m", "iss": "https://lite.sa"],
            signature: "totally-invalid-signature"
        )
        XCTAssertNoThrow(try JWTDecoder.decodeClaims(token))
    }

    func testRejectsNonLiteIssuer() throws {
        let token = try makeToken(payload: [
            "sessionId": "s",
            "merchantId": "m",
            "iss": "https://lite.sa.evil.com",
        ])
        XCTAssertThrowsError(try JWTDecoder.decodeClaims(token)) { error in
            XCTAssertEqual(error as? JWTError, .missingRequiredClaims)
        }
    }

    func testRejectsNonHTTPSIssuer() throws {
        let token = try makeToken(payload: [
            "sessionId": "s",
            "merchantId": "m",
            "iss": "http://dev.lite.sa",
        ])
        XCTAssertThrowsError(try JWTDecoder.decodeClaims(token)) { error in
            XCTAssertEqual(error as? JWTError, .missingRequiredClaims)
        }
    }
}
