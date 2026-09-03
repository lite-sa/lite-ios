import Foundation

/// Endpoint derivation from the JWT `iss` claim — there is NO environment parameter;
/// everything is derived from `iss` (DESIGN §5.1). Mirrors web `LiteEndpoints`.
public struct LiteEndpoints: Sendable, Equatable {
    /// The raw issuer, e.g. `https://lite.sa`. Used verbatim as the API base.
    public let iss: String

    public init(iss: String) {
        self.iss = iss
    }

    /// API base URL == the raw `iss`.
    public var api: String { iss }

    /// PCI/hosted-fields origin: inject `sdk.` right after the scheme.
    /// `s/^(https?:\/\/)/$1sdk./`  →  `https://lite.sa` → `https://sdk.lite.sa`.
    /// (Mostly irrelevant for native card capture, but kept for any hosted HTTPS assets.)
    public var secureOrigin: String {
        guard let range = iss.range(of: "^https?://", options: .regularExpression) else {
            return iss
        }
        let scheme = String(iss[range])
        return scheme + "sdk." + iss[range.upperBound...]
    }

    /// Per-`iss` resource path suffix (web `RESOURCES_PATHS`); unknown `iss` → "".
    private static let resourcePaths: [String: String] = [
        "https://lite.sa": "/public/p/fields",
        "https://staging.lite.sa": "/public/p/fields",
        "https://dev.lite.sa": "/public/rc/fields",
        "https://localhost:3002": "",
    ]

    /// Hosted-asset base = secureOrigin + per-iss suffix.
    public var resources: String {
        secureOrigin + (Self.resourcePaths[iss] ?? "")
    }

    /// The ONLY hardcoded path in the SDK. Everything else is HATEOAS (`session._links`).
    public func sessionURL(sessionId: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedId = sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              !encodedId.isEmpty
        else { return nil }
        return URL(string: "\(iss)/api/v1/checkout/sessions/\(encodedId)")
    }
}
