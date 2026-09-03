import Foundation

/// Pure card-field validation / formatting / brand detection, ported verbatim from the
/// web SDK (`card-number/element.tsx`, `expiry/element.tsx`, `cvv/element.tsx`).
/// This is the highest-value pure-logic port and is fully unit-tested.
public enum CardValidation {

    // MARK: Brand detection

    /// Mada BINs. Checked BEFORE the visa/mastercard prefix rules — the ordering is
    /// load-bearing: `4464`/`4968` start with `4` and `5043`/`5887` start with `5`,
    /// yet must resolve to `.mada` (DESIGN §5.3).
    static let madaPrefixes: Set<String> = [
        "4464", "4968", "5043", "5887", "6220", "6240", "6280", "9682",
    ]

    /// Reproduces `detectCardType` exactly, including rule order.
    public static func detectCardType(_ number: String) -> CardType {
        let cleaned = number.filter { !$0.isWhitespace }
        if cleaned.isEmpty { return .unknown }

        if cleaned.count >= 4 {
            let firstFour = String(cleaned.prefix(4))
            if madaPrefixes.contains(firstFour) { return .mada }
        }
        if cleaned.hasPrefix("4") { return .visa }
        if cleaned.hasPrefix("5") { return .mastercard }
        if cleaned.count >= 4, let firstFour = Int(cleaned.prefix(4)),
           (2221...2720).contains(firstFour) {
            return .mastercard // Mastercard 2-series BIN range
        }
        return .unknown
    }

    // MARK: Card number

    /// Luhn check (right-to-left doubling with `(n%10)+1` reduction; valid when `sum % 10 == 0`).
    /// Accepts ASCII `0`–`9` only. Empty input is invalid (`sum == 0` must not pass).
    public static func luhnValid(_ digits: String) -> Bool {
        if digits.isEmpty { return false }
        var sum = 0
        var alternate = false
        for ch in digits.reversed() {
            guard ch.isASCII, let d = ch.wholeNumberValue, (0...9).contains(d) else { return false }
            var n = d
            if alternate {
                n *= 2
                if n > 9 { n = (n % 10) + 1 }
            }
            sum += n
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    /// `validateCardNumber`: strip whitespace, require 13–19 digits, then Luhn.
    public static func validateCardNumber(_ input: String) -> Bool {
        let stripped = input.filter { !$0.isWhitespace }
        guard stripped.range(of: "^[0-9]{13,19}$", options: .regularExpression) != nil else {
            return false
        }
        return luhnValid(stripped)
    }

    /// `formatCardNumber`: ASCII digits only, capped at 19, grouped uniformly 4-4-4-4.
    public static func formatCardNumber(_ input: String) -> String {
        let digits = asciiDigits(in: input, limit: 19)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i != 0 && i % 4 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// ASCII `0`–`9` only — Unicode numeric characters are not PAN/expiry/CVV digits.
    static func asciiDigits(in input: String, limit: Int) -> String {
        String(input.filter { $0.isASCII && $0.isNumber }.prefix(limit))
    }

    // MARK: Expiry

    /// `formatExpiry`: digits only, capped at 4, `/` auto-inserted after 2 → `MM/YY`.
    public static func formatExpiry(_ input: String) -> String {
        let digits = asciiDigits(in: input, limit: 4)
        if digits.count > 2 {
            let mm = digits.prefix(2)
            let yy = digits.dropFirst(2)
            return "\(mm)/\(yy)"
        }
        return digits
    }

    /// `validateExpiry`: exactly `MM/YY`, `1..12` month, 2-digit-year comparison vs now.
    /// Current month is valid (`>=`); strictly past is invalid; no upper bound; no century
    /// disambiguation — matching the web SDK precisely. `now`/`calendar` are injectable for tests.
    /// Shared calendar for the default expiry check — avoids allocating a `Calendar` on every
    /// keystroke. Still overridable via the `calendar:` parameter for tests. Public because it
    /// backs a default argument on a public method.
    public static let gregorian = Calendar(identifier: .gregorian)

    public static func validateExpiry(
        _ expiry: String,
        now: Date = Date(),
        calendar: Calendar = CardValidation.gregorian
    ) -> Bool {
        guard expiry.range(of: "^[0-9]{2}/[0-9]{2}$", options: .regularExpression) != nil else {
            return false
        }
        let parts = expiry.split(separator: "/")
        guard parts.count == 2, let month = Int(parts[0]), let year = Int(parts[1]) else {
            return false
        }
        guard month >= 1, month <= 12 else { return false }

        let comps = calendar.dateComponents([.year, .month], from: now)
        let currentYear = (comps.year ?? 0) % 100
        let currentMonth = comps.month ?? 0
        if year == currentYear { return month >= currentMonth }
        return year >= currentYear
    }

    // MARK: CVV

    /// `validateCVV`: 3 or 4 digits, brand-independent (no Amex-4 rule).
    public static func validateCVV(_ cvv: String) -> Bool {
        cvv.range(of: "^[0-9]{3,4}$", options: .regularExpression) != nil
    }

    /// Sanitize CVV input: digits only, capped at 4.
    public static func sanitizeCVV(_ input: String) -> String {
        asciiDigits(in: input, limit: 4)
    }
}
