import XCTest
@testable import LiteSDKCore

final class ApplePayConfigTests: XCTestCase {

    func testMajorUnitAmountDividesMinorUnitsBy100() {
        XCTAssertEqual(ApplePayConfig.majorUnitAmount(minorUnits: 15099), Decimal(string: "150.99"))
        XCTAssertEqual(ApplePayConfig.majorUnitAmount(minorUnits: 100), Decimal(1))
        XCTAssertEqual(ApplePayConfig.majorUnitAmount(minorUnits: 0), Decimal(0))
    }

    func testParsesSupportedNetworks() {
        let networks = ApplePayConfig.networks(from: ["visa", "masterCard", "MADA", "amex", "discover", "unknown"])
        XCTAssertEqual(networks, [.visa, .masterCard, .mada, .amex, .discover])
    }

    func testParsesMasterCardAliases() {
        XCTAssertEqual(ApplePayConfig.Network.parse("mastercard"), .masterCard)
        XCTAssertEqual(ApplePayConfig.Network.parse("master_card"), .masterCard)
        XCTAssertEqual(ApplePayConfig.Network.parse("masterCard"), .masterCard)
    }

    func testParsesMerchantCapabilities() {
        let caps = ApplePayConfig.capabilities(from: [
            "supports3DS", "supportsCredit", "supportsDebit", "supportsEMV", "nope"
        ])
        XCTAssertEqual(caps, [.threeDSecure, .credit, .debit, .emv])
    }

    func testParsesMerchantCapabilitiesCaseInsensitively() {
        let caps = ApplePayConfig.capabilities(from: [
            "SUPPORTS3DS", "supportscredit", "SupportsDebit", "supportsEmv"
        ])
        XCTAssertEqual(caps, [.threeDSecure, .credit, .debit, .emv])
        XCTAssertEqual(ApplePayConfig.Capability.parse("supports3ds"), .threeDSecure)
        XCTAssertEqual(ApplePayConfig.Capability.parse("supports3DS"), .threeDSecure)
    }

    func testResolveSupportedNetworksUsesAliases() {
        let networks = CardNetworks(visa: true, mastercard: false, mada: true)
        let filtered = ApplePayConfig.resolveSupportedNetworks(
            applePayNetworks: ["visa", "master_card", "mada", "amex"],
            cardNetworks: networks
        )
        XCTAssertEqual(filtered, ["visa", "mada", "amex"])
    }
}
