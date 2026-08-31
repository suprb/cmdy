import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat

/// One HTTP server for the whole bridge. Routes are registered by feature modules
/// (MCP `/execute`, registry `/sessions/*`, etc). NIO event loop dispatches into Tasks
/// so handlers can do async work and reply when ready.
// Route registration finishes before `start`; after that NIO owns dispatch and
// the server's event-loop resources. This explicit contract permits the main
// actor to hand the configured server to its async start operation.
final class HTTPServer: @unchecked Sendable {
    static let portFilePath = "/tmp/braincell-bridge.port"
    static let tokenFilePath = "/tmp/braincell-bridge.token"

    private(set) var port: Int
    let authenticationToken: String
    /// Credential injected into untrusted browser pages. It is deliberately
    /// accepted only by routes that explicitly opt into cross-origin access.
    let crossOriginAuthenticationToken: String
    private var channel: Channel?
    private var group: EventLoopGroup?

    /// Route handlers. Match by (method, exact path or path prefix).
    /// Handlers receive the request body as Data and return a JSON-serializable dict.
    typealias Handler = (HTTPRequest) async throws -> HTTPResponse

    struct HTTPRequest {
        let method: HTTPMethod
        let path: String
        let body: Data
        /// First captured group from a prefix match: "/sessions/abc/heartbeat" with prefix "/sessions/" → "abc/heartbeat"
        let pathTail: String
    }

    struct HTTPResponse: @unchecked Sendable {
        let status: HTTPResponseStatus
        let body: Any  // JSON-serializable
        var contentType: String = "application/json"
        var rawData: Data? = nil  // if set, body is ignored
        var allowsCrossOrigin = false

        static func ok(_ body: Any) -> HTTPResponse {
            HTTPResponse(status: .ok, body: body)
        }
        static func badRequest(_ message: String) -> HTTPResponse {
            HTTPResponse(status: .badRequest, body: ["error": message])
        }
        static func unauthorized() -> HTTPResponse {
            HTTPResponse(status: .unauthorized, body: ["error": "Unauthorized"])
        }
        static func notFound() -> HTTPResponse {
            HTTPResponse(status: .notFound, body: ["error": "Not found"])
        }
        static func error(_ message: String) -> HTTPResponse {
            HTTPResponse(status: .internalServerError, body: ["error": message])
        }
    }

    private struct Route {
        let method: HTTPMethod
        let path: String
        let isPrefix: Bool
        let allowsCrossOrigin: Bool
        let handler: Handler
    }

    private var routes: [Route] = []

    init(port: Int, authenticationToken: String,
         crossOriginAuthenticationToken: String) {
        precondition(Self.isValidAuthenticationToken(authenticationToken),
                     "Bridge authentication token must be 64 hexadecimal characters")
        precondition(Self.isValidAuthenticationToken(crossOriginAuthenticationToken),
                     "Bridge browser token must be 64 hexadecimal characters")
        precondition(authenticationToken.caseInsensitiveCompare(
            crossOriginAuthenticationToken) != .orderedSame,
            "Bridge master and browser tokens must be distinct")
        self.port = port
        self.authenticationToken = authenticationToken.lowercased()
        self.crossOriginAuthenticationToken = crossOriginAuthenticationToken.lowercased()
    }

    /// A fresh 256-bit credential for one Bridge process lifetime. Callers must
    /// explicitly receive this token; there is deliberately no tokenless or
    /// fixed development credential.
    static func generateAuthenticationToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    static func isValidAuthenticationToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    /// Exact-match route: e.g. POST /execute
    func route(
        _ method: HTTPMethod,
        _ path: String,
        allowsCrossOrigin: Bool = false,
        _ handler: @escaping Handler
    ) {
        routes.append(Route(
            method: method,
            path: path,
            isPrefix: false,
            allowsCrossOrigin: allowsCrossOrigin,
            handler: handler))
    }

