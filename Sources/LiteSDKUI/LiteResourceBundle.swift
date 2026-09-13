#if canImport(UIKit)
import Foundation

/// Resolves the LiteSDKUI resource bundle for both SwiftPM (`Bundle.module`) and CocoaPods.
enum LiteResourceBundle {
    static let current: Bundle = {
        #if SWIFT_PACKAGE
        return .module
        #else
        let candidates = [
            Bundle(for: Lite.self),
            Bundle.main,
        ]
        for candidate in candidates {
            if let url = candidate.url(forResource: "LiteSDKUI", withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
            if let url = candidate.url(forResource: "LiteSDK_LiteSDKUI", withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle(for: Lite.self)
        #endif
    }()
}
#endif
