import Foundation

/// Base64URL encode/decode shared by the JWT decoder (Core) and the JWE assembler (Crypto).
/// Mirrors the web SDK: `+`↔`-`, `/`↔`_`, padding stripped on encode and restored (to a
/// multiple of 4) on decode. Foundation has no native base64url, so this is the single
/// home for the logic — callers must not re-implement it.
public enum Base64URL {

    /// Data → base64url string (no `=` padding).
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url string → Data, restoring `=` padding. Returns `nil` on invalid input.
    public static func decode(_ input: String) -> Data? {
        var str = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = str.count % 4
        if remainder > 0 {
            str += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: str)
    }
}