    /// Prefix-match route: e.g. POST /sessions/ matches /sessions/abc/heartbeat
    func routePrefix(
        _ method: HTTPMethod,
        _ pathPrefix: String,
        allowsCrossOrigin: Bool = false,
        _ handler: @escaping Handler
    ) {
        routes.append(Route(
            method: method,
            path: pathPrefix,
            isPrefix: true,
            allowsCrossOrigin: allowsCrossOrigin,
            handler: handler))
    }

    @discardableResult
    func start() async throws -> Int {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = eventLoopGroup

        let server = self
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(NIOHandler(server: server))
                }
            }
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let basePort = min(max(port, 1), 65_535)
        let attempts = min(100, 65_536 - basePort)
        for attempt in 0..<attempts {
            let tryPort = basePort + attempt
            let boundChannel: Channel
            do {
                boundChannel = try await bootstrap.bind(
                    host: "127.0.0.1", port: tryPort).get()
            } catch {
                if attempt < attempts - 1 { continue }
                try? await eventLoopGroup.shutdownGracefully()
                group = nil
                throw error
            }
            channel = boundChannel
            port = tryPort
            NSLog("[Bridge HTTP] Listening on port %d", tryPort)
            do {
                // Publish private discovery state so the MCP shim follows an
                // auto-bumped port and the current per-launch credential.
                // Both files are written 0600 through a fresh temporary inode
                // and atomically renamed into place.
                try publishPrivateDiscoveryFile(
                    path: Self.tokenFilePath, contents: authenticationToken + "\n")
                try publishPrivateDiscoveryFile(
                    path: Self.portFilePath, contents: "\(tryPort)\n")
                return tryPort
            } catch {
                try? await boundChannel.close()
                channel = nil
                removeDiscoveryFilesIfOwned()
                try? await eventLoopGroup.shutdownGracefully()
                group = nil
                throw error
            }
        }
        try? await eventLoopGroup.shutdownGracefully()
        group = nil
        throw NSError(domain: "HTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No port available"])
    }

    func stop() async {
        try? await channel?.close()
        try? await group?.shutdownGracefully()
        removeDiscoveryFilesIfOwned()
    }

    func dispatch(
        method: HTTPMethod,
        path: String,
        body: Data,
        origin: String? = nil,
        authorization: String? = nil
    ) async -> HTTPResponse {
        // Built-in health check
        if method == .GET && path == "/health" {
            return .ok(["status": "ok"])
        }

        // Only explicitly opted-in browser routes receive CORS. Privileged
        // registry and automation endpoints must not be readable or callable
        // by arbitrary web content merely because they listen on loopback.
        if method == .OPTIONS {
            let corsRoute = routes.first {
                $0.allowsCrossOrigin && ($0.isPrefix
                    ? path.hasPrefix($0.path)
                    : path == $0.path)
            }
            guard corsRoute != nil else { return .notFound() }
            var resp = HTTPResponse(status: .ok, body: NSNull())
            resp.contentType = "text/plain"
            resp.rawData = Data()
            resp.allowsCrossOrigin = true
            return resp
        }

        let matchingRoute = routes.first { route in
            route.method == method && (route.isPrefix
                ? path.hasPrefix(route.path)
                : path == route.path)
        }
        if origin != nil, let matchingRoute,
           !matchingRoute.allowsCrossOrigin {
            return .notFound()
        }

        let masterAuthorized = isAuthorized(
            authorization, expected: authenticationToken)
        let browserAuthorized = matchingRoute?.allowsCrossOrigin == true
            && isAuthorized(
                authorization, expected: crossOriginAuthenticationToken)
        guard masterAuthorized || browserAuthorized else {
            var response = HTTPResponse.unauthorized()
            // Let an opted-in browser caller observe its 401 instead of
            // turning it into an opaque CORS failure. No privileged handler
            // is entered until the bearer token is valid.
            if origin != nil,
               routes.contains(where: {
                   $0.allowsCrossOrigin && $0.method == method && ($0.isPrefix
                       ? path.hasPrefix($0.path)
                       : path == $0.path)
               }) {
                response.allowsCrossOrigin = true
            }
            return response
        }

        guard let route = matchingRoute else { return .notFound() }
        let tail = route.isPrefix ? String(path.dropFirst(route.path.count)) : ""
        let request = HTTPRequest(
            method: method, path: path, body: body, pathTail: tail)
        do {
            var response = try await route.handler(request)
            response.allowsCrossOrigin = route.allowsCrossOrigin
            return response
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func isAuthorized(_ authorization: String?, expected: String) -> Bool {
        guard let authorization,
              authorization.hasPrefix("Bearer ") else { return false }
        let supplied = String(authorization.dropFirst("Bearer ".count)).lowercased()
        guard supplied.utf8.count == expected.utf8.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(supplied.utf8, expected.utf8) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private func publishPrivateDiscoveryFile(path: String, contents: String) throws {
        let temporary = path + ".\(getpid()).\(UUID().uuidString)"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Could not create private Bridge discovery file",
            ])
        }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { unlink(temporary) }
        }
        let bytes = Array(contents.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "Could not write private Bridge discovery file",
                ])
            }
            offset += written
        }
        guard fsync(descriptor) == 0, rename(temporary, path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Could not publish private Bridge discovery file",
            ])
        }
        shouldRemoveTemporary = false
    }

    private func removeDiscoveryFilesIfOwned() {
        guard let token = try? String(contentsOfFile: Self.tokenFilePath, encoding: .utf8),
              token.trimmingCharacters(in: .whitespacesAndNewlines) == authenticationToken else {
            return
        }
        try? FileManager.default.removeItem(atPath: Self.tokenFilePath)
        try? FileManager.default.removeItem(atPath: Self.portFilePath)
    }
}

