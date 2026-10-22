// swift-tools-version: 5.9
import PackageDescription

// LiteSDK — native iOS SDK for Lite Checkout (Path B: truly-native card fields).
// Core + Crypto build on the macOS host; LiteSDKUI (card fields + Apple Pay)
// is real on iOS via `#if canImport(UIKit)`.
let package = Package(
    name: "LiteSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13), // enables `swift test` on the host while iOS UI is not yet in scope
    ],
    products: [
        // The only product, and deliberately so. Core, Crypto and UI stay
        // targets: vending them would let a merchant `import LiteSDKCrypto`
        // and make every public symbol in them API we cannot change. One
        // umbrella keeps the supported surface to `import LiteSDK`.
        .library(name: "LiteSDK", targets: ["LiteSDK"]),
    ],
    targets: [
        // Umbrella: re-exports Core + UI so a single `import LiteSDK` is enough.
        .target(
            name: "LiteSDK",
            dependencies: ["LiteSDKCore", "LiteSDKUI"]
        ),
        .target(name: "LiteSDKCore"),
        .target(
            name: "LiteSDKCrypto",
            dependencies: ["LiteSDKCore"]
        ),
        // UIKit/SwiftUI card fields. Source is gated with `#if canImport(UIKit)`, so it
        // compiles to nothing on the macOS host (keeping `swift test` green) and is real on iOS.
        .target(
            name: "LiteSDKUI",
            dependencies: ["LiteSDKCore", "LiteSDKCrypto"],
            resources: [.process("Resources")]
        ),
        // The fake network the test targets share. Not a product, so it never ships.
        .target(
            name: "LiteSDKTestSupport",
            path: "Tests/LiteSDKTestSupport"
        ),
        .testTarget(
            name: "LiteSDKCoreTests",
            dependencies: ["LiteSDKCore", "LiteSDKTestSupport"]
        ),
        .testTarget(
            name: "LiteSDKCryptoTests",
            dependencies: ["LiteSDKCrypto", "LiteSDKCore"]
        ),
        // `Lite` itself. Gated like LiteSDKUI, so it is empty under `swift test` on the macOS
        // host and runs on an iOS simulator (`xcodebuild test`).
        .testTarget(
            name: "LiteSDKUITests",
            dependencies: ["LiteSDKUI", "LiteSDKCore", "LiteSDKCrypto", "LiteSDKTestSupport"]
        ),
    ]
)
