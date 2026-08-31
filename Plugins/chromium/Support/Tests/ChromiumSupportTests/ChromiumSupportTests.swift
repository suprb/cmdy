import Foundation
import CmdySDK
import XCTest
@testable import ChromiumSupport

final class ChromiumSupportTests: XCTestCase {
    func testBackgroundCaptureParksWithoutDisturbingForegroundWork() {
        XCTAssertTrue(SidecarCapturePolicy.shouldParkOffscreen(
            hostIsActive: false, sidecarIsActive: false))
        XCTAssertFalse(SidecarCapturePolicy.shouldParkOffscreen(
            hostIsActive: true, sidecarIsActive: false))
        XCTAssertFalse(SidecarCapturePolicy.shouldParkOffscreen(
            hostIsActive: false, sidecarIsActive: true))

        let original = CGRect(x: 120, y: 80, width: 640, height: 480)
        let desktop = CGRect(x: -1440, y: 0, width: 4464, height: 1964)
        let parked = SidecarCapturePolicy.parkedFrame(
            for: original, desktopBounds: desktop)
        XCTAssertEqual(parked.size, original.size)
        let exposed = parked.intersection(desktop)
        XCTAssertEqual(exposed.width, 1, accuracy: 0.01)
        XCTAssertEqual(exposed.height, 1, accuracy: 0.01)
    }

    func testStartPageInstallsAUsableLocalDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-chromium-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let location = BrowserStartPage.install(in: directory.path)
        let page = try XCTUnwrap(URL(string: location))
        XCTAssertTrue(page.isFileURL)
        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>\(HostProductIdentity.titleName)</title>"))
        XCTAssertTrue(html.contains("Start browsing"))
        XCTAssertTrue(html.contains("Enter a URL to open a page"))
    }

    func testDOMFeedbackScriptCarriesItsNonceAndPickerContract() {
        let script = DOMFeedback.script(token: "test-nonce")
        XCTAssertTrue(script.contains("__CMDY_FEEDBACK__:test-nonce:"))
        XCTAssertTrue(script.contains("window.__cmdyFeedback={version:3"))
        XCTAssertTrue(script.contains("selectionType:'region'"))
        XCTAssertTrue(script.contains("selectionType:'element'"))
    }

    func testBrowserHTTPRequiresAuthenticationAndParsesRequests() async throws {
        let server = BrowserHTTPServer()
        server.handler = { request, respond in
            respond(200, [
                "method": request.method,
                "path": request.path,
                "value": request.json?["value"] ?? NSNull(),
            ])
        }
        XCTAssertTrue(server.start(preferredPort: 50_500))
        defer { server.stop() }

        let health = try await send(port: server.port, path: "/health")
        XCTAssertEqual(health.status, 200)

        let denied = try await send(port: server.port, path: "/execute")
        XCTAssertEqual(denied.status, 401)
        XCTAssertEqual(denied.json["error"] as? String, "missing or invalid token")

        let accepted = try await send(
            port: server.port,
            method: "POST",
            path: "/execute?source=test",
            token: server.authToken,
            body: ["value": "hello"])
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(accepted.json["method"] as? String, "POST")
        XCTAssertEqual(accepted.json["path"] as? String, "/execute")
        XCTAssertEqual(accepted.json["value"] as? String, "hello")
    }

    func testBrowserHTTPDrainsAConcurrentConnectionBurst() async throws {
        let server = BrowserHTTPServer()
        server.handler = { _, respond in respond(200, ["ok": true]) }
        XCTAssertTrue(server.start(preferredPort: 50_700))
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 48
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let port = server.port

        let statuses = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<48 {
                group.addTask {
                    var request = URLRequest(url: URL(
                        string: "http://127.0.0.1:\(port)/health?request=\(index)")!)
                    request.timeoutInterval = 3
                    do {
                        let (_, response) = try await session.data(for: request)
                        return (response as? HTTPURLResponse)?.statusCode ?? 0
                    } catch {
                        return -1
                    }
                }
            }
            var results: [Int] = []
            for await status in group { results.append(status) }
            return results
        }

        XCTAssertEqual(statuses.count, 48)
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, 48)
    }

    private func send(port: Int, method: String = "GET", path: String,
                      token: String? = nil, body: [String: Any]? = nil) async throws
        -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 3
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (
            (response as? HTTPURLResponse)?.statusCode ?? 0,
            (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }
}
