import Foundation
import Security
import CryptoKit
import LiteSDKCore

/// Produces the exact compact JWE the Lite backend expects for card data.
///
/// Protected header: `{"alg":"RSA-OAEP-256","enc":"A256GCM"}` (DESIGN §5.2).
/// Package-scoped — merchants must not call this directly (IOS-019); use `Lite` card fields.
package enum CardEncryptor {

    package enum EncryptionError: Error, Equatable {
        case rsaEncryptFailed(String)
    }

    /// Encrypt collected card data with the session's base64-wrapped PEM public key.
    package static func encrypt(_ card: CardData, base64WrappedPEMPublicKey: String) throws -> String {
        let publicKey: SecKey
        do {
            publicKey = try RSAKey.importPublicKey(base64WrappedPEM: base64WrappedPEMPublicKey)
        } catch {
            throw EncryptionError.rsaEncryptFailed("Invalid public key")
        }
        return try encrypt(card, publicKey: publicKey)
    }

    /// Encrypt with an already-imported `SecKey` (used directly by tests).
    package static func encrypt(_ card: CardData, publicKey: SecKey) throws -> String {
        var plaintext = card.jsonPlaintext()
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }

        // 1. Protected header (fixed) → base64url. Its ASCII bytes are the GCM AAD.
        let headerJSON = Data(#"{"alg":"RSA-OAEP-256","enc":"A256GCM"}"#.utf8)
        let headerB64 = base64url(headerJSON)
        let aad = Data(headerB64.utf8)

        // 2. Random 256-bit content-encryption key.
        let cek = SymmetricKey(size: .bits256)

        // 3. AES-256-GCM seal (random 96-bit nonce), authenticating the header.
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: cek, nonce: nonce, authenticating: aad)
        let iv = Data(nonce)

        // 4. RSA-OAEP-SHA256 wrap of the CEK.
        var cekData = cek.withUnsafeBytes { Data($0) }
        defer { cekData.resetBytes(in: cekData.startIndex..<cekData.endIndex) }
        var error: Unmanaged<CFError>?
        guard let encryptedKey = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionOAEPSHA256,
            cekData as CFData,
            &error
        ) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw EncryptionError.rsaEncryptFailed(message)
        }

        // 5. Assemble the 5-part compact serialization.
        return [
            headerB64,
            base64url(encryptedKey),
            base64url(iv),
            base64url(sealed.ciphertext),
            base64url(sealed.tag),
        ].joined(separator: ".")
    }

    // MARK: - base64url
    // Thin aliases over the shared `Base64URL` helper (Core), kept because the JWE round-trip
    // tests reference `CardEncryptor.base64urlDecode` directly.

    static func base64url(_ data: Data) -> String { Base64URL.encode(data) }

    package static func base64urlDecode(_ input: String) -> Data? { Base64URL.decode(input) }
}
