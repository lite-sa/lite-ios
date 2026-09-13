import Foundation

/// Supplies `device.ip` for authorize — matches the web SDK placeholder
/// (`packages/device-fingerprint/src/index.ts`).
///
/// A device behind NAT cannot know its public IP without a network echo; we deliberately do **not**
/// call a third-party service (e.g. ipify) and send the same hardcoded value the web client sends.
public enum PublicIPService {

    /// Value the web SDK hardcodes for `device.ip`.
    public static let placeholderIP = "196.136.41.119"

    public static func fetchPublicIP(
        urlSession _: URLSession = .shared,
        logHandler _: LiteRequestLogHandler? = nil
    ) async -> String {
        placeholderIP
    }
}
