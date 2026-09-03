import Foundation

/// HTML / `postMessage` origin serialization (`scheme://host` or `scheme://host:port`).
///
/// Default ports are omitted (`https` 443, `http` 80) so the string matches `event.origin`.
/// Scheme and host are lowercased to match browser origin ASCII serialization.
package enum HTMLOrigin {
    package static func serialized(for url: URL) -> String? {
        serialized(scheme: url.scheme, host: url.host, port: url.port)
    }

    package static func serialized(scheme: String?, host: String?, port: Int?) -> String? {
        guard let scheme = scheme?.lowercased(), !scheme.isEmpty,
              let host = host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if let port, port > 0 {
            let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefault {
                return "\(scheme)://\(host):\(port)"
            }
        }
        return "\(scheme)://\(host)"
    }
}

/// http(s) URLs the SDK may hand to `UIApplication.open`. Rejects `javascript:`, custom schemes, and hostless URLs.
package enum LiteHTTPURL {
    package static func parse(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
