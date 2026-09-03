// swift-tools-version: 5.9
import PackageDescription

// LiteSDK — native iOS SDK for Lite Checkout (Path B: truly-native card fields).
// See ../DESIGN.md for the full design. Core + Crypto build on the macOS host;
// LiteSDKUI (card fields + Apple Pay) is real on iOS via `#if canImport(UIKit)`.
let package = Package(
    name: "LiteSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13), // enables `swift test` on the host while iOS UI is not yet in scope
    ],
    products: [
        // The umbrella product merchants depend on — `import LiteSDK`.
        .library(name: "LiteSDK", targets: ["LiteSDK"]),
        .library(name: "LiteSDKCore", targets: ["LiteSDKCore"]),
        .library(name: "LiteSDKCrypto", targets: ["LiteSDKCrypto"]),
        .library(name: "LiteSDKUI", targets: ["LiteSDKUI"]),
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
        .testTarget(
            name: "LiteSDKCoreTests",
            dependencies: ["LiteSDKCore"]
        ),
        .testTarget(
            name: "LiteSDKCryptoTests",
            dependencies: ["LiteSDKCrypto", "LiteSDKCore"]
        ),
    ]
)
