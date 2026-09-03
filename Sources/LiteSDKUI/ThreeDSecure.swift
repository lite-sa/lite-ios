#if canImport(UIKit)
import UIKit
import WebKit
import LiteSDKCore

/// Presents a 3DS redirect challenge.
///
/// The web renders `next_action.redirect.url` in a sandboxed iframe and closes the modal when the
/// challenge page posts `lite.redirect.authentication.complete` (or calls `window.close()`). We mirror
/// that with an in-app `WKWebView` sheet (ACS completion needs a JS bridge — `ASWebAuthenticationSession`
/// cannot receive that postMessage). Hardened to match Android `ThreeDSWebViewEngine` + web origin checks.
protocol ThreeDSecurePresenting {
    /// Presents the challenge. Throws if the URL is not https (fail closed with a merchant-visible error).
    @MainActor func present(redirectURL: URL) async throws
}

// MARK: - URL validation

enum ThreeDSURLValidator {
    enum ValidationError: Error, Equatable {
        case notHTTPS
        case invalidURL
    }

    /// Challenge URLs must be https with a host (fail closed).
    static func requireSecureChallengeURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), !url.absoluteString.isEmpty else {
            throw ValidationError.invalidURL
        }
        guard scheme == "https" else {
            throw ValidationError.notHTTPS
        }
        guard let host = url.host, !host.isEmpty else {
            throw ValidationError.invalidURL
        }
    }

    static func expectedOrigin(for url: URL) -> String? {
        HTMLOrigin.serialized(for: url)
    }
}

enum ThreeDSPresentationError: Error, LocalizedError {
    case noPresenter

    var errorDescription: String? {
        "We could not verify this payment. Please try again."
    }
}

// MARK: - WKWebView presenter

@MainActor
final class WKWebViewThreeDS: NSObject, ThreeDSecurePresenting {

    private var activePresenter: ThreeDSModalPresenter?

    func present(redirectURL: URL) async throws {
        try ThreeDSURLValidator.requireSecureChallengeURL(redirectURL)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                let resumeOnce: (Result<Void, Error>) -> Void = { result in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(with: result)
                }

                let presenter = ThreeDSModalPresenter(redirectURL: redirectURL) { [weak self] outcome in
                    self?.activePresenter = nil
                    switch outcome {
                    case .completed:
                        resumeOnce(.success(()))
                    case .cancelled:
                        resumeOnce(.failure(CancellationError()))
                    }
                }
                self.activePresenter = presenter
                let presented = presenter.present()
                if !presented {
                    self.activePresenter = nil
                    resumeOnce(.failure(ThreeDSPresentationError.noPresenter))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.activePresenter?.cancelFromTask()
            }
        }
    }
}

@MainActor
private final class ThreeDSModalPresenter: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIAdaptivePresentationControllerDelegate {

    private static let completionMessageType = "lite.redirect.authentication.complete"
    private static let handlerName = "liteAuthComplete"

    enum Outcome {
        case completed
        case cancelled
    }

    private let redirectURL: URL
    private let expectedOrigin: String?
    private let challengeNonce: String
    private let onFinish: (Outcome) -> Void
    private var finished = false

    private var webView: WKWebView!
    private weak var presentedController: UIViewController?
    private var dataStore: WKWebsiteDataStore!

    init(redirectURL: URL, onFinish: @escaping (Outcome) -> Void) {
        self.redirectURL = redirectURL
        self.expectedOrigin = ThreeDSURLValidator.expectedOrigin(for: redirectURL)
        self.challengeNonce = UUID().uuidString
        self.onFinish = onFinish
        super.init()
    }

