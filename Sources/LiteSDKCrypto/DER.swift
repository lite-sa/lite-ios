import Foundation

/// Minimal ASN.1 DER helpers, just enough to convert between an RSA public key in
/// SPKI/X.509 form (`-----BEGIN PUBLIC KEY-----`, what the Lite session ships) and the
/// PKCS#1 `RSAPublicKey` form that `SecKeyCreateWithData` requires. See DESIGN §5.2.
enum DER {

    enum DERError: Error, Equatable {
        case invalidPEM
        case invalidStructure
    }

    // MARK: Encoding

    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(value.count) + value
    }

    // MARK: Parsing

    struct TLV {
        let tag: UInt8
        let valueStart: Int
        let valueLength: Int
        let next: Int
    }

    static func readTLV(_ data: [UInt8], _ offset: Int) throws -> TLV {
        guard offset < data.count else { throw DERError.invalidStructure }
        let tag = data[offset]
        var i = offset + 1
        guard i < data.count else { throw DERError.invalidStructure }

        var length = Int(data[i])
        i += 1
        if length & 0x80 != 0 {
            let numBytes = length & 0x7F
            guard numBytes > 0, numBytes <= 4, i + numBytes <= data.count else {
                throw DERError.invalidStructure
            }
            length = 0
            for _ in 0..<numBytes {
                let shifted = length.multipliedReportingOverflow(by: 256)
                guard !shifted.overflow else { throw DERError.invalidStructure }
                let added = shifted.partialValue.addingReportingOverflow(Int(data[i]))
                guard !added.overflow else { throw DERError.invalidStructure }
                length = added.partialValue
                i += 1
            }
        }
        guard i + length <= data.count else { throw DERError.invalidStructure }
        return TLV(tag: tag, valueStart: i, valueLength: length, next: i + length)
    }

    // MARK: RSA SPKI <-> PKCS#1

    /// Fixed AlgorithmIdentifier for rsaEncryption (OID 1.2.840.113549.1.1.1, params NULL).
    static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
        0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]

    /// Wrap a PKCS#1 `RSAPublicKey` into an SPKI `SubjectPublicKeyInfo`.
    static func spkiFromPKCS1(_ pkcs1: [UInt8]) -> [UInt8] {
        let bitString = tlv(0x03, [0x00] + pkcs1) // BIT STRING, 0 unused bits
        return tlv(0x30, rsaAlgorithmIdentifier + bitString)
    }

    /// Extract the PKCS#1 `RSAPublicKey` from an SPKI `SubjectPublicKeyInfo`.
    static func pkcs1FromSPKI(_ spki: [UInt8]) throws -> [UInt8] {
        let outer = try readTLV(spki, 0)
        guard outer.tag == 0x30 else { throw DERError.invalidStructure }
        // AlgorithmIdentifier SEQUENCE (skip)
        let alg = try readTLV(spki, outer.valueStart)
        guard alg.tag == 0x30 else { throw DERError.invalidStructure }
        let algTLV = Array(spki[outer.valueStart..<alg.next])
        guard algTLV == rsaAlgorithmIdentifier else { throw DERError.invalidStructure }
        // BIT STRING containing the PKCS#1 key
        let bitString = try readTLV(spki, alg.next)
        guard bitString.tag == 0x03, bitString.valueLength >= 1 else {
            throw DERError.invalidStructure
        }
        guard spki[bitString.valueStart] == 0x00 else { throw DERError.invalidStructure }
        return Array(spki[(bitString.valueStart + 1)..<(bitString.valueStart + bitString.valueLength)])
    }

    // MARK: PEM

    static func derFromPEM(_ pem: String) throws -> [UInt8] {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("BEGIN PUBLIC KEY"), trimmed.contains("END PUBLIC KEY") else {
            throw DERError.invalidPEM
        }
        let body = trimmed
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw DERError.invalidPEM }
        return [UInt8](data)
    }

    static func pemFromDER(_ der: [UInt8], label: String) -> String {
        let b64 = Data(der).base64EncodedString()
        var lines: [Substring] = []
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(b64[idx..<end])
            idx = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }
}
