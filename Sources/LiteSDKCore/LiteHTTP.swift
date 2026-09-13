import Foundation

/// Small JSON HTTP helper mirroring the web `liteFetch`: 30s timeout, `Bearer` auth,
/// `Content-Type: application/json`, snake_case request bodies, non-2xx → `LiteError.http`.
/// Emits a `LiteRequestLog` after every request when a `logHandler` is provided.
struct LiteHTTP {
    let urlSession: URLSession
    var timeout: TimeInterval = 30
    let logHandler: LiteRequestLogHandler?

    /// Configured once and reused — `JSONEncoder`/`JSONDecoder` are safe for concurrent
    /// encode/decode, and `pollPayment` alone issues 20+ requests per payment.
    static let snakeCaseEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    private static let decoder = JSONDecoder()

    init(urlSession: URLSession = .shared, logHandler: LiteRequestLogHandler? = nil) {
        self.urlSession = urlSession
        self.logHandler = logHandler
    }

    func get<T: Decodable>(urlString: String, bearer: String, as type: T.Type) async throws -> T {
        try await send(urlString: urlString, method: "GET", bearer: bearer, body: nil, as: type)
    }

    func post<B: Encodable, T: Decodable>(urlString: String, bearer: String, body: B, as type: T.Type) async throws -> T {
        let data = try Self.snakeCaseEncoder.encode(body)
        return try await send(urlString: urlString, method: "POST", bearer: bearer, body: data, as: type)
    }

    private func send<T: Decodable>(
        urlString: String,
        method: String,
        bearer: String,
        body: Data?,
        as _: T.Type
    ) async throws -> T {
        guard LiteDestinationAllowlist.isAllowed(urlString) else {
            throw LiteError.malformedSessionURL
        }
        guard let url = URL(string: urlString) else { throw LiteError.malformedSessionURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let start = Date()
        var status: Int?
        var responseText: String?
        var errorText: String?
        defer {
            // Redact bodies by default (IOS-011) — lengths only, never JWE / PII payloads.
            logHandler?(LiteRequestLog(
                method: method,
                url: Self.redactedURL(urlString),
                requestBody: body.map { "[redacted \( $0.count ) bytes]" },
                statusCode: status,
                responseBody: responseText.map { "[redacted \( $0.count ) chars]" },
                error: errorText,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            ))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            errorText = "cancelled"
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            errorText = "cancelled"
            throw CancellationError()
        } catch {
            errorText = error.localizedDescription
            throw LiteError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            errorText = "Non-HTTP response."
            throw LiteError.transport("Non-HTTP response.")
        }
        status = http.statusCode
        responseText = String(data: data, encoding: .utf8)

        guard (200..<300).contains(http.statusCode) else {
            errorText = "HTTP \(http.statusCode)"
            throw LiteError.http(status: http.statusCode, body: responseText)
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            errorText = "decode failed"
            throw LiteError.decoding("decode failed")
        }
    }

    private static func redactedURL(_ urlString: String) -> String {
        // Keep path; strip query strings that might carry tokens.
        guard var components = URLComponents(string: urlString) else { return urlString }
        if components.query != nil {
            components.query = nil
            components.percentEncodedQuery = nil
            return (components.string ?? urlString) + "?[redacted]"
        }
        return urlString
    }
}
