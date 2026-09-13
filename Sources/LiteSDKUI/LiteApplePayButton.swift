#if canImport(UIKit) && canImport(PassKit)
import Foundation
import PassKit
import SwiftUI
import UIKit
import LiteSDKCore

/// Native counterpart of web `ApplePayButton` (`packages/sdk/src/elements/apple-pay/index.ts`).
///
/// Renders only when the session has `payment_methods.applePay.status == ACTIVE` **and**
/// `PKPaymentAuthorizationController.canMakePayments()` (web: `ApplePaySession.canMakePayments()`).
/// Owns its own payment flow — do not route Apple Pay through `lite.pay()`.
public struct LiteApplePayButton: View {
    @ObservedObject private var lite: Lite
    private let buttonType: PKPaymentButtonType
    private let buttonStyle: PKPaymentButtonStyle
    private let onResult: (Lite.PayResult) -> Void

    public init(
        _ lite: Lite,
        type: PKPaymentButtonType = .buy,
        style: PKPaymentButtonStyle = .black,
        onResult: @escaping (Lite.PayResult) -> Void
    ) {
        self.lite = lite
        self.buttonType = type
        self.buttonStyle = style
        self.onResult = onResult
    }

    public var body: some View {
        // Web `mount()` silently no-ops when `isAvailable()` is false.
        if lite.isApplePayAvailable {
            ApplePayButtonRepresentable(
                lite: lite,
                buttonType: buttonType,
                buttonStyle: buttonStyle,
                onResult: onResult
            )
            .frame(maxWidth: .infinity)
            .frame(height: LiteTheme.expressButtonHeight)
            .clipShape(RoundedRectangle(cornerRadius: LiteTheme.Radii.express, style: .continuous))
        }
    }
}

// MARK: - UIKit bridge

private struct ApplePayButtonRepresentable: UIViewRepresentable {
    let lite: Lite
    let buttonType: PKPaymentButtonType
    let buttonStyle: PKPaymentButtonStyle
    let onResult: (Lite.PayResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(lite: lite, onResult: onResult)
    }

    func makeUIView(context: Context) -> PKPaymentButton {
        let button = PKPaymentButton(paymentButtonType: buttonType, paymentButtonStyle: buttonStyle)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cornerRadius = LiteTheme.Radii.express
        return button
    }

    func updateUIView(_ uiView: PKPaymentButton, context: Context) {
        context.coordinator.lite = lite
        context.coordinator.onResult = onResult
        uiView.cornerRadius = LiteTheme.Radii.express
    }

    final class Coordinator: NSObject, PKPaymentAuthorizationControllerDelegate {
        var lite: Lite
        var onResult: (Lite.PayResult) -> Void
        private var controller: PKPaymentAuthorizationController?
        /// Resumed from `didFinish` after PassKit dismisses — poll/3DS must not start while the sheet is up.
        private var passKitDidFinish = false
        private var passKitFinishWaiter: CheckedContinuation<Void, Never>?

        init(lite: Lite, onResult: @escaping (Lite.PayResult) -> Void) {
            self.lite = lite
            self.onResult = onResult
        }

        @objc func tapped() {
            guard controller == nil else { return }
            Task { @MainActor in
                do {
                    let request = try makePaymentRequest()
                    let controller = PKPaymentAuthorizationController(paymentRequest: request)
                    controller.delegate = self
                    self.controller = controller
                    self.passKitDidFinish = false
                    self.passKitFinishWaiter = nil
                    let presented = await controller.present()
                    if !presented {
                        onResult(Lite.PayResult(
                            status: .failure,
                            paymentId: nil,
                            error: "Unable to present Apple Pay"
                        ))
                        self.controller = nil
                    }
                } catch {
                    onResult(Lite.PayResult(
                        status: .failure,
                        paymentId: nil,
                        error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    ))
                }
            }
        }

        /// Mirrors web `paymentMethodConfig` + `buildApplePayRequest`.
        @MainActor
        private func makePaymentRequest() throws -> PKPaymentRequest {
            guard let session = lite.session,
                  let method = session.paymentMethods.applePay
            else {
                throw LiteError.applePayNotConfigured
            }
            guard method.status == .active else {
                throw LiteError.applePayNotActive
            }

            // Web throws if dependencies / merchant_identifier are missing.
            guard let merchantId = method.dependencies?.merchantIdentifier, !merchantId.isEmpty else {
                throw LiteError.applePayNotConfigured
            }

            // Web `buildApplePayRequest` defaults (applied when config fields are missing):
            //   countryCode ?? 'SA'
            //   merchantCapabilities ?? ['supports3DS','supportsCredit','supportsDebit']
            //   supportedNetworks ?? ['amex','discover','masterCard','visa','mada']
            //   total.label = 'Total', amount = session.amount / 100
            let config = method.config
            let countryCode = (config?.countryCode).flatMap { $0.isEmpty ? nil : $0 } ?? "SA"
            let capabilityStrings = (config?.merchantCapabilities).flatMap { $0.isEmpty ? nil : $0 }
                ?? ["supports3DS", "supportsCredit", "supportsDebit"]
            let networkStrings = ApplePayConfig.resolveSupportedNetworks(
                applePayNetworks: config?.supportedNetworks,
                cardNetworks: session.paymentMethods.card?.networks
            )

            let networks = Self.paymentNetworks(from: networkStrings)
            guard !networks.isEmpty else {
                throw LiteError.applePayNotConfigured
            }

            let request = PKPaymentRequest()
            request.merchantIdentifier = merchantId
            request.countryCode = countryCode
            request.currencyCode = session.currency
            request.supportedNetworks = networks
            request.merchantCapabilities = Self.merchantCapabilities(from: capabilityStrings)
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(
                    label: "Total",
                    amount: NSDecimalNumber(decimal: ApplePayConfig.majorUnitAmount(minorUnits: session.amount)),
                    type: .final
                )
            ]
            return request
        }

