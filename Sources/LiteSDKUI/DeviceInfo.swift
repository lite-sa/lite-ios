#if canImport(UIKit)
import UIKit
import LiteSDKCore

/// Builds the `Device` block sent with the authorize request from native signals.
///
/// The web collects a *browser* fingerprint (canvas/webgl/audio/fonts) which has no native
/// equivalent (DESIGN §5.8). We populate the same wire shape with native values, put structured
/// attributes in `device_data`, and use the vendor identifier as `device_fingerprint`.
@MainActor
enum DeviceInfo {
    static func collect() -> Device {
        let screen = UIScreen.main
        let pixels = screen.nativeBounds
        let language = Locale.preferredLanguages.first ?? Locale.current.identifier
        // Match JS `Date.getTimezoneOffset()` sign convention: minutes of (UTC - local).
        let timezoneOffsetMinutes = -(TimeZone.current.secondsFromGMT() / 60)
        let device = UIDevice.current
        let idfv = device.identifierForVendor?.uuidString
        let userAgent = "LiteSDK-iOS/1.0 (\(device.model); iOS \(device.systemVersion))"

        var deviceData: [String: String] = [
            "platform": "ios",
            "model": device.model,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "localized_model": device.localizedModel,
            "user_interface_idiom": idiomLabel(device.userInterfaceIdiom),
            "screen_scale": String(Double(screen.scale)),
        ]
        if let idfv {
            deviceData["identifier_for_vendor"] = idfv
        }

        return Device(
            ip: nil,
            userAgent: userAgent,
            acceptHeader: "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            language: language,
            screenHeight: Int(pixels.height),
            screenWidth: Int(pixels.width),
            colorDepth: 24,
            timezone: timezoneOffsetMinutes,
            javaEnabled: false,
            javaScriptEnabled: true,
            deviceFingerprint: idfv,
            deviceData: deviceData
        )
    }

    private static func idiomLabel(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: return "phone"
        case .pad: return "pad"
        case .mac: return "mac"
        case .tv: return "tv"
        case .carPlay: return "carPlay"
        case .vision: return "vision"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }
}
#endif
