import Foundation

/// The claims the SDK reads from the session JWT (`secret`).
/// The API issues snake_case claims (`session_id`, `merchant_id`, `channel_id`, `order_id`), as the
/// web SDK reads them (`@litesa/telemetry` `session-token.ts`); the camelCase spellings are still
/// accepted so older tokens decode. `sessionId`, `merchantId`, and `iss` are required;
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

extension LiteJWTClaims {
    private enum CodingKeys: String, CodingKey {
        case session_id, sessionId, merchant_id, merchantId, iss
        case channel_id, channelId, order_id, orderId, amount, currency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func either(_ snake: CodingKeys, _ camel: CodingKeys) throws -> String? {
            try c.decodeIfPresent(String.self, forKey: snake) ?? c.decodeIfPresent(String.self, forKey: camel)
        }
        guard let sessionId = try either(.session_id, .sessionId) else {
            throw DecodingError.keyNotFound(CodingKeys.session_id, .init(codingPath: [], debugDescription: "session_id"))
        }
        guard let merchantId = try either(.merchant_id, .merchantId) else {
            throw DecodingError.keyNotFound(CodingKeys.merchant_id, .init(codingPath: [], debugDescription: "merchant_id"))
        }
        self.init(
            sessionId: sessionId,
            merchantId: merchantId,
            iss: try c.decode(String.self, forKey: .iss),
            channelId: try either(.channel_id, .channelId),
            orderId: try either(.order_id, .orderId),
            amount: try c.decodeIfPresent(Double.self, forKey: .amount),
            currency: try c.decodeIfPresent(String.self, forKey: .currency)
        )
    }
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