        static func paymentNetworks(from raw: [String]) -> [PKPaymentNetwork] {
            ApplePayConfig.networks(from: raw).compactMap { PKPaymentNetwork($0) }
        }

        static func merchantCapabilities(from raw: [String]) -> PKMerchantCapability {
            let parsed = ApplePayConfig.capabilities(from: raw)
            var caps = PKMerchantCapability()
            if parsed.isEmpty {
                return [.threeDSecure, .credit, .debit]
            }
            for cap in parsed {
                switch cap {
                case .threeDSecure: caps.insert(.threeDSecure)
                case .credit: caps.insert(.credit)
                case .debit: caps.insert(.debit)
                case .emv: caps.insert(.emv)
                }
            }
            return caps
        }

        // MARK: PKPaymentAuthorizationControllerDelegate

        func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
            // PassKit requires dismiss here. Resume the authorize waiter so poll/3DS can start
            // after the system sheet is gone — do not emit Lite's result yet.
            controller.dismiss { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.controller = nil
                    self.passKitDidFinish = true
                    let waiter = self.passKitFinishWaiter
                    self.passKitFinishWaiter = nil
                    waiter?.resume()
                }
            }
        }

        func paymentAuthorizationController(
            _: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            Task { @MainActor in
                do {
                    // Web: `JSON.stringify(event.payment.token)` → createInstrument('applePay', …) → pay()
                    let tokenJSON = try Self.tokenJSON(from: payment)
                    let result = await lite.payWithApplePay(tokenJSON: tokenJSON) { passKitSuccess in
                        completion(PKPaymentAuthorizationResult(
                            status: passKitSuccess ? .success : .failure,
                            errors: nil
                        ))
                        await self.waitUntilPassKitFinished()
                    }
                    self.onResult(result)
                } catch {
                    completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
                    await self.waitUntilPassKitFinished()
                    self.onResult(Lite.PayResult(
                        status: .failure,
                        paymentId: nil,
                        error: error.localizedDescription
                    ))
                }
            }
        }

        private func waitUntilPassKitFinished() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if passKitDidFinish {
                    cont.resume()
                } else {
                    passKitFinishWaiter = cont
                }
            }
        }

        /// Serialize `PKPayment.token` into the Apple Pay JS token shape
        /// (`paymentData` + `paymentMethod` + `transactionIdentifier`).
        ///
        /// Web does `JSON.stringify(event.payment.token)`. On device, `paymentData` is JSON;
        /// on Simulator it is often empty or plaintext — never fail the whole pay on that alone.
        static func tokenJSON(from payment: PKPayment) throws -> String {
            let token: [String: Any] = [
                "paymentData": Self.paymentDataValue(from: payment.token.paymentData),
                "paymentMethod": [
                    "displayName": payment.token.paymentMethod.displayName ?? "",
                    "network": payment.token.paymentMethod.network?.rawValue ?? "",
                    "type": Self.methodTypeString(payment.token.paymentMethod.type),
                ],
                "transactionIdentifier": payment.token.transactionIdentifier,
            ]

            let data = try JSONSerialization.data(withJSONObject: token)
            guard let json = String(data: data, encoding: .utf8) else {
                throw LiteError.decoding("Could not encode Apple Pay token as UTF-8 JSON.")
            }
            return json
        }

        /// PassKit `paymentData` is usually a JSON object. Simulator may return empty Data or
        /// non-JSON bytes — mirror a usable value instead of throwing Cocoa's format error.
        static func paymentDataValue(from data: Data) -> Any {
            if data.isEmpty {
                return [String: Any]()
            }
            if let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
            if let string = String(data: data, encoding: .utf8) {
                return string
            }
            return data.base64EncodedString()
        }

        static func methodTypeString(_ type: PKPaymentMethodType) -> String {
            switch type {
            case .debit: return "debit"
            case .credit: return "credit"
            case .prepaid: return "prepaid"
            case .store: return "store"
            case .eMoney: return "eMoney"
            case .unknown: return "unknown"
            @unknown default: return "unknown"
            }
        }
    }
}

extension PKPaymentNetwork {
    init?(_ network: ApplePayConfig.Network) {
        switch network {
        case .visa: self = .visa
        case .masterCard: self = .masterCard
        case .amex: self = .amex
        case .discover: self = .discover
        case .mada: self = .mada
        }
    }
}

#endif