    /// Returns `false` when there is no key window / presenter — caller must resume continuation.
    @discardableResult
    func present() -> Bool {
        guard let host = topViewController() else { return false }

        dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(makeBridgeScript())
        controller.add(self, name: Self.handlerName)
        config.userContentController = controller
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.overrideUserInterfaceStyle = .light

        let container = UIViewController()
        container.overrideUserInterfaceStyle = .light
        container.view.backgroundColor = LiteTheme.Colors.backgroundUIColor

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = LiteTheme.Colors.textSecondaryUIColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.finish(.completed) }, for: .touchUpInside)

        container.view.addSubview(closeButton)
        container.view.addSubview(webView)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            webView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])

        let nav = UINavigationController(rootViewController: container)
        nav.overrideUserInterfaceStyle = .light
        nav.modalPresentationStyle = .pageSheet
        nav.presentationController?.delegate = self
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }

        presentedController = nav
        let url = redirectURL
        host.present(nav, animated: true) { [weak self] in
            self?.webView.load(URLRequest(url: url))
        }
        return true
    }

    func cancelFromTask() {
        finish(.cancelled)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(.completed)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        guard isTrustedFrame(message.frameInfo) else { return }
        guard isTrustedCompletionPayload(message.body) else { return }
        finish(.completed)
    }

    private func isTrustedFrame(_ frame: WKFrameInfo) -> Bool {
        guard let expectedOrigin else { return false }
        let origin = frame.securityOrigin
        guard let actual = HTMLOrigin.serialized(scheme: origin.`protocol`, host: origin.host, port: origin.port) else {
            return false
        }
        return actual == expectedOrigin
    }

    private func isTrustedCompletionPayload(_ body: Any) -> Bool {
        let dict: [String: Any]?
        if let asDict = body as? [String: Any] {
            dict = asDict
        } else if let string = body as? String,
                  let data = string.data(using: .utf8),
                  let asDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = asDict
        } else {
            return false
        }
        guard let dict, (dict["type"] as? String) == Self.completionMessageType else { return false }
        guard let nonce = dict["nonce"] as? String, nonce == challengeNonce else { return false }
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // Allow https navigations and about:blank (used during wipe).
        if scheme == "https" || scheme == "about" {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    // MARK: - Bridge

    private func makeBridgeScript() -> WKUserScript {
        let originLiteral: String
        if let expectedOrigin {
            let escaped = expectedOrigin
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            originLiteral = "'\(escaped)'"
        } else {
            originLiteral = "null"
        }
        let nonceLiteral = challengeNonce
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        // Injected into the main frame only; it still receives `message` events from iframes.
        // Origin check mirrors web AuthenticationModal / Android ThreeDSWebViewEngine.
        // Install only when `location.origin` matches the ACS origin (A19).
        let source = """
        (function() {
          if (window.__liteAuthBridgeInstalled) return;
          var expectedOrigin = \(originLiteral);
          var challengeNonce = '\(nonceLiteral)';
          if (expectedOrigin && window.location.origin !== expectedOrigin) return;
          window.__liteAuthBridgeInstalled = true;
          function notifyComplete(data) {
            try {
              var payload = data || { type: '\(Self.completionMessageType)', success: true };
              if (typeof payload !== 'object' || payload === null) {
                payload = { type: '\(Self.completionMessageType)', success: true };
              }
              payload.nonce = challengeNonce;
              window.webkit.messageHandlers.\(Self.handlerName).postMessage(payload);
            } catch (e) {}
          }
          window.addEventListener('message', function(e) {
            try {
              if (expectedOrigin && e.origin !== expectedOrigin) return;
              var data = e.data;
              if (typeof data === 'string') {
                try { data = JSON.parse(data); } catch (err) { return; }
              }
              if (!data || typeof data !== 'object') return;
              if (data.type !== '\(Self.completionMessageType)') return;
              notifyComplete(data);
            } catch (err) {}
          });
          var originalClose = window.close;
          window.close = function() {
            notifyComplete({ type: '\(Self.completionMessageType)', success: true });
            if (typeof originalClose === 'function') {
              try { originalClose.call(window); } catch (e) {}
            }
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        wipeWebView()
        if let presented = presentedController {
            presented.dismiss(animated: true) { [onFinish] in onFinish(outcome) }
        } else {
            onFinish(outcome)
        }
    }

    private func wipeWebView() {
        webView?.stopLoading()
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView?.navigationDelegate = nil
        // Non-persistent store — also clear any residual records for this challenge.
        let store = dataStore ?? webView?.configuration.websiteDataStore
        store?.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
        }
        webView = nil
    }

    private func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
#endif
