import Foundation
import Security

/// Imports the RSA public key the Lite session ships.
///
/// Contract (DESIGN §5.2): `session.payment_methods.card.config.public_key` is a
/// **base64-wrapped PEM** (SPKI). Web does `importSPKI(atob(public_key).trim(), 'RSA-OAEP-256')`.
/// Natively we must: outer base64-decode → parse SPKI PEM → strip to PKCS#1 → `SecKeyCreateWithData`.
enum RSAKey {

    enum RSAKeyError: Error, Equatable {
        case invalidOuterBase64
        case invalidPEMEncoding
        case secKeyCreationFailed(String)
    }

    /// Import from the exact wire format: base64( PEM( SPKI ) ).
    static func importPublicKey(base64WrappedPEM: String) throws -> SecKey {
        let compact = base64WrappedPEM.filter { !$0.isWhitespace }
        guard let pemData = Data(base64Encoded: compact) else {
            throw RSAKeyError.invalidOuterBase64
        }
        guard let pem = String(data: pemData, encoding: .utf8) else {
            throw RSAKeyError.invalidPEMEncoding
        }
        let spki = try DER.derFromPEM(pem)
        let pkcs1 = try DER.pkcs1FromSPKI(spki)
        return try secKey(fromPKCS1: pkcs1, isPublic: true)
    }

    /// Build a `SecKey` from PKCS#1 key material.
    static func secKey(fromPKCS1 pkcs1: [UInt8], isPublic: Bool) throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw RSAKeyError.secKeyCreationFailed(message)
        }
        return key
    }
}
