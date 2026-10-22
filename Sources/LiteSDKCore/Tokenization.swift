import Foundation

// MARK: - Result

/// Status of `Lite.tokenize()`. There is no `processing`: tokenizing never authorizes or polls.
public enum TokenizeStatus: String, Sendable, Equatable {
    case success
    case failure
}

/// Why `tokenize()` returned no instrument (web `TokenizeErrorCode`).
public enum TokenizeErrorCode {
    /// Called on a payment session; only a tokenization session can tokenize on its own.
    /// Also the `PayResult.errorCode` of a payment refused on a tokenization session.
    public static let sessionTypeUnsupported = "session_type_unsupported"
    /// The session already tokenized a card; it allows one. Create a new session for another.
    public static let sessionConsumed = "session_consumed"
    /// The session ran out before the request; create a new one.
    public static let sessionExpired = "session_expired"
    /// This session has no key to encrypt a card with, or its cards are switched off (`INACTIVE`).
    public static let cardNotConfigured = "card_not_configured"
    /// The API refused or could not be reached; `apiErrorCode` carries its code when it gave one.
    /// The session can still be retried.
    public static let tokenizeFailed = "tokenize_failed"
}

/// Result of `Lite.tokenize()` (web `TokenizeResult`). On `success`, `instrument` is set; on
/// `failure`, `errorCode` names why (`TokenizeErrorCode`) and `apiErrorCode` carries the API's own
/// `errors[0].code` when it answered with one.
public struct TokenizeResult: Sendable, Equatable {
    public let status: TokenizeStatus
    public let instrument: LiteInstrument?
    public let error: String?
    public let errorCode: String?
    public let apiErrorCode: String?
    public var isSuccess: Bool { status == .success }

    public init(
        status: TokenizeStatus,
        instrument: LiteInstrument? = nil,
        error: String? = nil,
        errorCode: String? = nil,
        apiErrorCode: String? = nil
    ) {
        self.status = status
        self.instrument = instrument
        self.error = error
        self.errorCode = errorCode
        self.apiErrorCode = apiErrorCode
    }

    static func failure(_ errorCode: String, _ error: String, apiErrorCode: String? = nil) -> TokenizeResult {
        TokenizeResult(status: .failure, error: error, errorCode: errorCode, apiErrorCode: apiErrorCode)
    }
}

// MARK: - Coordinator

/// Runs `Lite.tokenize()` (web `Lite.tokenize` + `LiteCardAggregator.tokenize`): refuses what
/// cannot tokenize, then sends the card exactly as `pay()` does, without authorizing or polling.
///
/// A session tokenizes one card. A refused request does not count, so the customer can correct the
/// card and retry; `reset()` (a new session) allows another. Concurrent calls share the request in
/// flight, as `pay()` does.
@MainActor
package final class TokenizeCoordinator {
    private var isConsumed = false
    private var inFlight: Task<TokenizeResult, Never>?
    /// Bumped by `reset()`, so a request that outlives its session cannot consume the next one.
    private var generation = 0

    package init() {}

    /// Forget the consumed session and cancel a tokenization in flight. Called on `start` / `reset`.
    package func reset() {
        inFlight?.cancel()
        inFlight = nil
        isConsumed = false
        generation += 1
    }

    /// `encrypt` turns the session's public key into the card JWE; it runs only after every
    /// refusal has passed, so a refused call never reads the card.
    package func tokenize(
        started: SessionService.StartedSession?,
        storeForFuture: Bool,
        urlSession: URLSession = .shared,
        logHandler: LiteRequestLogHandler? = nil,
        encrypt: @escaping @MainActor (_ publicKey: String) throws -> String
    ) async -> TokenizeResult {
        if let inFlight {
            return await inFlight.value
        }
        guard let started else {
            return .failure(TokenizeErrorCode.tokenizeFailed, LiteError.notStarted.customerSafeMessage)
        }
        if let refusal = refusal(for: started.session) {
            return refusal
        }
        // `refusal` checked the key is there.
        let publicKey = started.session.cardPublicKey ?? ""

        let task = Task { @MainActor [self] in
            await self.send(
                started: started,
                publicKey: publicKey,
                storeForFuture: storeForFuture,
                urlSession: urlSession,
                logHandler: logHandler,
                encrypt: encrypt
            )
        }
        inFlight = task
        let result = await task.value
        if inFlight == task {
            inFlight = nil
        }
        return result
    }

    /// Why `tokenize()` cannot start, checked before the card is collected; nil when it can
    /// (web `LiteSession.refuseTokenize`). A payment session tokenizes inside `pay()`.
    package func refusal(for session: LiteCheckoutSession) -> TokenizeResult? {
        guard session.isTokenization else {
            return .failure(
                TokenizeErrorCode.sessionTypeUnsupported,
                "Only a tokenization session can tokenize on its own; a payment session tokenizes inside pay()."
            )
        }
        if isConsumed {
            return .failure(
                TokenizeErrorCode.sessionConsumed,
                "This session already tokenized a card; create a new session for another."
            )
        }
        // The key is all a tokenization needs; the session may send the card method without a status.
        guard session.cardPublicKey?.isEmpty == false else {
            return .failure(TokenizeErrorCode.cardNotConfigured, "This session has no key to encrypt a card with.")
        }
        // An explicit INACTIVE switches cards off, as it stops the web SDK's card fields mounting.
        if session.paymentMethods.card?.status == .inactive {
            return .failure(TokenizeErrorCode.cardNotConfigured, "Cards are not active on this session.")
        }
        return nil
    }

    private func send(
        started: SessionService.StartedSession,
        publicKey: String,
        storeForFuture: Bool,
        urlSession: URLSession,
        logHandler: LiteRequestLogHandler?,
        encrypt: @MainActor (String) throws -> String
    ) async -> TokenizeResult {
        let generation = self.generation
        do {
            try Task.checkCancellation()
            let jwe = try encrypt(publicKey)
            let service = PaymentService(started: started, urlSession: urlSession, logHandler: logHandler)
            let instrument = try await service.createInstrument(
                paymentMethod: .card,
                data: jwe,
                storeForFuture: storeForFuture
            )
            guard !instrument.id.isEmpty else {
                return .failure(TokenizeErrorCode.tokenizeFailed, "Failed to create instrument")
            }
            if generation == self.generation {
                isConsumed = true
            }
            return TokenizeResult(status: .success, instrument: instrument)
        } catch is CancellationError {
            return .failure(TokenizeErrorCode.tokenizeFailed, "cancelled")
        } catch {
            return Self.failure(error)
        }
    }

    private static func failure(_ error: Error) -> TokenizeResult {
        guard let lite = error as? LiteError else {
            return .failure(
                TokenizeErrorCode.tokenizeFailed,
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        // The API refuses an expired token at the gateway (401) or the session service (403).
        if case .http(let status, _) = lite, status == 401 || status == 403 {
            return .failure(
                TokenizeErrorCode.sessionExpired,
                "The session has expired; create a new one.",
                apiErrorCode: lite.apiErrorCode
            )
        }
        return .failure(TokenizeErrorCode.tokenizeFailed, lite.customerSafeMessage, apiErrorCode: lite.apiErrorCode)
    }
}
