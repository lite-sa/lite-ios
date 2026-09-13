#if canImport(UIKit)
import UIKit
import WebKit
import LiteSDKCore

/// Presents a 3DS redirect challenge.
///
/// The web renders `next_action.redirect.url` in a sandboxed iframe and closes the modal when the
/// challenge page posts `lite.redirect.authentication.complete` (or calls `window.close()`). We mirror
/// that with an in-app `WKWebView` (ACS completion needs a JS bridge — `ASWebAuthenticationSession`
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
    case challengeDismissed

    var errorDescription: String? {
        "We could not verify this payment. Please try again."
    }
}

// MARK: - WKWebView presenter

@MainActor
final class WKWebViewThreeDS: NSObject, ThreeDSecurePresenting {

    private var activePresenter: ThreeDSContainerViewController?

    func present(redirectURL: URL) async throws {
        try ThreeDSURLValidator.requireSecureChallengeURL(redirectURL)

        try await withTaskCancellationHandler {
            try await awaitChallenge(redirectURL: redirectURL)
        } onCancel: {
            scheduleCancellation()
        }
    }

    private func awaitChallenge(redirectURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            startChallenge(redirectURL: redirectURL, continuation: continuation)
        }
    }

    private func startChallenge(
        redirectURL: URL,
        continuation: CheckedContinuation<Void, Error>
    ) {
        var resumed = false
        let resumeOnce: (Result<Void, Error>) -> Void = { result in
            guard !resumed else { return }
            resumed = true
            continuation.resume(with: result)
        }

        guard let host = Self.topViewController() else {
            resumeOnce(.failure(ThreeDSPresentationError.noPresenter))
            return
        }

        let presenter = ThreeDSContainerViewController(redirectURL: redirectURL) { [weak self] outcome in
            self?.activePresenter = nil
            switch outcome {
            case .completed:
                resumeOnce(.success(()))
            case .dismissed:
                resumeOnce(.failure(ThreeDSPresentationError.challengeDismissed))
            case .cancelled:
                resumeOnce(.failure(CancellationError()))
            }
        }
        activePresenter = presenter
        if !presenter.present(from: host) {
            activePresenter = nil
            resumeOnce(.failure(ThreeDSPresentationError.noPresenter))
        }
    }

    nonisolated private func scheduleCancellation() {
        Task { @MainActor [weak self] in
            self?.activePresenter?.cancelFromTask()
        }
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

@MainActor
private final class ThreeDSContainerViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler, UIAdaptivePresentationControllerDelegate {

    private static let completionMessageType = "lite.redirect.authentication.complete"
    private static let handlerName = "liteAuthComplete"

    enum Outcome {
        case completed
        case dismissed
        case cancelled
    }

    private let redirectURL: URL
    private let expectedOrigin: String?
    private let challengeNonce: String
    private let onFinish: (Outcome) -> Void
    private var finished = false

    private var webView: WKWebView!
    private var dataStore: WKWebsiteDataStore!

    init(redirectURL: URL, onFinish: @escaping (Outcome) -> Void) {
        self.redirectURL = redirectURL
        self.expectedOrigin = ThreeDSURLValidator.expectedOrigin(for: redirectURL)
        self.challengeNonce = UUID().uuidString
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        overrideUserInterfaceStyle = .light
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Returns `false` when there is no key window / presenter — caller must resume continuation.
    @discardableResult
    func present(from host: UIViewController) -> Bool {
        presentationController?.delegate = self
        let url = redirectURL
        host.present(self, animated: true) { [weak self] in
            self?.webView.load(URLRequest(url: url))
        }
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LiteTheme.Colors.backgroundUIColor

        dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(makeBridgeScript())
        controller.addUserScript(makeFillViewportScript())
        controller.add(self, name: Self.handlerName)
        config.userContentController = controller
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.overrideUserInterfaceStyle = .light
        webView.isOpaque = true
        webView.backgroundColor = LiteTheme.Colors.backgroundUIColor
        webView.scrollView.backgroundColor = LiteTheme.Colors.backgroundUIColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = LiteTheme.Colors.textSecondaryUIColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.finish(.dismissed) }, for: .touchUpInside)

        view.addSubview(webView)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func cancelFromTask() {
        finish(.cancelled)
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        finish(.dismissed)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
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
        _: WKWebView,
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

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard webView.url?.scheme != "about" else { return }
        webView.evaluateJavaScript(Self.fillViewportJavaScript, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.finished else { return }
            self.webView?.evaluateJavaScript(Self.fillViewportJavaScript, completionHandler: nil)
        }
    }

    // MARK: - Bridge

    /// Stretch ACS html/body/iframe (and a single root card) to the WebView bounds.
    private static let fillViewportJavaScript = """
    (function() {
      var html = document.documentElement;
      var body = document.body;
      if (!html || !body) return;
      html.style.setProperty('height', '100%', 'important');
      html.style.setProperty('min-height', '100%', 'important');
      html.style.setProperty('width', '100%', 'important');
      body.style.setProperty('height', '100%', 'important');
      body.style.setProperty('min-height', '100%', 'important');
      body.style.setProperty('width', '100%', 'important');
      body.style.setProperty('margin', '0', 'important');
      body.style.setProperty('display', 'flex', 'important');
      body.style.setProperty('flex-direction', 'column', 'important');
      function stretch(el) {
        if (!el || !el.style) return;
        el.style.setProperty('width', '100%', 'important');
        el.style.setProperty('max-width', 'none', 'important');
        el.style.setProperty('height', '100%', 'important');
        el.style.setProperty('min-height', '0', 'important');
        el.style.setProperty('flex', '1 1 auto', 'important');
        el.style.setProperty('margin-left', '0', 'important');
        el.style.setProperty('margin-right', '0', 'important');
        el.style.setProperty('box-sizing', 'border-box', 'important');
      }
      var frames = body.querySelectorAll('iframe');
      var i;
      if (frames.length) {
        for (i = 0; i < frames.length; i++) {
          stretch(frames[i]);
          var p = frames[i].parentElement;
          while (p && p !== body) {
            stretch(p);
            p = p.parentElement;
          }
        }
        return;
      }
      var root = body.children.length === 1 ? body.children[0] : null;
      while (root) {
        stretch(root);
        root = root.children.length === 1 ? root.children[0] : null;
      }
    })();
    """

    private func makeFillViewportScript() -> WKUserScript {
        WKUserScript(
            source: Self.fillViewportJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

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
        if presentingViewController != nil {
            dismiss(animated: true) { [onFinish] in onFinish(outcome) }
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
}
#endif
