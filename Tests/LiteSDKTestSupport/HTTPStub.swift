import Foundation

/// A fake network for tests: answers every request with the next canned response and records what
/// was sent. Attach it to a test `URLSession` (`configuration.protocolClasses = [HTTPStub.self]`), or
/// register it process-wide (`URLProtocol.registerClass`) for code that uses `URLSession.shared`.
/// Call `reset()` before each test: its state is static, and guarded by a lock because URL loading
/// threads record requests while the test reads them.
public final class HTTPStub: URLProtocol {
    public struct Recorded {
        public let method: String
        public let url: String
        public let authorization: String?
        public let body: Data?

        public var json: [String: Any]? {
            guard let body else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    private static var storedCanned: [(Int, String)] = []
    private static var storedRequests: [Recorded] = []
    private static var storedDelay: TimeInterval = 0

    /// Answers, in order, as `(status, JSON body)`. Once they run out, every request gets a 500.
    public static var canned: [(Int, String)] {
        get { locked { storedCanned } }
        set { locked { storedCanned = newValue } }
    }

    public static var requests: [Recorded] {
        get { locked { storedRequests } }
        set { locked { storedRequests = newValue } }
    }

    /// How long each answer waits, to hold a request open while a test acts.
    public static var delay: TimeInterval {
        get { locked { storedDelay } }
        set { locked { storedDelay = newValue } }
    }

    public static func reset() {
        locked {
            storedCanned = []
            storedRequests = []
            storedDelay = 0
        }
    }

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The delayed answer, cancelled when `URLSession` stops this request.
    private var pendingResponse: DispatchWorkItem?

    override public class func canInit(with _: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let recorded = Recorded(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody ?? Self.read(request.httpBodyStream)
        )
        // Record and take the answer in one step, so two requests can't take the same one.
        let (status, payload, delay) = Self.locked { () -> (Int, String, TimeInterval) in
            Self.storedRequests.append(recorded)
            let (status, payload) = Self.storedCanned.isEmpty ? (500, "{}") : Self.storedCanned.removeFirst()
            return (status, payload, Self.storedDelay)
        }
        let respond = { [self] in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            let work = DispatchWorkItem(block: respond)
            pendingResponse = work
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            respond()
        }
    }

    override public func stopLoading() {
        // A delayed answer must not reach a client that has torn this request down.
        pendingResponse?.cancel()
        pendingResponse = nil
    }

    /// `URLSession` hands a protocol the body as a stream, not `httpBody`.
    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
