import Foundation

/// The payment state machine — a faithful port of the web `LiteSession` pay flow
/// (`packages/sdk/src/session/index.ts`): createInstrument (tokenize) → authorize → poll, with
/// the 3DS redirect loop driven by the caller (`Lite.pay`, which owns the UI presenter).
public struct PaymentService {

    private let started: SessionService.StartedSession
    private let http: LiteHTTP

    public init(
        started: SessionService.StartedSession,
        urlSession: URLSession = .shared,
        logHandler: LiteRequestLogHandler? = nil
    ) {
        self.started = started
        self.http = LiteHTTP(urlSession: urlSession, logHandler: logHandler)
    }

    private var session: LiteCheckoutSession { started.session }
    private var clientSecret: String { started.clientSecret }

    // MARK: createInstrument (tokenize)

    /// POST `session._links.tokenize.href` with the encrypted card `data` (the JWE).
    public func createInstrument(paymentMethod: String, data jwe: String, storeForFuture: Bool) async throws -> LiteInstrument {
        guard let holderId = session.customer?.id else {
            throw LiteError.decoding("Session is missing customer.id (required to tokenize).")
        }
        let body = CreateInstrumentRequest(
            holderId: holderId,
            paymentMethod: paymentMethod,
            holderType: "CUSTOMER",
            data: jwe,
            futureUsage: storeForFuture ? "unscheduled" : nil
        )
        return try await http.post(
            urlString: session.links.tokenize.href,
            bearer: clientSecret,
            body: body,
            as: LiteInstrument.self
        )
    }

    // MARK: authorize (pay)

    /// POST `session._links.authorize.href`. Throws if the response has no `payment.id`
    /// (web `'Payment ID is not found'`).
    public func authorize(instrumentId: String, device: Device) async throws -> PaymentResponse {
        let response = try await http.post(
            urlString: session.links.authorize.href,
            bearer: clientSecret,
            body: buildPaymentRequest(instrumentId: instrumentId, device: device),
            as: PaymentResponse.self
        )
        guard !response.payment.id.isEmpty else {
            throw LiteError.decoding("Payment ID is not found")
        }
        return response
    }

    // MARK: pollPayment

    /// GET `session._links.payment.href` on a fixed ~1s interval, up to 20 attempts (matching the
    /// web poller — `backoffMultiplier` defaults to 1, so there is no real backoff). Resolves when
    /// the status is terminal, or when a *new* (unhandled) 3DS redirect appears, or — on exhaustion
    /// — with `PROCESSING` + the standard message.
    ///
    /// Propagates `CancellationError` so an aborted `pay()` stops polling promptly.
    public func pollPayment(handledActions: Set<String>) async throws -> PaymentPollingResult {
        let maxRetries = 20
        var lastError: Error?
        for attempt in 1...maxRetries {
            try Task.checkCancellation()
            do {
                let response = try await http.get(
                    urlString: session.links.payment.href,
                    bearer: clientSecret,
                    as: PaymentResponse.self
                )
                let status = response.payment.status

                if PaymentStatus.finalStatuses.contains(status) {
                    let error = status == .unknown ? PaymentStatus.unknownStatusMessage : nil
                    return PaymentPollingResult(status: status.operationStatus, payment: response, error: error)
                }

                if status == .requiresAction || status == .pending,
                   let url = response.nextAction?.redirect?.url,
                   !handledActions.contains(url) {
                    // Stop for a new action — surface to the caller to present 3DS.
                    return PaymentPollingResult(status: .processing, payment: response)
                }
                // Not terminal, no new action — fall through and retry.
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }

            if attempt < maxRetries {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s — throws on cancel
            }
        }
        return PaymentPollingResult(
            status: .processing,
            error: Self.paymentNotCompletedError(lastError: lastError)
        )
    }

    private static let paymentNotCompletedMessage =
        "Payment not completed yet, Please wait for a confirmation message."

    private static func paymentNotCompletedError(lastError: Error?) -> String {
        let detail: String?
        if let lite = lastError as? LiteError {
            detail = lite.merchantMessage
        } else {
            detail = lastError?.localizedDescription
        }
        guard let detail, !detail.isEmpty else { return paymentNotCompletedMessage }
        return "\(paymentNotCompletedMessage) \(detail)"
    }

    // MARK: request building

    private func buildPaymentRequest(instrumentId: String, device: Device) -> LitePaymentRequest {
        let customer = session.customer
        let orderBilling = session.order?.billingAddress

        // Prefer customer billing when present; otherwise keep order.billing_address
        // (web spreads `session.order` first so that address is retained).
        let billing: LitePaymentRequest.BillingAddress?
        if let cba = customer?.billingAddress {
            let fullName = [customer?.firstName, customer?.lastName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            billing = LitePaymentRequest.BillingAddress(
                name: fullName.isEmpty ? orderBilling?.name : fullName,
                email: customer?.email ?? orderBilling?.email,
                street: cba.line1 ?? orderBilling?.street,
                city: cba.city ?? orderBilling?.city,
                state: cba.state ?? orderBilling?.state,
                country: cba.country ?? orderBilling?.country,
                zip: cba.postalCode ?? orderBilling?.zip
            )
        } else if let orderBilling {
            billing = LitePaymentRequest.BillingAddress(
                name: orderBilling.name,
                email: orderBilling.email,
                street: orderBilling.street,
                city: orderBilling.city,
                state: orderBilling.state,
                country: orderBilling.country,
                zip: orderBilling.zip
            )
        } else {
            billing = nil
        }

        let order = LitePaymentRequest.OrderBody(
            reference: session.orderId ?? "",
            amount: session.order?.amount,
            currency: session.order?.currency,
            description: session.order?.description,
            billingAddress: billing
        )

        let customerBody = LitePaymentRequest.CustomerBody(
            id: customer?.id ?? "",
            email: customer?.email,
            firstName: customer?.firstName,
            lastName: customer?.lastName,
            phoneCountryCode: customer?.phoneCountryCode,
            phoneNumber: customer?.phoneNumber
        )

        return LitePaymentRequest(
            amount: session.amount,
            currency: session.currency,
            processing: .init(processingType: "REGULAR"),
            order: order,
            captureOptions: .init(captureMode: "INSTANT"),
            paymentInstrument: .init(id: instrumentId),
            customer: customerBody,
            channelId: started.claims.channelId ?? session.channelId,
            device: device
        )
    }
}
