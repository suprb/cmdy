import CoreGraphics
import Foundation
import XCTest
@testable import sim

final class BrowserMirrorHandoffTests: XCTestCase {
    func testDelayedBrowserDiscoveryRetriesUntilExactMirrorURLIsVisible() async throws {
        let targetURL = try XCTUnwrap(URL(string: "http://localhost:3204"))
        let fixture = try BrowserAPIFixture(targetURL: targetURL)
        defer { fixture.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmdy-browser-handoff-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let discoveryURL = directory.appendingPathComponent("browser-api.json")

        let scheduler = ManualHandoffScheduler()
        let outcome = HandoffOutcomeCapture()
        let completed = expectation(description: "mirror URL reached")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let handoff = BrowserMirrorHandoff(
            mirrorURL: targetURL,
            windowNumber: 404,
            discoveryURL: discoveryURL,
            session: session,
            schedule: scheduler.schedule,
            isCurrent: { true },
            completion: {
                outcome.store($0)
                completed.fulfill()
            })

        // Browser's API is not discoverable yet. The first attempt must stay
        // local and queue a retry instead of opening an external browser.
        handoff.start(attemptsRemaining: 4)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(fixture.snapshot().navigateCount, 0)

        let discovery = try JSONSerialization.data(withJSONObject: [
            "port": fixture.port,
            "token": fixture.token,
        ])
        try discovery.write(to: discoveryURL, options: .atomic)

        // Retry 1 discovers Browser and sends the real authenticated navigate.
        let firstVerification = expectation(description: "first verification scheduled")
        scheduler.observeNextEnqueue { firstVerification.fulfill() }
        XCTAssertTrue(scheduler.runNext())
        await fulfillment(of: [firstVerification], timeout: 2)

        // Browser accepted navigate but its CEF surface still reports another
        // localhost session whose port only shares the `3204` prefix. Exact
        // get_url matching must schedule another complete handoff.
        let secondAttempt = expectation(description: "second attempt scheduled")
        scheduler.observeNextEnqueue { secondAttempt.fulfill() }
        XCTAssertTrue(scheduler.runNext())
        await fulfillment(of: [secondAttempt], timeout: 2)

        // The next navigate makes the fixture's surface live. A second exact
        // get_url verification is still required before completion.
        let secondVerification = expectation(description: "second verification scheduled")
        scheduler.observeNextEnqueue { secondVerification.fulfill() }
        XCTAssertTrue(scheduler.runNext())
        await fulfillment(of: [secondVerification], timeout: 2)
        XCTAssertTrue(scheduler.runNext())
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(
            outcome.value,
            .reached("http://localhost:3204/"))
        let requests = fixture.snapshot()
        XCTAssertEqual(requests.navigateCount, 2)
        XCTAssertEqual(requests.getURLCount, 2)
        XCTAssertEqual(
            requests.navigatedURLs,
            [targetURL.absoluteString, targetURL.absoluteString])
        XCTAssertEqual(requests.windowNumbers, [404, 404, 404, 404])
        XCTAssertEqual(scheduler.recordedDelays, [0.15, 0.5, 0.15, 0.5])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }
}

private final class BrowserAPIFixture: @unchecked Sendable {
    struct Snapshot {
        let navigateCount: Int
        let getURLCount: Int
        let navigatedURLs: [String]
        let windowNumbers: [Int]
    }

    private let server = SimHTTPServer()
    private let lock = NSLock()
    private let targetURL: URL
    private var navigateCount = 0
    private var getURLCount = 0
    private var navigatedURLs: [String] = []
    private var windowNumbers: [Int] = []
    private var visibleURL = "http://localhost:32040/"

    var port: Int { server.port }
    var token: String { server.authToken }

    init(targetURL: URL) throws {
        self.targetURL = targetURL
        server.handler = { [weak self] request, respond in
            self?.handle(request, respond: respond)
        }
        let preferred = UInt16(50_000 + Int(getpid()) % 10_000)
        guard server.start(preferredPort: preferred) else {
            throw BrowserFixtureError.couldNotBind
        }
    }

    func stop() {
        server.stop()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            navigateCount: navigateCount,
            getURLCount: getURLCount,
            navigatedURLs: navigatedURLs,
            windowNumbers: windowNumbers)
    }

    private func handle(
        _ request: SimHTTPServer.Request,
        respond: @escaping (Int, Any) -> Void
    ) {
        guard request.method == "POST", request.path == "/execute",
              let json = request.json,
              let tool = json["tool"] as? String,
              let window = (json["window"] as? NSNumber)?.intValue else {
            respond(400, ["error": "invalid fixture request"])
            return
        }

        let result: [String: Any]
        lock.lock()
        windowNumbers.append(window)
        switch tool {
        case "navigate":
            let arguments = json["arguments"] as? [String: Any]
            let url = arguments?["url"] as? String ?? ""
            navigateCount += 1
            navigatedURLs.append(url)
            if navigateCount >= 2 {
                visibleURL = targetURL.absoluteString + "/"
            }
            result = ["success": true, "url": url]

        case "get_url":
            getURLCount += 1
            result = ["success": true, "url": visibleURL]

        default:
            lock.unlock()
            respond(200, ["error": "unexpected tool \(tool)"])
            return
        }
        lock.unlock()
        respond(200, ["result": result])
    }
}

private enum BrowserFixtureError: Error {
    case couldNotBind
}

private final class ManualHandoffScheduler: @unchecked Sendable {
    typealias Action = () -> Void

    private let lock = NSLock()
    private var actions: [Action] = []
    private var delays: [TimeInterval] = []
    private var nextObserver: (() -> Void)?

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }

    var recordedDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }

    func observeNextEnqueue(_ observer: @escaping () -> Void) {
        lock.lock()
        precondition(nextObserver == nil)
        nextObserver = observer
        lock.unlock()
    }

    func schedule(delay: TimeInterval, action: @escaping Action) {
        lock.lock()
        actions.append(action)
        delays.append(delay)
        let observer = nextObserver
        nextObserver = nil
        lock.unlock()
        observer?()
    }

    @discardableResult
    func runNext() -> Bool {
        lock.lock()
        guard !actions.isEmpty else {
            lock.unlock()
            return false
        }
        let action = actions.removeFirst()
        lock.unlock()
        action()
        return true
    }
}

private final class HandoffOutcomeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrowserMirrorHandoff.Outcome?

    var value: BrowserMirrorHandoff.Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ outcome: BrowserMirrorHandoff.Outcome) {
        lock.lock()
        stored = outcome
        lock.unlock()
    }
}
