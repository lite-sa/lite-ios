import Foundation

/// API error codes and user-facing copy mirrored from the web checkout pay button
/// (`PAYMENT_METHOD_NOT_SUPPORTED` + toaster / pay lock).
public enum LiteAPIError {
    public static let paymentMethodNotSupported = "PAYMENT_METHOD_NOT_SUPPORTED"

    public static let unsupportedPaymentMethodMessage =
        "This payment method is not supported. Please try a different card."

    /// First `errors[0].code` from a Lite API JSON error body, if present
    /// (web `getApiErrorCode`).
    public static func errorCode(fromHTTPBody body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let code = errors.first?["code"] as? String,
              !code.isEmpty
        else { return nil }
        return code
    }
}
