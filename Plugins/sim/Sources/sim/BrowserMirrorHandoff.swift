import CoreGraphics
import Foundation

/// Delivers one serve-sim session to the Browser attached to the same Cmdy
/// window. Discovery, navigation, and CEF creation are independently
/// asynchronous, so success means Browser reports the target URL—not merely
/// that it accepted an early navigate request.
final class BrowserMirrorHandoff: @unchecked Sendable {
    enum Outcome: Equatable {
        case reached(String)
        case exhausted
        case cancelled
    }

    typealias Scheduler = (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> Void

    private let mirrorURL: URL
    private let windowNumber: CGWindowID
    private let discoveryURL: URL
    private let session: URLSession
    private let retryDelay: TimeInterval
    private let verificationDelay: TimeInterval
    private let schedule: Scheduler
    private let isCurrent: () -> Bool
    private let completion: ((Outcome) -> Void)?
    private let completionLock = NSLock()
    private var didFinish = false

    init(
        mirrorURL: URL,
        windowNumber: CGWindowID,
        discoveryURL: URL,
        session: URLSession = .shared,
        retryDelay: TimeInterval = 0.15,
        verificationDelay: TimeInterval = 0.5,
        schedule: @escaping Scheduler,
        isCurrent: @escaping () -> Bool,
        completion: ((Outcome) -> Void)? = nil
    ) {
        self.mirrorURL = mirrorURL
        self.windowNumber = windowNumber
        self.discoveryURL = discoveryURL
        self.session = session
        self.retryDelay = retryDelay
        self.verificationDelay = verificationDelay
        self.schedule = schedule
        self.isCurrent = isCurrent
        self.completion = completion
    }

    /// `attemptsRemaining` retains the historical contract: the initial
    /// attempt is immediate, followed by at most this many scheduled retries.
    func start(attemptsRemaining: Int = 40) {
        attempt(attemptsRemaining: max(0, attemptsRemaining))
    }

    private func attempt(attemptsRemaining: Int) {
        guard isCurrent() else {
            finish(.cancelled)
            return
        }
        guard let endpoint = browserEndpoint() else {
            retry(attemptsRemaining: attemptsRemaining)
            return
        }

        post(
            endpoint: endpoint,
            tool: "navigate",
            arguments: ["url": mirrorURL.absoluteString]
        ) { accepted, _ in
            guard accepted else {
                self.retry(attemptsRemaining: attemptsRemaining)
                return
            }
            self.schedule(self.verificationDelay) {
                self.verify(endpoint: endpoint,
                            attemptsRemaining: attemptsRemaining)
            }
        }
    }

    private func verify(
        endpoint: BrowserEndpoint,
        attemptsRemaining: Int
    ) {
        guard isCurrent() else {
            finish(.cancelled)
            return
        }
        post(endpoint: endpoint, tool: "get_url", arguments: [:]) {
            accepted, result in
            if accepted,
               let reportedURL = result?["url"] as? String,
               Self.samePage(reportedURL, as: self.mirrorURL.absoluteString) {
                self.finish(.reached(reportedURL))
                return
            }
            self.retry(attemptsRemaining: attemptsRemaining)
        }
    }

    private func retry(attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            finish(.exhausted)
            return
        }
        schedule(retryDelay) {
            self.attempt(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private struct BrowserEndpoint {
        let executeURL: URL
        let token: String
    }

    private func browserEndpoint() -> BrowserEndpoint? {
        guard let data = Simctl.readFile(discoveryURL.path, maxBytes: 64 * 1024),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let port = (json["port"] as? NSNumber)?.intValue,
              let token = json["token"] as? String,
              (1...65_535).contains(port),
              !token.isEmpty, token.count <= 4_096,
              let executeURL = URL(
                string: "http://127.0.0.1:\(port)/execute") else {
            return nil
        }
        return BrowserEndpoint(executeURL: executeURL, token: token)
    }

    private func post(
        endpoint: BrowserEndpoint,
        tool: String,
        arguments: [String: Any],
        completion: @escaping (Bool, [String: Any]?) -> Void
    ) {
        let payload: [String: Any] = [
            "tool": tool,
            "arguments": arguments,
            "window": Int(windowNumber),
        ]
        guard let body = try? JSONSerialization.data(
            withJSONObject: payload) else {
            completion(false, nil)
            return
        }
        var request = URLRequest(url: endpoint.executeURL)
        request.httpMethod = "POST"
        request.addValue(
            "Bearer \(endpoint.token)",
            forHTTPHeaderField: "Authorization")
        request.addValue(
            "application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 5
        session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let status = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status),
                  let data,
                  let envelope = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  envelope["error"] == nil,
                  let result = envelope["result"] as? [String: Any] else {
                completion(false, nil)
                return
            }
            completion(true, result)
        }.resume()
    }

    /// CEF commonly canonicalizes an empty HTTP path to `/`. Everything else
    /// must match, preventing a response from an unrelated localhost page on
    /// the same or a merely similar port from ending the retry loop.
    private static func samePage(_ reported: String, as expected: String) -> Bool {
        guard let reported = URLComponents(string: reported),
              let expected = URLComponents(string: expected) else { return false }
        func path(_ value: String) -> String { value.isEmpty ? "/" : value }
        return reported.scheme?.lowercased() == expected.scheme?.lowercased()
            && reported.host?.lowercased() == expected.host?.lowercased()
            && reported.port == expected.port
            && path(reported.percentEncodedPath) == path(expected.percentEncodedPath)
            && reported.percentEncodedQuery == expected.percentEncodedQuery
            && reported.percentEncodedFragment == expected.percentEncodedFragment
    }

    private func finish(_ outcome: Outcome) {
        completionLock.lock()
        guard !didFinish else {
            completionLock.unlock()
            return
        }
        didFinish = true
        completionLock.unlock()
        completion?(outcome)
    }
}
