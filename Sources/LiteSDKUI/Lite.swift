#if canImport(UIKit)
import Foundation
import Combine
import LiteSDKCore
import LiteSDKCrypto
#if canImport(PassKit)
import PassKit
#endif

/// The single entry point a merchant integrates against.
///
/// `Lite` is stateful: it holds the checkout session, tracks card-field validity, and runs the whole
/// payment internally — the merchant never sees the public key, the ciphertext, or the network calls.
/// Create one (`@StateObject var lite = Lite()`), `start(clientSecret:)` to load the session, bind the
/// card fields to it, then call `pay()` — or `tokenize()` on a tokenization session, which saves the
/// card without paying.
@MainActor
public final class Lite: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case loadingSession
        case ready
        case paying
        case failed(String)
    }

    /// Which card payment path is active — mirrors the web checkout `selectedMethod` state.
    public enum CardPaymentSelection: Equatable {
        case newCard
        case storedInstrument(id: String)
    }

    /// Result of `pay()` / sheet present. Merchants branch on `status`
    /// (`success` / `failure` / `processing` / `cancelled` / `already_completed`).
    /// `already_completed` is an opened session whose payment was already captured — not a new pay.
    /// `errorCode` matches web (`errors[0].code`).
    public struct PayResult: Sendable, Equatable {
        public let status: PaymentOperationStatus
        public let paymentId: String?
        public let error: String?
        public let errorCode: String?
        public var isSuccess: Bool { status == .success }
        public var isCancelled: Bool { status == .cancelled }
        public var isAlreadyCompleted: Bool { status == .alreadyCompleted }

        public init(
            status: PaymentOperationStatus,
            paymentId: String?,
            error: String?,
            errorCode: String? = nil
        ) {
            self.status = status
            self.paymentId = paymentId
            self.error = error
            self.errorCode = errorCode
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var session: LiteCheckoutSession?
    @Published public private(set) var lastPayResult: PayResult?
    @Published internal private(set) var isThreeDSActive = false
    @Published public var cardSelection: CardPaymentSelection = .newCard
    @Published public var storeForFuture = false

    /// True after `PAYMENT_METHOD_NOT_SUPPORTED` until the card number changes (web `isPayLocked`).
    @Published public private(set) var isPayLocked = false

    /// Banner copy while pay is locked for an unsupported card scheme.
    public var payLockMessage: String? {
        isPayLocked ? LiteAPIError.unsupportedPaymentMethodMessage : nil
    }

    /// When `false` (default), network request bodies are not published to `requestLog` (IOS-011).
    /// Set `true` only in debug builds for local diagnostics — bodies remain redacted.
    public var isRequestLoggingEnabled = false

    /// Log of network requests the SDK has made (for debugging / observability). Reset on `start`.
    /// Bodies are redacted; logging is off unless `isRequestLoggingEnabled` is set.
    @Published public private(set) var requestLog: [LiteRequestLog] = []

    /// True when the required new-card fields are all currently valid.
    public var isComplete: Bool { aggregator.isComplete }

    /// True when `pay()` can be invoked — an instrument selected (and not a listed one whose scheme is
    /// off), or new-card fields complete. New-card brand is not gated client-side; the server rejects
    /// unsupported schemes.
    public var isReadyToPay: Bool {
        guard !isPayLocked else { return false }
        switch cardSelection {
        case .storedInstrument(let id):
            return canPayWithInstrument(id)
        case .newCard:
            return aggregator.isComplete
        }
    }

    /// Whether Apple Pay should be shown — mirrors hosted checkout + web `ApplePayButton.isAvailable()`:
    /// - session `payment_methods.applePay.status === 'ACTIVE'`
    /// - `canMakePayments(usingNetworks:)` for session networks (IOS-024)
    /// Cached per session so PassKit is not queried on every card-field keystroke.
    @Published public private(set) var isApplePayAvailable = false

    /// Session-only check (web checkout `payment_methods?.applePay?.status === 'ACTIVE'`).
    /// False on a tokenization session, which has nothing to pay.
    public var isApplePayEnabledInSession: Bool {
        guard session?.isTokenization != true else { return false }
        return session?.paymentMethods.applePay?.status == .active
    }

    private let aggregator = LiteCardAggregator()
    private let tokenizer = TokenizeCoordinator()
    private let threeDS: ThreeDSecurePresenting
    private var started: SessionService.StartedSession?
    private var cancellables: Set<AnyCancellable> = []
    /// Coalesces concurrent `pay*` calls onto one in-flight task (web / IOS-003).
    private var inFlightPay: Task<PayResult, Never>?
    internal static let threeDSChallengeDismissedErrorCode = "THREE_DS_CHALLENGE_DISMISSED"

    public init() {
        self.threeDS = WKWebViewThreeDS()
        aggregator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        aggregator.onCardNumberEdited = { [weak self] in
            self?.unlockPay()
        }
    }

    /// Stored card instruments for the current session (web `lite.getStoredInstruments('card')`).
    /// Each item includes `enabled` from `payment_methods.card.networks`.
    /// Pass `enabledOnly: true` to only receive selectable instruments.
    public func getStoredInstruments(
        paymentMethod: String = "card",
        enabledOnly: Bool = false
    ) -> [StoredInstrument] {
        guard paymentMethod == "card" else { return [] }
        // Empty on a MOTO or tokenization session (`storedCardInstruments`).
        let instruments = session?.storedCardInstruments ?? []
        if enabledOnly {
            return instruments.filter(\.enabled)
        }
        return instruments
    }

    /// Card schemes enabled on this session (`payment_methods.card.networks`).
    /// When `networks` is omitted, returns all known schemes.
    public func getEnabledCardNetworks() -> [CardNetwork] {
        CardNetworks.enabledNetworks(in: session?.paymentMethods.card?.networks)
    }

    /// Whether a card scheme is enabled on the session (`payment_methods.card.networks`).
    /// When `networks` is omitted, every scheme is treated as enabled.
    public func isCardSchemeEnabled(_ scheme: String?) -> Bool {
        CardNetworks.isSchemeEnabled(scheme, networks: session?.paymentMethods.card?.networks)
    }

    /// Select an instrument for the next `pay()` call: a saved card from `getStoredInstruments()`, or
    /// any other id, such as one `tokenize()` returned. No-ops for a listed card whose scheme is disabled.
    public func selectStoredInstrument(_ id: String) {
        guard canPayWithInstrument(id) else { return }
        unlockPay()
        cardSelection = .storedInstrument(id: id)
    }

    /// Whether `pay(instrumentId:)` may send this id. Never on a MOTO session: the API rejects a
    /// stored instrument's future-usage agreement with MOTO, which is why the session lists none.
    private func canPayWithInstrument(_ id: String) -> Bool {
        !id.isEmpty && !isMotoSession && !isListedButDisabled(id)
    }

    private var isMotoSession: Bool { session?.processingType == "MOTO" }

    /// A saved card the session lists, whose scheme the session turned off. An id the session
    /// doesn't list, such as a tokenized one, is the API's to accept or refuse.
    private func isListedButDisabled(_ id: String) -> Bool {
        getStoredInstruments().first(where: { $0.id == id })?.enabled == false
    }

    /// Select the new-card entry path for the next `pay()` call.
    public func selectNewCard() {
        unlockPay()
        cardSelection = .newCard
    }

    /// Start the SDK with the merchant's `clientSecret` (the session JWT). Fetches the session and
    /// exposes it via `session`; on failure `phase` becomes `.failed(message)`.
    public func start(clientSecret: String) async {
        inFlightPay?.cancel()
        inFlightPay = nil
        tokenizer.reset()
        // Forget the previous session first, so nothing pays or tokenizes against it while the
        // replacement loads, or after it fails to.
        started = nil
        phase = .loadingSession
        session = nil
        lastPayResult = nil
        isThreeDSActive = false
        cardSelection = .newCard
        storeForFuture = false
        isPayLocked = false
        isApplePayAvailable = false
        requestLog.removeAll()
        do {
            let started = try await SessionService.fetchSession(clientSecret: clientSecret, logHandler: makeLogHandler())
            self.started = started
            self.session = started.session
            refreshApplePayAvailability()
            let opened = try await SessionService.classifyOpenedCheckout(
                started: started,
                logHandler: makeLogHandler()
            )
            if case let .terminal(status, paymentId, error) = opened {
                lastPayResult = PayResult(status: status, paymentId: paymentId, error: error)
            }
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            self.started = nil
            phase = .failed(Self.message(error))
        }
    }

    /// Register a UIKit `LiteCardField`. Returns false when another field of this type is already live.
    @discardableResult
    func register(_ field: LiteCardField) -> Bool {
        aggregator.register(field)
    }

    /// Remember [field]'s text before a window detach wipes the display.
    func retainField(_ field: LiteCardField) {
        aggregator.retain(field)
    }

    func dropRetainedField(_ type: CardElementType) {
        aggregator.dropRetained(type)
    }

    func retainedFieldValue(_ type: CardElementType) -> String {
        aggregator.retainedValue(for: type)
    }

    /// Unregister a field and drop its stored text. Permanent disposal.
    func unregister(_ field: LiteCardField) {
        aggregator.unregister(field, keepingValue: false)
    }

    /// Unregister a field but keep its stored text for the next attach.
    func unregisterKeepingValue(_ field: LiteCardField) {
        aggregator.unregister(field, keepingValue: true)
    }

    /// Focus the field that follows [type], when that field is registered.
    func focusField(after type: CardElementType) {
        aggregator.focusField(after: type)
    }

    /// Reset the SDK to its initial state: drops the session, request log, and any collected card
    /// fields, and returns `phase` to `.idle`. Use it to restart the checkout flow.
    public func reset() {
        inFlightPay?.cancel()
        inFlightPay = nil
        tokenizer.reset()
        started = nil
        session = nil
        lastPayResult = nil
        isThreeDSActive = false
        cardSelection = .newCard
        storeForFuture = false
        isPayLocked = false
        isApplePayAvailable = false
        requestLog.removeAll()
        aggregator.reset()
        phase = .idle
    }

    /// Pay using the current UI selection (`cardSelection` + `storeForFuture`).
    public func pay() async -> PayResult {
        switch cardSelection {
        case .storedInstrument(let id):
            return await pay(instrumentId: id)
        case .newCard:
            return await pay(storeForFuture: storeForFuture)
        }
    }

    /// Pay with a new card (web `{ payment_method: 'card', store_for_future? }`).
    public func pay(storeForFuture: Bool = false) async -> PayResult {
        await withPayIdempotency { [self] in
            await self.payNewCard(storeForFuture: storeForFuture)
        }
    }

    /// Pay with an instrument (web `{ instrument_id }` — skips tokenize): a saved card, or any other id,
    /// such as one `tokenize()` returned on a tokenization session.
    public func pay(instrumentId: String) async -> PayResult {
        await withPayIdempotency { [self] in
            await self.payStoredInstrument(instrumentId: instrumentId)
        }
    }

    /// Pay with an Apple Pay token JSON string (web `createInstrument('applePay', JSON.stringify(token))`).
    /// Called by `LiteApplePayButton` — merchants should use the button, not this method directly.
    ///
    /// `afterAuthorize` (PassKit only): invoked after tokenize+authorize, **before** poll/3DS.
    /// The button uses it to call PassKit `completion` and wait until the Apple Pay sheet
    /// has dismissed. Lite's success/failure result is not emitted until poll/3DS finish.
    /// Direct callers omit it and run the full pipeline in one shot.
    public func payWithApplePay(
        tokenJSON: String,
        afterAuthorize: (@MainActor (_ passKitSuccess: Bool) async -> Void)? = nil
    ) async -> PayResult {
        await withPayIdempotency { [self] in
            await self.payApplePay(tokenJSON: tokenJSON, afterAuthorize: afterAuthorize)
        }
    }

    /// Tokenize the card in the card fields without paying, on a tokenization session (web
    /// `lite.tokenize`). Never authorizes and never polls. Returns the instrument, or why there is
    /// none; it does not throw for a card or session that cannot be tokenized.
    ///
    /// A session tokenizes one card: a failed attempt can be retried, a successful one cannot.
    /// A second call while one is in flight gets the same result.
    public func tokenize(storeForFuture: Bool = false) async -> TokenizeResult {
        await tokenizer.tokenize(
            started: started,
            storeForFuture: storeForFuture,
            logHandler: makeLogHandler()
        ) { [aggregator] publicKey in
            // The same collect + encrypt as `payNewCard`: the card goes to the API as `pay()`
            // sends it, and whether it is accepted is the API's call.
            guard aggregator.isComplete else {
                throw LiteError.fieldsIncomplete(LiteCardAggregator.requiredFields)
            }
            return try aggregator.encrypt(base64WrappedPEMPublicKey: publicKey)
        }
    }

    /// Clear the request log.
    public func clearLog() { requestLog.removeAll() }

    /// Whether a `pay*` call is currently running (used by the payment sheet lifecycle).
    public var hasInFlightPay: Bool { inFlightPay != nil }

    /// Awaits the current in-flight pay task, if any. Returns `lastPayResult` when nothing is in flight.
    public func awaitInFlightPay() async -> PayResult? {
        if let inFlightPay {
            return await inFlightPay.value
        }
        return lastPayResult
    }

    /// Cancels the in-flight pay task (poll/sleep will abort). Prefer awaiting the result via
    /// `awaitInFlightPay()` after cancel when the merchant needs a terminal `PayResult`.
    public func cancelInFlightPay() {
        inFlightPay?.cancel()
    }

    // MARK: - Pay internals

    private func withPayIdempotency(_ work: @escaping @MainActor () async -> PayResult) async -> PayResult {
        if let existing = inFlightPay {
            return await existing.value
        }
        let task = Task { @MainActor in
            await work()
        }
        inFlightPay = task
        let result = await task.value
        if inFlightPay == task {
            inFlightPay = nil
        }
        return result
    }

    private func payNewCard(storeForFuture: Bool) async -> PayResult {
        guard let started else { return failure(LiteError.notStarted) }
        // Before the card is read: tokenizing first would leave an instrument behind for a
        // payment that cannot happen.
        if started.session.isTokenization {
            return Self.sessionTypeUnsupportedResult
        }
        guard started.session.paymentMethods.card?.status == .active else {
            return failure(LiteError.cardNotActive)
        }
        guard let publicKey = started.session.cardPublicKey else { return failure(LiteError.cardNotConfigured) }
        guard aggregator.isComplete else {
            return failure(LiteError.fieldsIncomplete(LiteCardAggregator.requiredFields))
        }

        phase = .paying
        // Do not `aggregator.reset()` here. Web and Android keep the PAN on
        // `PAYMENT_METHOD_NOT_SUPPORTED` so the in-sheet error can show; clearing also
        // fired `onCardNumberEdited` and immediately unlocked pay.
        defer { if case .paying = phase { phase = .ready } }

        do {
            try Task.checkCancellation()
            let jwe = try aggregator.encrypt(base64WrappedPEMPublicKey: publicKey)
            let service = PaymentService(started: started, logHandler: makeLogHandler())
            let instrument = try await service.createInstrument(
                paymentMethod: .card,
                data: jwe,
                storeForFuture: storeForFuture
            )
            guard !instrument.id.isEmpty else {
                return recordFailure("Failed to create instrument")
            }
            return try await authorizeAndPoll(instrumentId: instrument.id, service: service)
        } catch is CancellationError {
            return cancelledResult()
        } catch {
            return recordPayFailure(error)
        }
    }

    private func payStoredInstrument(instrumentId: String) async -> PayResult {
        guard let started else { return failure(LiteError.notStarted) }
        if started.session.isTokenization {
            return Self.sessionTypeUnsupportedResult
        }
        guard started.session.paymentMethods.card?.status == .active else {
            return failure(LiteError.cardNotActive)
        }
        guard !instrumentId.isEmpty else {
            return failure(LiteError.decoding("instrument_id is required"))
        }
        if started.session.processingType == "MOTO" {
            return failure(LiteError.decoding("A MOTO session can't be paid with an instrument"))
        }
        if isListedButDisabled(instrumentId) {
            return failure(LiteError.decoding("Card scheme is not enabled for this session"))
        }

        phase = .paying
        defer { if case .paying = phase { phase = .ready } }

        do {
            try Task.checkCancellation()
            let service = PaymentService(started: started, logHandler: makeLogHandler())
            return try await authorizeAndPoll(instrumentId: instrumentId, service: service)
        } catch is CancellationError {
            return cancelledResult()
        } catch {
            return recordPayFailure(error)
        }
    }

    private func payApplePay(
        tokenJSON: String,
        afterAuthorize: (@MainActor (Bool) async -> Void)?
    ) async -> PayResult {
        guard let started else {
            await afterAuthorize?(false)
            return failure(LiteError.notStarted)
        }
        // Before the token is sent, so no Apple Pay instrument is left behind.
        if started.session.isTokenization {
            await afterAuthorize?(false)
            return Self.sessionTypeUnsupportedResult
        }
        guard let method = started.session.paymentMethods.applePay else {
            await afterAuthorize?(false)
            return failure(LiteError.applePayNotConfigured)
        }
        guard method.status == .active else {
            await afterAuthorize?(false)
            return failure(LiteError.applePayNotActive)
        }
        guard !tokenJSON.isEmpty else {
            await afterAuthorize?(false)
            return failure(LiteError.decoding("Apple Pay token is required"))
        }

        phase = .paying
        defer { if case .paying = phase { phase = .ready } }

        let service = PaymentService(started: started, logHandler: makeLogHandler())
        do {
            try Task.checkCancellation()
            let instrument = try await service.createInstrument(
                paymentMethod: .applePay,
                data: tokenJSON,
                storeForFuture: false
            )
            guard !instrument.id.isEmpty else {
                await afterAuthorize?(false)
                return recordFailure("Failed to create instrument")
            }
            try await authorizePayment(instrumentId: instrument.id, service: service)
        } catch is CancellationError {
            await afterAuthorize?(false)
            return cancelledResult()
        } catch {
            await afterAuthorize?(false)
            return recordPayFailure(error)
        }
        await afterAuthorize?(true)
        do {
            return try await pollAndPresentThreeDS(service: service)
        } catch is CancellationError {
            return cancelledResult()
        } catch {
            return recordPayFailure(error)
        }
    }

    // MARK: - Payment pipeline

    private func authorizeAndPoll(instrumentId: String, service: PaymentService) async throws -> PayResult {
        try await authorizePayment(instrumentId: instrumentId, service: service)
        return try await pollAndPresentThreeDS(service: service)
    }

    private func authorizePayment(instrumentId: String, service: PaymentService) async throws {
        try Task.checkCancellation()
        var device = DeviceInfo.collect()
        device.ip = await PublicIPService.fetchPublicIP(logHandler: makeLogHandler())
        try Task.checkCancellation()
        _ = try await service.authorize(instrumentId: instrumentId, device: device)
    }

    private func pollAndPresentThreeDS(service: PaymentService) async throws -> PayResult {
        var handled = Set<String>()
        var result = try await service.pollPayment(handledActions: handled)
        while result.status == .processing,
              let redirect = result.payment?.nextAction?.redirect,
              let url = URL(string: redirect.url) {
            try Task.checkCancellation()
            // Same-URL guard (web `handledActions` + Android `url in handled`). No count cap.
            if handled.contains(redirect.url) { break }
            handled.insert(redirect.url)
            do {
                try await presentThreeDS(redirectURL: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch ThreeDSPresentationError.challengeDismissed {
                return PayResult(
                    status: .cancelled,
                    paymentId: result.payment?.payment.id,
                    error: "cancelled",
                    errorCode: Self.threeDSChallengeDismissedErrorCode
                )
            } catch is ThreeDSURLValidator.ValidationError {
                return recordFailure(
                    LiteError.threeDSInvalidURL.errorDescription ?? "3DS challenge URL must use HTTPS."
                )
            } catch LiteError.threeDSTimeout {
                return recordFailure(LiteError.threeDSTimeout.customerSafeMessage)
            }
            try Task.checkCancellation()
            result = try await service.pollPayment(handledActions: handled)
        }

        let payResult = PayResult(
            status: result.status,
            paymentId: result.payment?.payment.id,
            error: result.error
        )
        lastPayResult = payResult
        if payResult.isSuccess {
            aggregator.reset()
        }
        await refreshSession()
        return payResult
    }

    /// Android `THREE_DS_TIMEOUT_MS` (10 minutes). Timeout is a pay failure, not cancellation.
    private static let threeDSTimeoutNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    private func presentThreeDS(redirectURL url: URL) async throws {
        isThreeDSActive = true
        defer { isThreeDSActive = false }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await self.threeDS.present(redirectURL: url)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.threeDSTimeoutNanoseconds)
                throw LiteError.threeDSTimeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func cancelledResult() -> PayResult {
        // Prefer a completed outcome if pay already finished before cancel took effect (IOS-005).
        if let last = lastPayResult, last.status != .cancelled {
            return last
        }
        let payResult = PayResult(status: .cancelled, paymentId: lastPayResult?.paymentId, error: "cancelled")
        lastPayResult = payResult
        return payResult
    }

    private func recordFailure(
        _ message: String,
        paymentId: String? = nil,
        errorCode: String? = nil
    ) -> PayResult {
        let payResult = PayResult(
            status: .failure,
            paymentId: paymentId,
            error: message,
            errorCode: errorCode
        )
        lastPayResult = payResult
        return payResult
    }

    /// Maps thrown errors; locks pay on `PAYMENT_METHOD_NOT_SUPPORTED` (web pay-button toaster path).
    private func recordPayFailure(_ error: Error) -> PayResult {
        let code = (error as? LiteError)?.apiErrorCode
        if code == LiteAPIError.paymentMethodNotSupported {
            lockPay()
            return recordFailure(LiteAPIError.unsupportedPaymentMethodMessage, errorCode: code)
        }
        return recordFailure(Self.message(error), errorCode: code)
    }

    private func lockPay() {
        isPayLocked = true
    }

    private func unlockPay() {
        guard isPayLocked else { return }
        isPayLocked = false
    }

    /// Re-fetch the checkout session so stored instruments and status reflect post-payment state.
    private func refreshSession() async {
        guard let started else { return }
        do {
            let updated = try await SessionService.refreshSession(
                started: started,
                logHandler: makeLogHandler()
            )
            session = updated
            self.started = SessionService.StartedSession(
                clientSecret: started.clientSecret,
                claims: started.claims,
                endpoints: started.endpoints,
                session: updated
            )
            refreshApplePayAvailability()
        } catch {
            // Non-fatal — `lastPayResult` still carries the authoritative payment outcome.
        }
    }

    private func makeLogHandler() -> LiteRequestLogHandler? {
        guard isRequestLoggingEnabled else { return nil }
        return { [weak self] entry in
            Task { @MainActor in self?.requestLog.append(entry) }
        }
    }

    /// What every pay path, the Payment Sheet and the embeddable form return on a tokenization
    /// session (web `refusePaymentOnTokenization`). Not recorded as `lastPayResult`: nothing was paid.
    static let sessionTypeUnsupportedResult = PayResult(
        status: .failure,
        paymentId: nil,
        error: LiteError.sessionTypeUnsupported.merchantMessage,
        errorCode: TokenizeErrorCode.sessionTypeUnsupported
    )

    /// The result the Payment Sheet and embeddable form complete with instead of rendering the
    /// pay UI; nil on a payment session.
    var paymentUIRefusal: PayResult? {
        guard session?.isTokenization == true else { return nil }
        return Self.sessionTypeUnsupportedResult
    }

    private func failure(_ error: LiteError) -> PayResult {
        PayResult(
            status: .failure,
            paymentId: nil,
            error: Self.message(error),
            errorCode: error.apiErrorCode
        )
    }

    private static func message(_ error: Error) -> String {
        if let lite = error as? LiteError {
            return lite.customerSafeMessage
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func refreshApplePayAvailability() {
        #if canImport(PassKit)
        guard isApplePayEnabledInSession else {
            isApplePayAvailable = false
            return
        }
        let networks = applePayPKNetworks()
        isApplePayAvailable = networks.isEmpty
            ? PKPaymentAuthorizationController.canMakePayments()
            : PKPaymentAuthorizationController.canMakePayments(usingNetworks: networks)
        #else
        isApplePayAvailable = false
        #endif
    }

    #if canImport(PassKit)
    private func applePayPKNetworks() -> [PKPaymentNetwork] {
        guard let session else { return [] }
        let config = session.paymentMethods.applePay?.config
        let raw = ApplePayConfig.resolveSupportedNetworks(
            applePayNetworks: config?.supportedNetworks,
            cardNetworks: session.paymentMethods.card?.networks
        )
        return ApplePayConfig.networks(from: raw).compactMap { PKPaymentNetwork($0) }
    }
    #endif
}
#endif
