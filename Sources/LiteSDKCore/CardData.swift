import Foundation

/// The cleartext card payload that gets JWE-encrypted before leaving the SDK.
/// Field names and order match the exact web plaintext:
/// `{ cardNumber, expiryMonth, expiryYear, cvv, cardholderName }` (DESIGN §5.2).
/// Package-scoped so host apps cannot construct / encrypt outside Lite fields (IOS-019).
package struct CardData: Sendable, Equatable, CustomStringConvertible {
    package var cardNumber: String
    package var expiryMonth: String
    package var expiryYear: String
    package var cvv: String
    package var cardholderName: String

    package init(
        cardNumber: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        cardholderName: String
    ) {
        self.cardNumber = cardNumber
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.cardholderName = cardholderName
    }

    /// Build from raw field values, splitting the `MM/YY` expiry on `/`.
    /// Month/year are trimmed and stripped of internal whitespace (Android CardData).
    /// Missing `/` keeps month and empty year.
    package init(
        cardNumber: String,
        expiry: String,
        cvv: String,
        cardholderName: String
    ) {
        let parts = expiry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        self.cardNumber = cardNumber.filter { !$0.isWhitespace }
        self.expiryMonth = Self.normalizedExpiryPart(parts[0])
        self.expiryYear = parts.count > 1 ? Self.normalizedExpiryPart(parts[1]) : ""
        self.cvv = cvv
        self.cardholderName = cardholderName
    }

    private static func normalizedExpiryPart(_ part: Substring) -> String {
        String(part).trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isWhitespace }
    }

    /// Ordered, compact JSON exactly as `JSON.stringify(payload)` produces
    /// (keys in order: cardNumber, expiryMonth, expiryYear, cvv, cardholderName).
    ///
    /// Built by hand: `JSONEncoder` does NOT preserve property-declaration order (it emits an
    /// arbitrary order), so we assemble the JSON ourselves to match the web output byte-for-byte.
    package func jsonPlaintext() -> Data {
        let pairs: [(String, String)] = [
            ("cardNumber", cardNumber),
            ("expiryMonth", expiryMonth),
            ("expiryYear", expiryYear),
            ("cvv", cvv),
            ("cardholderName", cardholderName),
        ]
        let body = pairs
            .map { "\"\($0.0)\":\"\(Self.escapeJSONString($0.1))\"" }
            .joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    /// Redacts PAN and CVV. Name and expiry stay.
    package var description: String {
        "CardData(cardNumber: REDACTED, expiryMonth: \(expiryMonth), expiryYear: \(expiryYear), cvv: REDACTED, cardholderName: \(cardholderName))"
    }

    /// Minimal JSON string escaping matching `JSON.stringify`: escapes `"`, `\`, the
    /// control-character shortcuts, and other U+0000–U+001F as `\u00XX`. Non-ASCII passes
    /// through as UTF-8 (exactly as `JSON.stringify` leaves it).
    static func escapeJSONString(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
