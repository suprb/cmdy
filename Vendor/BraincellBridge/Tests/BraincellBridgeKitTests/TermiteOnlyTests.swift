import XCTest
@testable import BraincellBridgeKit

final class CmdyHostSecurityTests: XCTestCase {
    func testBoundedFileReaderRejectsOversizedFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-bounded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: 1_025).write(to: url)

        XCTAssertThrowsError(
            try BridgeBoundedFileReader.data(at: url, maxBytes: 1_024))
        XCTAssertEqual(
            try BridgeBoundedFileReader.data(at: url, maxBytes: 1_025).count,
            1_025)
    }

    func testPIDFileRejectsDangerousProcessIdentifiers() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        for value in ["0", "1", "-1", String(repeating: "9", count: 65)] {
            try Data(value.utf8).write(to: url, options: .atomic)
            XCTAssertNil(BridgePIDFile.previousPID(at: url, excluding: 999))
        }

        try Data("1234\n".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(
            BridgePIDFile.previousPID(at: url, excluding: 999),
            1_234)
        XCTAssertNil(BridgePIDFile.previousPID(at: url, excluding: 1_234))
    }

    func testOnlyOptedInRoutesReceiveCORS() async {
        let token = String(repeating: "a", count: 64)
        let browserToken = String(repeating: "b", count: 64)
        let server = HTTPServer(
            port: 34_570,
            authenticationToken: token,
            crossOriginAuthenticationToken: browserToken)
        server.route(.POST, "/private") { _ in .ok(["ok": true]) }
        server.route(.POST, "/composer/show", allowsCrossOrigin: true) { _ in
            .ok(["ok": true])
        }

        let privatePreflight = await server.dispatch(
            method: .OPTIONS, path: "/private", body: Data())
        XCTAssertEqual(privatePreflight.status, .notFound)
        XCTAssertFalse(privatePreflight.allowsCrossOrigin)

        let composerPreflight = await server.dispatch(
            method: .OPTIONS, path: "/composer/show", body: Data())
        XCTAssertEqual(composerPreflight.status, .ok)
        XCTAssertTrue(composerPreflight.allowsCrossOrigin)

        let unauthorized = await server.dispatch(
            method: .POST, path: "/private", body: Data())
        XCTAssertEqual(unauthorized.status, .unauthorized)
        XCTAssertFalse(unauthorized.allowsCrossOrigin)
        let wrongToken = await server.dispatch(
            method: .POST, path: "/private", body: Data(),
            authorization: "Bearer \(String(repeating: "c", count: 64))")
        XCTAssertEqual(wrongToken.status, .unauthorized)
        let privateResponse = await server.dispatch(
            method: .POST, path: "/private", body: Data(),
            authorization: "Bearer \(token)")
        XCTAssertEqual(privateResponse.status, .ok)
        XCTAssertFalse(privateResponse.allowsCrossOrigin)
        let scopedTokenPrivateResponse = await server.dispatch(
            method: .POST,
            path: "/private",
            body: Data(),
            authorization: "Bearer \(browserToken)")
        XCTAssertEqual(scopedTokenPrivateResponse.status, .unauthorized)
        let browserPrivateResponse = await server.dispatch(
            method: .POST,
            path: "/private",
            body: Data(),
            origin: "https://example.com",
            authorization: "Bearer \(token)")
        XCTAssertEqual(browserPrivateResponse.status, .notFound)
        let unauthorizedComposer = await server.dispatch(
            method: .POST,
            path: "/composer/show",
            body: Data(),
            origin: "https://example.com")
        XCTAssertEqual(unauthorizedComposer.status, .unauthorized)
        XCTAssertTrue(unauthorizedComposer.allowsCrossOrigin)
        let composerResponse = await server.dispatch(
            method: .POST,
            path: "/composer/show",
            body: Data(),
            origin: "https://example.com",
            authorization: "Bearer \(browserToken)")
        XCTAssertEqual(composerResponse.status, .ok)
        XCTAssertTrue(composerResponse.allowsCrossOrigin)
        let masterComposerResponse = await server.dispatch(
            method: .POST,
            path: "/composer/show",
            body: Data(),
            authorization: "Bearer \(token)")
        XCTAssertEqual(masterComposerResponse.status, .ok)

        let health = await server.dispatch(
            method: .GET, path: "/health", body: Data())
        XCTAssertEqual(health.status, .ok)
        XCTAssertEqual((health.body as? [String: String])?["status"], "ok")
    }

    func testBridgeAuthenticationTokensAreFreshAndStrong() {
        let first = HTTPServer.generateAuthenticationToken()
        let second = HTTPServer.generateAuthenticationToken()
        XCTAssertTrue(HTTPServer.isValidAuthenticationToken(first))
        XCTAssertTrue(HTTPServer.isValidAuthenticationToken(second))
        XCTAssertNotEqual(first, second)
    }

    @MainActor
    func testStreamProxyRejectsBodiesOverSixteenMegabytes() async throws {
        let server = StreamProxyServer()
        try await server.start()
        do {
            let url = try XCTUnwrap(URL(
                string: "http://127.0.0.1:\(server.port)/sess/test/v1/messages"))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.httpBody = Data(repeating: 0x61, count: 16 * 1024 * 1024 + 1)
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 413)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("exceeds 16 MB"))
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @MainActor
    func testFeedbackStoreFiltersAndResolvesBySession() {
        let store = BridgeFeedbackStore()
        let first = store.add([
            "sessionId": "pane-a", "source": "bridge", "comment": "Align this",
        ])
        _ = store.add([
            "sessionId": "pane-b", "source": "bridge", "comment": "Rename this",
        ])

        XCTAssertEqual(store.list(status: "open", sessionId: "pane-a").count, 1)
        let id = try! XCTUnwrap(first["id"] as? String)
        XCTAssertEqual(store.resolve(id: id)?["status"] as? String, "resolved")
        XCTAssertEqual(store.list(status: "open", sessionId: "pane-a").count, 0)
        XCTAssertEqual(store.clear(resolvedOnly: true, sessionId: "pane-a"), 1)
        XCTAssertEqual(store.list(sessionId: "pane-b").count, 1)
    }

    @MainActor
    func testRecognizesOnlyProductHostApplication() {
        XCTAssertTrue(TextInjection.isTerminalApp(
            bundleId: BridgeHostIdentity.bundleIdentifier))
        XCTAssertFalse(TextInjection.isTerminalApp(bundleId: "com.apple.Terminal"))
        XCTAssertFalse(TextInjection.isTerminalApp(bundleId: "com.mitchellh.ghostty"))
        XCTAssertFalse(TextInjection.isTerminalApp(bundleId: "com.googlecode.iterm2"))
    }

    @MainActor
    func testTerminalAppsAreNotNativeBindingTargets() {
        XCTAssertTrue(TextInjection.isTerminalLikeApp(
            bundleId: BridgeHostIdentity.bundleIdentifier))
        XCTAssertTrue(TextInjection.isTerminalLikeApp(bundleId: "com.mitchellh.ghostty"))
        XCTAssertTrue(TextInjection.isTerminalLikeApp(bundleId: "com.apple.Terminal"))
        XCTAssertFalse(TextInjection.isTerminalLikeApp(bundleId: "com.apple.finder"))
        XCTAssertFalse(TextInjection.isTerminalLikeApp(bundleId: "com.google.Chrome"))
    }

    @MainActor
    func testLauncherAlwaysTargetsProductHost() {
        XCTAssertEqual(
            TerminalLauncher.preferredTerminalBundleId(
                lastFrontmostBundleId: "com.mitchellh.ghostty"),
            BridgeHostIdentity.bundleIdentifier)
    }

    func testRegistrationRequiresProductHostAndExactWindowIdentity() {
        XCTAssertNil(RegistryRoutes.hostIdentityError(
            terminalApp: BridgeHostIdentity.slug, windowId: 42))
        XCTAssertNotNil(RegistryRoutes.hostIdentityError(
            terminalApp: "Ghostty", windowId: 42))
        XCTAssertNotNil(RegistryRoutes.hostIdentityError(
            terminalApp: BridgeHostIdentity.slug, windowId: nil))
        XCTAssertNotNil(RegistryRoutes.hostIdentityError(
            terminalApp: BridgeHostIdentity.slug, windowId: 0))
    }

    @MainActor
    func testRegistryTracksFocusedPaneWithinExactWindow() {
        let registry = TerminalRegistry()
        let session = registry.register(
            pid: 123, tty: "/dev/ttys123",
            terminalApp: BridgeHostIdentity.slug,
            windowId: 77, paneId: "pane-a", paneFocused: false,
            windowTitle: BridgeHostIdentity.displayName, projectPath: "/tmp")
        XCTAssertEqual(session.windowId, 77)
        XCTAssertEqual(session.paneId, "pane-a")
        XCTAssertFalse(session.paneFocused)

        let updated = registry.update(id: session.id, paneId: "pane-a",
                                      paneFocused: true)
        XCTAssertTrue(updated?.paneFocused == true)
    }
}
