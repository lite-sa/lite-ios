import XCTest
@testable import LiteSDKCore

final class LiteCardFieldStateTests: XCTestCase {
    func testEmptyRequiredFieldIsInvalidWithoutError() {
        let change = LiteCardFieldState.resolve(
            type: .cardNumber,
            isEmpty: true,
            formatValid: false,
            brand: .unknown,
            focused: false
        )
        XCTAssertFalse(change.valid)
        XCTAssertNil(change.error)
        XCTAssertNil(change.message)
        XCTAssertEqual(change.brand, .unknown)
    }

    func testInvalidNumberDoesNotReportScheme() {
        let change = LiteCardFieldState.resolve(
            type: .cardNumber,
            isEmpty: false,
            formatValid: false,
            brand: .visa,
            focused: true
        )
        XCTAssertFalse(change.valid)
        XCTAssertEqual(change.error, .invalidNumber)
        XCTAssertEqual(change.message, LiteFieldCopy.message(for: .invalidNumber))
        XCTAssertTrue(change.focused)
    }

    func testDisabledSchemeDoesNotBlockAValidNumber() {
        let change = LiteCardFieldState.resolve(
            type: .cardNumber,
            isEmpty: false,
            formatValid: true,
            brand: .mada,
            focused: false
        )
        XCTAssertTrue(change.valid)
        XCTAssertNil(change.error)
        XCTAssertNil(change.message)
        XCTAssertEqual(change.brand, .mada)
    }

    func testNameHasNoError() {
        let change = LiteCardFieldState.resolve(
            type: .cardholderName,
            isEmpty: true,
            formatValid: true,
            brand: .unknown,
            focused: false
        )
        XCTAssertTrue(change.valid)
        XCTAssertNil(change.error)
    }

    func testNonNumberFieldDoesNotReportBrand() {
        let change = LiteCardFieldState.resolve(
            type: .cvv,
            isEmpty: false,
            formatValid: false,
            brand: .visa,
            focused: false
        )
        XCTAssertEqual(change.error, .invalidCvv)
        XCTAssertEqual(change.brand, .unknown)
    }

    func testCopyAndCutBlockedForPanAndCvv() {
        XCTAssertFalse(LiteFieldClipboard.allowsCopyOrCut(.cardNumber))
        XCTAssertFalse(LiteFieldClipboard.allowsCopyOrCut(.cvv))
        XCTAssertTrue(LiteFieldClipboard.allowsCopyOrCut(.expiry))
        XCTAssertTrue(LiteFieldClipboard.allowsCopyOrCut(.cardholderName))
    }

    func testAccessibilityValueIsBrandOrError() {
        XCTAssertEqual(LiteFieldCopy.accessibilityValue(brand: .visa, error: nil), "Visa")
        XCTAssertEqual(
            LiteFieldCopy.accessibilityValue(brand: .visa, error: .invalidNumber),
            "Incorrect card number"
        )
        XCTAssertEqual(LiteFieldCopy.label(for: .cardNumber), "Card number")
        XCTAssertEqual(LiteFieldCopy.placeholder(for: .cardNumber), "1234 1234 1234 1234 123")
        XCTAssertEqual(LiteFieldCopy.placeholder(for: .cardholderName), "Name on card")
        XCTAssertFalse(LiteFieldCopy.accessibilityValue(brand: .unknown, error: nil).contains("4111"))
    }

    func testSecondOwnerDoesNotReplaceTheFirst() {
        let table = FieldOwnerTable()
        let first = NSObject()
        let second = NSObject()
        XCTAssertTrue(table.claim(.cardNumber, owner: first))
        XCTAssertFalse(table.claim(.cardNumber, owner: second))
        XCTAssertTrue(table.claim(.cardNumber, owner: first))
        table.release(.cardNumber, owner: first)
        XCTAssertTrue(table.claim(.cardNumber, owner: second))
    }

    func testPublicFieldSurfaceDoesNotExposeCardText() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LiteSDKUI", isDirectory: true)
        let files = ["LiteCardFieldHost.swift", "LiteCardFieldView.swift", "LiteCardField.swift", "LiteFieldStyle.swift"]
        for name in files {
            let text = try String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("public") else { continue }
                XCTAssertFalse(trimmed.contains("rawValue"), name)
                XCTAssertFalse(trimmed.contains("textField"), name)
                XCTAssertFalse(trimmed.contains("cardNumber:"), name)
            }
        }
    }
}
