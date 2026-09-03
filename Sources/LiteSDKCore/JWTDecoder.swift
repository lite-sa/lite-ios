import Foundation

/// The claims the SDK reads from the session JWT (`secret`).
/// Matches the web `DecodedJWT.payload`. `sessionId`, `merchantId`, and `iss` are required;
/// the rest are optional (amount/currency are informational — live values come from the
/// fetched session, not the token — DESIGN §5.1). `iss` must be a Lite HTTPS host.
public struct LiteJWTClaims: Sendable, Equatable, Decodable {
    public let sessionId: String
    public let merchantId: String
    public let iss: String
    public let channelId: String?
    public let orderId: String?
    public let amount: Double?
    public let currency: String?
}

public enum JWTError: Error, Equatable {
    case malformed
    case invalidBase64
    case invalidJSON
    case missingRequiredClaims
}

/// Decodes the session JWT **without verifying the signature** — matching the web SDK
/// (`decode-jwt.ts`): no signature check, no `exp` check. `iss` is allowlisted to Lite HTTPS
/// hosts so a crafted token cannot redirect the bearer. Adding an `exp` check natively is a
/// deliberate decision to coordinate (DESIGN §10 #6).
public enum JWTDecoder {

    public static func decodeClaims(_ token: String) throws -> LiteJWTClaims {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { throw JWTError.malformed }

        guard let payloadData = Base64URL.decode(String(segments[1])) else {
            throw JWTError.invalidBase64
        }
        let claims: LiteJWTClaims
        do {
            claims = try JSONDecoder().decode(LiteJWTClaims.self, from: payloadData)
        } catch let error as DecodingError {
            // A missing required key surfaces as .keyNotFound → distinguish for clearer errors.
            if case .keyNotFound = error { throw JWTError.missingRequiredClaims }
            throw JWTError.invalidJSON
        } catch {
            throw JWTError.invalidJSON
        }
        guard !claims.sessionId.isEmpty, !claims.merchantId.isEmpty, !claims.iss.isEmpty else {
            throw JWTError.missingRequiredClaims
        }
        // Unsigned JWT: reject a crafted `iss` that would send the bearer token off Lite hosts.
        guard LiteDestinationAllowlist.isAllowed(claims.iss) else {
            throw JWTError.missingRequiredClaims
        }
        return claims
    }
}