private final class NIOHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let server: HTTPServer
    private var requestBody = ByteBuffer()
    private var requestHead: HTTPRequestHead?
    private var responsePending = false
    private var requestTooLarge = false
    private static let maxBodyBytes = 16 * 1024 * 1024

    init(server: HTTPServer) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            guard requestHead == nil, !responsePending,
                  head.uri.utf8.count <= 8_192 else {
                context.close(promise: nil)
                return
            }
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
            requestTooLarge = false
        case .body(var body):
            guard !requestTooLarge else { return }
            if requestBody.readableBytes + body.readableBytes > Self.maxBodyBytes {
                requestTooLarge = true
                requestBody.clear()
            } else {
                requestBody.writeBuffer(&body)
            }
        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            responsePending = true
            if requestTooLarge {
                write(context: context, response: HTTPServer.HTTPResponse(
                    status: .payloadTooLarge,
                    body: ["error": "request body exceeds 16 MB"]))
            } else {
                handle(context: context, head: head, body: requestBody)
            }
            requestBody.clear()
        }
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
        let bodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()
        let method = head.method
        // Strip query string from URI (we don't use queries in any route).
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri

        let ctx = NIOContextBox(context)
        Task { [weak self] in
            guard let self = self else { return }
            let resp = await self.server.dispatch(
                method: method,
                path: path,
                body: bodyData,
                origin: head.headers.first(name: "Origin"),
                authorization: head.headers.first(name: "Authorization"))
            ctx.value.eventLoop.execute {
                self.write(context: ctx.value, response: resp)
            }
        }
    }

    private func write(context: ChannelHandlerContext, response: HTTPServer.HTTPResponse) {
        let data: Data = {
            if let raw = response.rawData { return raw }
            return (try? JSONSerialization.data(withJSONObject: response.body)) ?? Data()
        }()

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        if response.allowsCrossOrigin {
            headers.add(name: "Access-Control-Allow-Origin", value: "*")
            headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            headers.add(name: "Access-Control-Allow-Headers", value: "Authorization, Content-Type")
            headers.add(name: "Access-Control-Max-Age", value: "600")
        }
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buf = context.channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

/// NIO guarantees a channel context is used only on its event loop. The task
/// above merely carries the reference back to that same loop before touching it.
private final class NIOContextBox: @unchecked Sendable {
    let value: ChannelHandlerContext
    init(_ value: ChannelHandlerContext) { self.value = value }
}
