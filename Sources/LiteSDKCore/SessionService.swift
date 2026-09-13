import Foundation

/// Errors surfaced by the SDK's networking / session layer.
public enum LiteError: Error, LocalizedError {
    case invalidClientSecret
    case malformedSessionURL
    case http(status: Int, body: String?)
    case decoding(String)
    case transport(String)
    case cardNotConfigured
    case cardNotActive
    case applePayNotConfigured
    case applePayNotActive
    case threeDSInvalidURL
    case threeDSTimeout
    case fieldsIncomplete([CardElementType])
    case notStarted

    public var errorDescription: String? { customerSafeMessage }

    /// Merchant / poll diagnostics. Never includes HTTP bodies or decode payloads.
    public var merchantMessage: String {
        switch self {
        case .invalidClientSecret:   return "The client secret is not a valid session token."
        case .malformedSessionURL:   return "Could not build the session URL from the token issuer."
        case .http(let status, _):   return "Server returned HTTP \(status)."
        case .decoding:              return "Could not read the session response."
        case .transport(let detail): return "Network error: \(detail)"
        case .cardNotConfigured:     return "Card payments are not enabled for this session."
        case .cardNotActive:         return "Card payments are not active for this session."
        case .applePayNotConfigured: return "Apple Pay is not configured."
        case .applePayNotActive:     return "Apple Pay is not active."
        case .threeDSInvalidURL:     return "3DS challenge URL must use HTTPS."
        case .threeDSTimeout:        return "We could not verify this payment in time. Please try again."
        case .fieldsIncomplete:      return "Card details are incomplete."
        case .notStarted:            return "The SDK has not been started with a client secret."
        }
    }

    /// Customer-facing copy. Never includes HTTP bodies, decode payloads, or transport internals.
    public var customerSafeMessage: String {
        switch self {
        case .invalidClientSecret, .malformedSessionURL, .notStarted:
            return "Checkout is unavailable. Please try again."
        case .http, .decoding:
            return "Something went wrong. Please try again."
        case .transport:
            return "We could not connect. Please check your connection and try again."
        case .cardNotConfigured, .cardNotActive:
            return "Card payments are unavailable. Please try a different payment method."
        case .applePayNotConfigured, .applePayNotActive:
            return "Apple Pay is unavailable. Please try a different payment method."
        case .threeDSInvalidURL:
            return "We could not verify this payment. Please try again."
        case .threeDSTimeout:
            return "We could not verify this payment in time. Please try again."
        case .fieldsIncomplete:
            return "Please complete your card details."
        }
    }

    /// First API `errors[0].code` when this is an HTTP error with a JSON body.
    public var apiErrorCode: String? {
        guard case .http(_, let body) = self else { return nil }
        return LiteAPIError.errorCode(fromHTTPBody: body)
    }
}

extension LiteError: CustomStringConvertible {
    /// `String(describing:)` must not dump HTTP bodies or decode detail.
    public var description: String {
        switch self {
        case .http(let status, _): return "Http(status=\(status))"
        case .decoding: return "Decoding()"
        case .transport: return "Transport()"
        case .invalidClientSecret: return "InvalidClientSecret"
        case .malformedSessionURL: return "MalformedSessionURL"
        case .cardNotConfigured: return "CardNotConfigured"
        case .cardNotActive: return "CardNotActive"
        case .applePayNotConfigured: return "ApplePayNotConfigured"
        case .applePayNotActive: return "ApplePayNotActive"
        case .threeDSInvalidURL: return "ThreeDSInvalidURL"
        case .threeDSTimeout: return "ThreeDSTimeout"
        case .fieldsIncomplete: return "FieldsIncomplete"
        case .notStarted: return "NotStarted"
        }
    }
}

/// Fetches and decodes the checkout session from the `clientSecret` (the session JWT).
///
/// The `clientSecret` IS the raw JWT: its `iss`/`sessionId` claims determine the endpoint, and it
/// is sent as the `Authorization: Bearer` credential (matching the web SDK). Signature is not
/// verified locally (see `JWTDecoder`).
public enum SessionService {

    public struct StartedSession: Sendable {
        public let clientSecret: String
        public let claims: LiteJWTClaims
        public let endpoints: LiteEndpoints
        public let session: LiteCheckoutSession

