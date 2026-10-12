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
        let port = Int(server.port)
        // The proxy rejects from the declared length and closes. Uploading the
        // body too races that close, so send only the head and read the reply.
        let head = "POST /sess/test/v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Length: \(16 * 1024 * 1024 + 1)\r\n\r\n"
        let exchange = Task.detached { () -> String? in
            CmdyHostSecurityTests.exchange(port: port, request: head)
        }
        let reply = await exchange.value
        await server.stop()
        let text = try XCTUnwrap(reply)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 413"), text)
        XCTAssertTrue(text.contains("exceeds 16 MB"), text)
    }

    /// Writes `request` to a loopback TCP port and reads until the peer closes.
    private nonisolated static func exchange(port: Int, request: String) -> String? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let bytes = Array(request.utf8)
        guard send(descriptor, bytes, bytes.count, 0) == bytes.count else { return nil }
        var response = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { break }
            response += buffer[0..<count]
        }
        return String(decoding: response, as: UTF8.self)
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
