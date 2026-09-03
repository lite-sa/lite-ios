import XCTest
@testable import LiteSDKCore

final class CardValidationTests: XCTestCase {

    // MARK: Brand detection (order-sensitive)

    func testMadaBinsBeatVisaAndMastercardPrefixes() {
        // 4464/4968 start with '4' (visa prefix) but must be mada.
        XCTAssertEqual(CardValidation.detectCardType("4464000000000000"), .mada)
        XCTAssertEqual(CardValidation.detectCardType("4968 0000 0000 0000"), .mada)
        // 5043/5887 start with '5' (mastercard prefix) but must be mada.
        XCTAssertEqual(CardValidation.detectCardType("5043000000000000"), .mada)
        XCTAssertEqual(CardValidation.detectCardType("5887000000000000"), .mada)
        // 6xxx mada bins
        XCTAssertEqual(CardValidation.detectCardType("6220000000000000"), .mada)
    }

    func testVisaMastercardAndTwoSeries() {
        XCTAssertEqual(CardValidation.detectCardType("4111111111111111"), .visa)
        XCTAssertEqual(CardValidation.detectCardType("5111111111111111"), .mastercard)
        XCTAssertEqual(CardValidation.detectCardType("2221000000000000"), .mastercard)
        XCTAssertEqual(CardValidation.detectCardType("2720000000000000"), .mastercard)
        XCTAssertEqual(CardValidation.detectCardType("2221"), .mastercard) // 2-series lower bound (4 digits)
        XCTAssertEqual(CardValidation.detectCardType("2720"), .mastercard) // 2-series upper bound (4 digits)
        XCTAssertEqual(CardValidation.detectCardType("2721000000000000"), .unknown) // just above 2-series
    }

    func testUnknownAndShortInputs() {
        XCTAssertEqual(CardValidation.detectCardType(""), .unknown)
        XCTAssertEqual(CardValidation.detectCardType("3782"), .unknown) // amex not supported
        XCTAssertEqual(CardValidation.detectCardType("2220000000000000"), .unknown) // just below 2-series
        // startsWith fires from the first digit for visa/mastercard
        XCTAssertEqual(CardValidation.detectCardType("4"), .visa)
        XCTAssertEqual(CardValidation.detectCardType("5"), .mastercard)
    }

    // MARK: Luhn + validation

    func testLuhnAndCardNumberValidation() {
        XCTAssertFalse(CardValidation.luhnValid(""))
        XCTAssertFalse(CardValidation.luhnValid("٤١١١١١١١١١١١١١١١"))
        XCTAssertTrue(CardValidation.luhnValid("4111111111111111"))
        XCTAssertFalse(CardValidation.luhnValid("4111111111111112"))
        XCTAssertTrue(CardValidation.validateCardNumber("4111 1111 1111 1111"))
        XCTAssertFalse(CardValidation.validateCardNumber("4111 1111 1111 1112"))
        XCTAssertFalse(CardValidation.validateCardNumber("411111")) // too short (<13)
    }

    func testFormatCardNumberGrouping() {
        XCTAssertEqual(CardValidation.formatCardNumber("4111111111111111"), "4111 1111 1111 1111")
        XCTAssertEqual(CardValidation.formatCardNumber("41111"), "4111 1")
        XCTAssertEqual(CardValidation.formatCardNumber("4111"), "4111")
        // capped at 19 digits (17–19 PANs must not be truncated before Luhn)
        XCTAssertEqual(CardValidation.formatCardNumber("4111111111111111110"), "4111 1111 1111 1111 110")
        XCTAssertEqual(CardValidation.formatCardNumber("41111111111111111109999"), "4111 1111 1111 1111 110")
        // strips non-digits
        XCTAssertEqual(CardValidation.formatCardNumber("4a1b1c1"), "4111")
    }

    // MARK: Expiry

    func testExpiryFormatting() {
        XCTAssertEqual(CardValidation.formatExpiry("1"), "1")
        XCTAssertEqual(CardValidation.formatExpiry("12"), "12")
        XCTAssertEqual(CardValidation.formatExpiry("123"), "12/3")
        XCTAssertEqual(CardValidation.formatExpiry("1230"), "12/30")
        XCTAssertEqual(CardValidation.formatExpiry("12309"), "12/30") // capped at 4 digits
    }

    func testExpiryValidationEdges() {
        // Fixed "now" = 2026-07 (matches the conversation's currentDate).
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!

        XCTAssertTrue(CardValidation.validateExpiry("07/26", now: now, calendar: cal))  // current month → valid
        XCTAssertTrue(CardValidation.validateExpiry("12/26", now: now, calendar: cal))  // later this year
        XCTAssertTrue(CardValidation.validateExpiry("01/30", now: now, calendar: cal))  // future year
        XCTAssertFalse(CardValidation.validateExpiry("06/26", now: now, calendar: cal)) // last month → invalid
        XCTAssertFalse(CardValidation.validateExpiry("12/25", now: now, calendar: cal)) // past year
        XCTAssertFalse(CardValidation.validateExpiry("13/30", now: now, calendar: cal)) // bad month
        XCTAssertFalse(CardValidation.validateExpiry("1/30", now: now, calendar: cal))  // not MM/YY
        XCTAssertFalse(CardValidation.validateExpiry("12/2030", now: now, calendar: cal)) // 4-digit year rejected
    }

    // MARK: CVV

    func testCVV() {
        XCTAssertTrue(CardValidation.validateCVV("123"))
        XCTAssertTrue(CardValidation.validateCVV("1234"))
        XCTAssertFalse(CardValidation.validateCVV("12"))
        XCTAssertFalse(CardValidation.validateCVV("12345"))
        XCTAssertFalse(CardValidation.validateCVV("12a"))
        XCTAssertEqual(CardValidation.sanitizeCVV("1a2b3c4d5"), "1234")
    }
}