        public init(clientSecret: String, claims: LiteJWTClaims, endpoints: LiteEndpoints, session: LiteCheckoutSession) {
            self.clientSecret = clientSecret
            self.claims = claims
            self.endpoints = endpoints
            self.session = session
        }
    }

    public static func fetchSession(
        clientSecret: String,
        urlSession: URLSession = .shared,
        logHandler: LiteRequestLogHandler? = nil
    ) async throws -> StartedSession {
        let claims: LiteJWTClaims
        do {
            claims = try JWTDecoder.decodeClaims(clientSecret)
        } catch {
            throw LiteError.invalidClientSecret
        }

        let endpoints = LiteEndpoints(iss: claims.iss)
        guard let url = endpoints.sessionURL(sessionId: claims.sessionId) else {
            throw LiteError.malformedSessionURL
        }

        let http = LiteHTTP(urlSession: urlSession, logHandler: logHandler)
        let session = try await http.get(
            urlString: url.absoluteString,
            bearer: clientSecret,
            as: LiteCheckoutSession.self
        )
        return StartedSession(
            clientSecret: clientSecret,
            claims: claims,
            endpoints: endpoints,
            session: session
        )
    }

    /// One GET of `_links.payment` (no poll). Used when the checkout session is already completed.
    package static func fetchPayment(
        started: StartedSession,
        urlSession: URLSession = .shared,
        logHandler: LiteRequestLogHandler? = nil
    ) async throws -> PaymentResponse {
        let http = LiteHTTP(urlSession: urlSession, logHandler: logHandler)
        return try await http.get(
            urlString: started.session.links.payment.href,
            bearer: started.clientSecret,
            as: PaymentResponse.self
        )
    }

    /// After a session GET: `pending` → show the form; `failed` → error result;
    /// `completed` → GET `links.payment` once and map success to already-paid (Android A36).
    package static func classifyOpenedCheckout(
        started: StartedSession,
        urlSession: URLSession = .shared,
        logHandler: LiteRequestLogHandler? = nil
    ) async throws -> OpenedCheckout {
        switch CheckoutSessionStatus.fromWire(started.session.status) {
        case .pending:
            return .showForm
        case .failed:
            return .terminal(
                status: .failure,
                paymentId: nil,
                error: CheckoutSessionStatus.sessionFailedMessage
            )
        case .completed:
            let payment: PaymentResponse.Payment
            do {
                payment = try await fetchPayment(
                    started: started,
                    urlSession: urlSession,
                    logHandler: logHandler
                ).payment
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .terminal(
                    status: .failure,
                    paymentId: nil,
                    error: Self.openedCheckoutFailureMessage(error)
                )
            }
            if payment.status.operationStatus == .success {
                return .terminal(
                    status: .alreadyCompleted,
                    paymentId: payment.id,
                    error: CheckoutSessionStatus.alreadyCompletedMessage
                )
            }
            return .terminal(
                status: .failure,
                paymentId: payment.id.isEmpty ? nil : payment.id,
                error: payment.status == .unknown
                    ? PaymentStatus.unknownStatusMessage
                    : CheckoutSessionStatus.sessionFailedMessage
            )
        }
    }

    private static func openedCheckoutFailureMessage(_ error: Error) -> String {
        if let lite = error as? LiteError {
            return lite.customerSafeMessage
        }
        return (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Please try again."
    }

    /// Re-fetch the session document from `_links.self` (used after `pay()` to refresh UI state).
    public static func refreshSession(
        started: StartedSession,
        urlSession: URLSession = .shared,
        logHandler: LiteRequestLogHandler? = nil
    ) async throws -> LiteCheckoutSession {
        let http = LiteHTTP(urlSession: urlSession, logHandler: logHandler)
        return try await http.get(
            urlString: started.session.links.selfLink.href,
            bearer: started.clientSecret,
            as: LiteCheckoutSession.self
        )
    }
}

/// Result of gating a fetched checkout session (Android `OpenedCheckout`).
package enum OpenedCheckout: Equatable {
    case showForm
    case terminal(status: PaymentOperationStatus, paymentId: String?, error: String?)
}
