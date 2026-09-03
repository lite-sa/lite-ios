import XCTest
import Security
import CryptoKit
@testable import LiteSDKCrypto
@testable import LiteSDKCore

final class CardEncryptorTests: XCTestCase {

    /// Full round-trip through the PUBLIC API path:
    /// generate keypair → build the exact base64(PEM(SPKI)) wire format → `encrypt(...)`
    /// → decrypt the CEK with the private key (RSA-OAEP-SHA256) → AES-GCM open with the
    /// header as AAD → assert the plaintext and the exact protected header.
    ///
    /// This proves the JWE is well-formed and uses RSA-OAEP-256 + A256GCM correctly, which
    /// is the single highest-risk item in the port (DESIGN §5.2).
    func testJWERoundTripViaPublicKeyImport() throws {
        // 1. Ephemeral RSA-2048 keypair.
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            return XCTFail("keygen failed: \(String(describing: error?.takeRetainedValue()))")
        }
        let publicKey = SecKeyCopyPublicKey(privateKey)!

        // 2. Export public key (PKCS#1) → SPKI → PEM → base64-wrap, matching the wire contract.
        let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error)! as Data
        let spki = DER.spkiFromPKCS1([UInt8](pkcs1))
        let pem = DER.pemFromDER(spki, label: "PUBLIC KEY")
        let base64WrappedPEM = Data(pem.utf8).base64EncodedString()

        // 3. Encrypt collected card data.
        let card = CardData(
            cardNumber: "4111111111111111",
            expiryMonth: "12",
            expiryYear: "30",
            cvv: "123",
            cardholderName: "Jane Doe"
        )
        let jwe = try CardEncryptor.encrypt(card, base64WrappedPEMPublicKey: base64WrappedPEM)

        // 4. Parse compact serialization (5 parts).
        let parts = jwe.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts.count, 5, "compact JWE must have 5 segments")

        // 5. Protected header must be exactly {"alg":"RSA-OAEP-256","enc":"A256GCM"}.
        let headerData = CardEncryptor.base64urlDecode(parts[0])!
        let header = try JSONSerialization.jsonObject(with: headerData) as! [String: String]
        XCTAssertEqual(header, ["alg": "RSA-OAEP-256", "enc": "A256GCM"])

        // 6. Unwrap the CEK with the private key.
        let encryptedKey = CardEncryptor.base64urlDecode(parts[1])!
        guard let cekData = SecKeyCreateDecryptedData(
            privateKey, .rsaEncryptionOAEPSHA256, encryptedKey as CFData, &error
        ) as Data? else {
            return XCTFail("CEK unwrap failed: \(String(describing: error?.takeRetainedValue()))")
        }
        XCTAssertEqual(cekData.count, 32, "CEK must be 256-bit")

        // 7. AES-256-GCM open, authenticating the base64url header (AAD).
        let iv = CardEncryptor.base64urlDecode(parts[2])!
        let ciphertext = CardEncryptor.base64urlDecode(parts[3])!
        let tag = CardEncryptor.base64urlDecode(parts[4])!
        XCTAssertEqual(iv.count, 12, "IV must be 96-bit")
        XCTAssertEqual(tag.count, 16, "auth tag must be 128-bit")

        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: iv),
            ciphertext: ciphertext,
            tag: tag
        )
        let aad = Data(parts[0].utf8)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: cekData), authenticating: aad)

        // 8. Plaintext must be the exact ordered payload.
        let json = try JSONSerialization.jsonObject(with: plaintext) as! [String: String]
        XCTAssertEqual(json["cardNumber"], "4111111111111111")
        XCTAssertEqual(json["expiryMonth"], "12")
        XCTAssertEqual(json["expiryYear"], "30")
        XCTAssertEqual(json["cvv"], "123")
        XCTAssertEqual(json["cardholderName"], "Jane Doe")

        // Verify field order matches the web JSON.stringify contract.
        let jsonString = String(data: plaintext, encoding: .utf8)!
        XCTAssertEqual(
            jsonString,
            #"{"cardNumber":"4111111111111111","expiryMonth":"12","expiryYear":"30","cvv":"123","cardholderName":"Jane Doe"}"#
        )
    }

    /// Wrong AAD (tampered header) must fail the GCM tag — sanity check on authentication.
    func testTamperedHeaderFailsAuthentication() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!
        let publicKey = SecKeyCopyPublicKey(privateKey)!

        let card = CardData(cardNumber: "4111111111111111", expiryMonth: "01", expiryYear: "28", cvv: "999", cardholderName: "A B")
        let jwe = try CardEncryptor.encrypt(card, publicKey: publicKey)
        let parts = jwe.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts.count, 5)

        let cekData = SecKeyCreateDecryptedData(
            privateKey, .rsaEncryptionOAEPSHA256, CardEncryptor.base64urlDecode(parts[1])! as CFData, &error
        )! as Data
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: CardEncryptor.base64urlDecode(parts[2])!),
            ciphertext: CardEncryptor.base64urlDecode(parts[3])!,
            tag: CardEncryptor.base64urlDecode(parts[4])!
        )
        // Authenticate with a WRONG aad → must throw.
        XCTAssertThrowsError(
            try AES.GCM.open(box, using: SymmetricKey(data: cekData), authenticating: Data("wrong".utf8))
        )
    }

    /// SPKI <-> PKCS#1 conversions are inverses.
    func testDERConversionsRoundTrip() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = [UInt8](try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?))

        let spki = DER.spkiFromPKCS1(pkcs1)
        let recovered = try DER.pkcs1FromSPKI(spki)
        XCTAssertEqual(recovered, pkcs1)
    }
}
