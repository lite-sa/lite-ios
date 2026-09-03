import Foundation

/// Lite-owned HTTPS destinations. Host must be exactly `lite.sa` or a subdomain
/// (`*.lite.sa`). Parsed as a real URL so suffix tricks such as `lite.sa.evil.com` fail.
enum LiteDestinationAllowlist {
    private static let rootHost = "lite.sa"

    static func isAllowed(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              url.user == nil
        else { return false }
        return host == rootHost || host.hasSuffix(".\(rootHost)")
    }
}
