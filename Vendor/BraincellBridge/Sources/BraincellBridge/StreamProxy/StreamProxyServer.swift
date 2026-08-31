import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat

/// Local HTTP reverse proxy that forwards Anthropic API requests verbatim
/// while teeing the SSE response stream into `SSEStreamParser` to surface
/// `tool_use` composition events.
///
/// Why this exists: with `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>/sess/<sid>`
/// set in a bound terminal, every Claude Code call to `api.anthropic.com`
/// flows through this proxy. We forward it verbatim (auth headers preserved)
/// and parse the SSE response so the bridge can render an "intent overlay"
/// the moment Claude *starts* composing a tool call — typically 500–2000ms
/// before the call actually arrives at our MCP endpoint.
///
/// URL shape: `/sess/<sessionId>/v1/messages` (or any other `/v1/...` path).
/// The `<sessionId>` segment is stripped before forwarding upstream and is
/// attached to every emitted `ToolStreamEvent`.
@MainActor
final class StreamProxyServer {
    /// Port the proxy is listening on. Set after `start()` succeeds.
    private(set) var port: Int = 0

    /// Single sink for all parsed tool-stream events. Dispatched on the main actor.
    var onEvent: ((ToolStreamEvent) -> Void)?

    private var channel: Channel?
    private var group: EventLoopGroup?

    /// One URLSession reused for every upstream request. Created in `start()`
    /// (so init stays cheap) and stored as a plain reference — URLSession is
    /// internally thread-safe, so the inbound handler reads it directly off
    /// any thread without hopping to the main actor.
    nonisolated(unsafe) fileprivate var urlSession: URLSession?

    /// Bind and listen on `127.0.0.1` at any free port. Subsequent reads of
    /// `port` reflect the actual bound port. Throws on bind/listen failure.
    func start(preferredPort: Int = 0) async throws {
        // Build the URLSession once. Delegate is the shared singleton because
        // URLSession requires the delegate at construction time.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(
            configuration: cfg,
            delegate: ProxyURLSessionDelegate.shared,
            delegateQueue: nil
        )

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let server = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProxyInboundHandler(server: server))
                }
            }
            .childChannelOption(.maxMessagesPerRead, value: 4)

        // Try preferredPort first, then auto-bump up to +99.
        let basePort = max(preferredPort, 0)
        for attempt in 0..<100 {
            let tryPort = basePort == 0 ? 0 : basePort + attempt
            do {
                let ch = try await bootstrap.bind(host: "127.0.0.1", port: tryPort).get()
                self.channel = ch
                let bound = ch.localAddress?.port ?? tryPort
                self.port = bound
                NSLog("[StreamProxy] Listening on 127.0.0.1:%d", bound)
                return
            } catch {
                if basePort == 0 || attempt == 99 {
                    NSLog("[StreamProxy] Bind failed: %@", "\(error)")
                    throw error
                }
                continue
            }
        }
    }

    func stop() async {
        try? await channel?.close()
        try? await group?.shutdownGracefully()
        urlSession?.invalidateAndCancel()
        channel = nil
        group = nil
        urlSession = nil
    }

    /// Called by the inbound handler off the main actor when the SSE parser
    /// produces an event. Bounces onto the main actor for the public sink.
    nonisolated fileprivate func dispatchEvent(_ event: ToolStreamEvent) {
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
    }
}

// MARK: - Inbound NIO handler

