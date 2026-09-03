import Foundation

/// A single network request the SDK made, surfaced for debugging / observability.
///
/// Bodies are redacted by default (IOS-011). Enable via `Lite.isRequestLoggingEnabled`.
public struct LiteRequestLog: Identifiable, Sendable {
    public let id: UUID
    public let method: String
    public let url: String
    public let requestBody: String?
    public let statusCode: Int?
    public let responseBody: String?
    public let error: String?
    public let durationMs: Int

    public init(
        id: UUID = UUID(),
        method: String,
        url: String,
        requestBody: String? = nil,
        statusCode: Int? = nil,
        responseBody: String? = nil,
        error: String? = nil,
        durationMs: Int
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.error = error
        self.durationMs = durationMs
    }
}

/// Callback the networking layer invokes after every request completes (success or failure).
public typealias LiteRequestLogHandler = @Sendable (LiteRequestLog) -> Void