/// Buffers the inbound HTTP request, kicks off the upstream URLSession task,
/// and streams the response (status + headers + body bytes) back. One
/// instance per inbound connection — `channelInactive` releases state.
///
/// Forwards bytes BOTH to the channel AND to a per-request `SSEStreamParser`
/// when the upstream `Content-Type` is `text/event-stream`.
private final class ProxyInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Hop-by-hop headers per RFC 7230 — never forwarded upstream or back.
    private static let hopByHop: Set<String> = [
        "host", "connection", "transfer-encoding", "content-length",
        "upgrade", "proxy-connection", "keep-alive", "te", "trailer"
    ]

    /// Header names that may contain credentials — redacted in NSLog output.
    /// Matched by case-insensitive substring on the header NAME.
    private static let secretMarkers: [String] = ["key", "token", "secret", "auth"]
    private static let maxRequestBodyBytes = 16 * 1024 * 1024

    private weak var server: StreamProxyServer?
    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()
    /// Tracks whether we've sent the response head to the client. Required so
    /// `writeResponseEnd` doesn't try to write `.end` on a pipeline that's
    /// still waiting for `.head` — that trips an assertionFailure inside
    /// NIO's `HTTPServerProtocolErrorHandler` and crashes the proxy. Happens
    /// when the upstream URLSession task fails BEFORE delivering an
    /// HTTPURLResponse (e.g. DNS hiccup, TLS handshake error).
    private var responseHeadSent = false
    /// Tracks whether the inbound channel is still open. Late callbacks
    /// from URLSession can fire after the client (Claude Code) has already
    /// disconnected; writing into a closed channel asserts inside NIO.
    private var channelIsActive = true

    init(server: StreamProxyServer) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
            let declaredTooLarge = head.headers.first(name: "Content-Length")
                .flatMap(Int.init)
                .map { $0 > Self.maxRequestBodyBytes }
                ?? false
            if declaredTooLarge {
                requestHead = nil
                writeError(
                    context: context,
                    status: .payloadTooLarge,
                    message: "Proxy request body exceeds 16 MB")
            }
        case .body(var buf):
            guard requestHead != nil else { return }
            if requestBody.readableBytes + buf.readableBytes > Self.maxRequestBodyBytes {
                requestHead = nil
                requestBody.clear()
                writeError(
                    context: context,
                    status: .payloadTooLarge,
                    message: "Proxy request body exceeds 16 MB")
            } else {
                requestBody.writeBuffer(&buf)
            }
        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            let bodyData = requestBody.getData(at: requestBody.readerIndex,
                                               length: requestBody.readableBytes) ?? Data()
            requestBody.clear()
            handle(context: context, head: head, body: bodyData)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelIsActive = false
        context.fireChannelInactive()
    }

    // MARK: Request handling

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri

        // Expect /sess/<sessionId>/<rest...>
        guard path.hasPrefix("/sess/") else {
            NSLog("[StreamProxy] %@ %@ — rejected (no /sess/ prefix)",
                  head.method.rawValue, path)
            writeError(context: context, status: .badRequest,
                       message: "Proxy requires /sess/<sessionId> path prefix")
            return
        }

        // Slice off "/sess/" then split off the next segment as sessionId.
        let afterPrefix = path.dropFirst("/sess/".count)
        guard let nextSlash = afterPrefix.firstIndex(of: "/") else {
            NSLog("[StreamProxy] %@ %@ — rejected (missing path tail after sessionId)",
                  head.method.rawValue, path)
            writeError(context: context, status: .badRequest,
                       message: "Missing path after /sess/<sessionId>")
            return
        }
        let sessionId = String(afterPrefix[..<nextSlash])
        let upstreamPath = String(afterPrefix[nextSlash...])  // includes leading slash
        guard !sessionId.isEmpty else {
            writeError(context: context, status: .badRequest, message: "Empty sessionId")
            return
        }

        // Reattach query string if there was one.
        let query: String = {
            if let qIdx = head.uri.firstIndex(of: "?") {
                return String(head.uri[qIdx...])  // includes the '?'
            }
            return ""
        }()
        let upstreamURLString = "https://api.anthropic.com\(upstreamPath)\(query)"
        guard let upstreamURL = URL(string: upstreamURLString) else {
            NSLog("[StreamProxy] Bad upstream URL: %@", upstreamURLString)
            writeError(context: context, status: .badRequest, message: "Invalid upstream URL")
            return
        }

        NSLog("[StreamProxy] %@ %@ sid=%@ → %@",
              head.method.rawValue, path, sessionId, upstreamURL.absoluteString)
        logHeadersRedacted(head.headers, prefix: "[StreamProxy] req hdr")

        // Build URLRequest with verbatim headers (minus hop-by-hop).
        var req = URLRequest(url: upstreamURL)
        req.httpMethod = head.method.rawValue
        for (name, value) in head.headers {
            if Self.hopByHop.contains(name.lowercased()) { continue }
            req.setValue(value, forHTTPHeaderField: name)
        }
        // Force Host to upstream — URLSession sets it itself, but be explicit.
        req.setValue("api.anthropic.com", forHTTPHeaderField: "Host")
        if !body.isEmpty {
            req.httpBody = body
        }

        // Per-request parser; only ever fed if upstream is SSE.
        guard let server = server else { return }
        let parser = SSEStreamParser(sessionId: sessionId) { [weak server] event in
            server?.dispatchEvent(event)
        }

        // Capture event loop + channel for the URLSession callback path —
        // those callbacks fire on URLSession's delegate queue, not this loop.
        nonisolated(unsafe) let ctx = context
        let loop = context.eventLoop

        guard let session = server.urlSession else {
            NSLog("[StreamProxy] URLSession unavailable")
            writeError(context: context, status: .internalServerError,
                       message: "Proxy not started")
            return
        }
        let task = session.dataTask(with: req)
        ProxyURLSessionDelegate.shared.register(
            task: task,
            sessionId: sessionId,
            parser: parser,
            onResponse: { [weak self] response in
                loop.execute { self?.writeResponseHead(context: ctx, response: response) }
            },
            onData: { [weak self] data in
                loop.execute { self?.writeResponseBody(context: ctx, data: data) }
            },
            onComplete: { [weak self] error in
                loop.execute { self?.writeResponseEnd(context: ctx, error: error) }
            }
        )
        task.resume()
    }

    // MARK: Response writing (event loop)

    private func writeResponseHead(context: ChannelHandlerContext, response: HTTPURLResponse) {
        guard channelIsActive else { return }
        var headers = HTTPHeaders()
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String,
                  let value = rawValue as? String else { continue }
            let lower = name.lowercased()
            if Self.hopByHop.contains(lower) { continue }
            // URLSession transparently auto-decompresses gzip/deflate/br.
            // The body bytes we receive in `didReceive data:` are ALREADY
            // decoded. Forwarding the original Content-Encoding would make
            // Claude Code try to gunzip already-plain bytes → ZlibError.
            // Same logic for Content-Length: stripped because we re-frame
            // as Transfer-Encoding: chunked anyway, and the original length
            // was for the still-encoded body which no longer matches.
            if lower == "content-encoding" { continue }
            headers.add(name: name, value: value)
        }
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        // Use chunked transfer for streaming bodies — drop any
        // upstream Content-Length since we re-frame.
        headers.remove(name: "Content-Length")
        headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        responseHeadSent = true
        context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
    }

    private func writeResponseBody(context: ChannelHandlerContext, data: Data) {
        guard channelIsActive, responseHeadSent else { return }
        var buf = context.channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
    }

    private func writeResponseEnd(context: ChannelHandlerContext, error: Error?) {
        if let error = error {
            NSLog("[StreamProxy] upstream error: %@", "\(error)")
        }
        guard channelIsActive else { return }
        // If the upstream task failed BEFORE delivering an HTTPURLResponse,
        // we never wrote .head — sending .end first would assert inside
        // NIO's HTTPServerProtocolErrorHandler and crash the proxy. Synthesize
        // a 502 head + end so the pipeline transitions cleanly.
        if !responseHeadSent {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: "0")
            let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
            responseHeadSent = true
            context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    // MARK: Helpers

    private func writeError(context: ChannelHandlerContext,
                            status: HTTPResponseStatus,
                            message: String) {
        let payload: [String: Any] = ["error": ["type": "proxy_error", "message": message]]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buf = context.channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func logHeadersRedacted(_ headers: HTTPHeaders, prefix: String) {
        for (name, value) in headers {
            let lower = name.lowercased()
            let isSecret = Self.secretMarkers.contains(where: { lower.contains($0) })
            if isSecret {
                NSLog("%@ %@: <redacted len=%d>", prefix, name, value.count)
            } else {
                NSLog("%@ %@: %@", prefix, name, value)
            }
        }
    }
}

// MARK: - URLSession delegate

/// Singleton URLSessionDataDelegate that fans `urlSession(_:dataTask:...)`
/// callbacks out to per-task closures registered by the inbound handler.
/// Singleton because URLSession requires the delegate at session-init time
/// and we have a single proxy session for the whole process.
private final class ProxyURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ProxyURLSessionDelegate()

    private struct PerTask {
        let sessionId: String
        let parser: SSEStreamParser
        let onResponse: (HTTPURLResponse) -> Void
        let onData: (Data) -> Void
        let onComplete: (Error?) -> Void
        var sawSSE: Bool
    }

    private let lock = NSLock()
    private var tasks: [Int: PerTask] = [:]

    func register(task: URLSessionDataTask,
                  sessionId: String,
                  parser: SSEStreamParser,
                  onResponse: @escaping (HTTPURLResponse) -> Void,
                  onData: @escaping (Data) -> Void,
                  onComplete: @escaping (Error?) -> Void) {
        let entry = PerTask(
            sessionId: sessionId,
            parser: parser,
            onResponse: onResponse,
            onData: onData,
            onComplete: onComplete,
            sawSSE: false
        )
        lock.lock()
        tasks[task.taskIdentifier] = entry
        lock.unlock()
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let contentType = (http.allHeaderFields["Content-Type"] as? String)
            ?? (http.allHeaderFields["content-type"] as? String)
            ?? ""
        let isSSE = contentType.lowercased().hasPrefix("text/event-stream")

        lock.lock()
        if var entry = tasks[dataTask.taskIdentifier] {
            entry.sawSSE = isSSE
            tasks[dataTask.taskIdentifier] = entry
            let cb = entry.onResponse
            lock.unlock()
            cb(http)
        } else {
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        guard let entry = tasks[dataTask.taskIdentifier] else { lock.unlock(); return }
        let cb = entry.onData
        let parser = entry.parser
        let isSSE = entry.sawSSE
        lock.unlock()

        cb(data)
        if isSSE {
            parser.feed(data)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        guard let entry = tasks.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        let cb = entry.onComplete
        let parser = entry.parser
        let isSSE = entry.sawSSE
        lock.unlock()

        if isSSE { parser.finish() }
        cb(error)
    }
}
