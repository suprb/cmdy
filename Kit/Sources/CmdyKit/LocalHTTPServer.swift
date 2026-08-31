import Foundation
import ProductIdentity

/// Tiny dependency-free HTTP/1.1 server on 127.0.0.1 — the transport behind
/// cmdy's plugin API. BSD sockets + DispatchSources; one short-lived
/// connection per request (Connection: close); handlers run on the main
/// queue when they touch AppKit state. Socket I/O runs per connection so one
/// slow local client cannot stall every other plugin request.
final class LocalHTTPServer {
    typealias Handler = (PluginHTTPRequest) -> PluginHTTPResponse

    private struct Route {
        let method: String
        let path: String
        let prefix: Bool
        let runsOnMain: Bool
        let handler: Handler
    }

    private(set) var port: Int = 0
    /// Bearer token required on every route except /health.
    let authToken = UUID().uuidString

    private struct PluginCredential {
        let id: String
        let name: String
        let capabilities: Set<ExtensionCapability>
    }
    private var pluginCredentials: [String: PluginCredential] = [:]
    private var pluginAuthenticationHandler: ((String) -> Void)?
    private let credentialLock = NSLock()

    /// Called after a per-launch Extension credential authenticates. The
    /// lifecycle owner uses this as the readiness boundary: a child process is
    /// only "ready" once it has connected back to the host successfully.
    var onPluginAuthenticated: ((String) -> Void)? {
        get {
            credentialLock.lock()
            defer { credentialLock.unlock() }
            return pluginAuthenticationHandler
        }
        set {
            credentialLock.lock()
            pluginAuthenticationHandler = newValue
            credentialLock.unlock()
        }
    }

    private var routes: [Route] = []
    private let routeLock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "cmdy.plugin-http")
    private let connectionQueue = DispatchQueue(label: "cmdy.plugin-http.connections",
                                                qos: .userInitiated,
                                                attributes: .concurrent)
    private let connectionSlots = DispatchSemaphore(value: 64)
    private let debugConnections =
        ProductIdentity.current.environmentValue("HTTP_DEBUG") == "1"

    /// Long-lived SSE endpoints (the SDK event stream) + their subscribers.
    private enum StreamRequirement {
        case none
        case capability(ExtensionCapability)
    }
    private var streamPaths: [String: StreamRequirement] = [:]
    private struct Subscriber {
        let fd: Int32
        let owner: String?
    }
    private var subscribers: [Subscriber] = []
    /// Accessed only on `queue`, together with `subscribers`.
    private var acceptsSubscribers = false
    private let subscriberCountLock = NSLock()
    private var subscriberCount = 0

    var hasEventSubscribers: Bool {
        subscriberCountLock.lock()
        let result = subscriberCount > 0
        subscriberCountLock.unlock()
        return result
    }

    private func publishSubscriberCount() {
        subscriberCountLock.lock()
        subscriberCount = subscribers.count
        subscriberCountLock.unlock()
    }

    /// External plugins receive a unique token for each launch. Besides
    /// limiting a leaked token to one process lifetime, this lets the host
    /// tear down exactly the commands, hotkeys, panels, and insets that launch
    /// created. The discovery-file token remains the ownerless automation key.
    func registerPluginCredential(_ token: String, id: String, name: String,
                                  capabilities: Set<ExtensionCapability> = Set(ExtensionCapability.allCases)) {
        credentialLock.lock()
        pluginCredentials[token] = PluginCredential(id: id, name: name,
                                                    capabilities: capabilities)
        credentialLock.unlock()
    }

    func revokePluginCredential(_ token: String) {
        credentialLock.lock()
        pluginCredentials[token] = nil
        credentialLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.subscribers.removeAll { subscriber in
                guard subscriber.owner == token else { return false }
                close(subscriber.fd)
                return true
            }
            self.publishSubscriberCount()
        }
    }

    func route(_ method: String, _ path: String, _ handler: @escaping Handler) {
        routeLock.lock()
        routes.append(Route(method: method.uppercased(), path: path,
                            prefix: path.hasSuffix("/"), runsOnMain: true,
                            handler: handler))
        routeLock.unlock()
    }

    /// For handlers that perform no AppKit access and may block on network or
    /// disk I/O. They run on a connection worker instead of freezing terminal UI.
    func backgroundRoute(_ method: String, _ path: String, _ handler: @escaping Handler) {
        routeLock.lock()
        routes.append(Route(method: method.uppercased(), path: path,
                            prefix: path.hasSuffix("/"), runsOnMain: false,
                            handler: handler))
        routeLock.unlock()
    }

    /// Register a GET path that stays open as a Server-Sent-Events stream.
    func streamRoute(_ path: String, capability: ExtensionCapability? = nil) {
        routeLock.lock()
        streamPaths[path] = capability.map(StreamRequirement.capability)
            ?? StreamRequirement.none
        routeLock.unlock()
    }

    /// Push one event to every connected stream subscriber (drops dead ones).
    func broadcast(_ event: [String: Any], toOwner owner: String? = nil,
                   privateDelivery: Bool = false) {
        guard hasEventSubscribers else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: event) else { return }
        var frame = Data("data: ".utf8)
        frame.append(json)
        frame.append(Data("\n\n".utf8))
        queue.async { [weak self] in
            guard let self, !self.subscribers.isEmpty else { return }
            self.subscribers.removeAll { subscriber in
                if privateDelivery {
                    guard subscriber.owner == owner else { return false }
                } else if let owner,
                          subscriber.owner != owner && subscriber.owner != nil {
                    return false
                }
                let alive = self.writeAll(fd: subscriber.fd, data: frame)
                if !alive { close(subscriber.fd) }
                return !alive
            }
            self.publishSubscriberCount()
        }
    }

    /// Bind 127.0.0.1 on the first free port at/after `preferredPort`.
    func start(preferredPort: UInt16 = 4664) {
        let firstPort = Int(preferredPort)
        for rawPort in firstPort..<min(65_536, firstPort + 128) {
            let candidate = UInt16(rawPort)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 64) == 0 else { close(fd); continue }
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                close(fd)
                continue
            }
            listenFD = fd
            port = Int(candidate)
            break
        }
        guard listenFD >= 0 else {
            NSLog("cmdy: plugin HTTP server failed to bind")
            return
        }
        queue.sync { acceptsSubscribers = true }
        let fd = listenFD
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(from: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        NSLog("cmdy: plugin API listening on 127.0.0.1:%d", port)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        port = 0
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptsSubscribers = false
            self.subscribers.forEach { close($0.fd) }
            self.subscribers.removeAll()
            self.publishSubscriberCount()
        }
    }

    private func acceptPending(from listenFD: Int32) {
        // A DispatchSource read event is edge/coalescing based: accepting one
        // socket can leave the listener readable without another callback. A
        // nonblocking listener must be drained through EAGAIN every time, or a
        // launch burst strands random Extension registrations in the backlog.
        var acceptedCount = 0
        if debugConnections {
            NSLog("cmdy HTTP: accept event (flags=%d)", fcntl(listenFD, F_GETFL))
        }
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if debugConnections {
                    NSLog("cmdy HTTP: accept drained %d (errno=%d)",
                          acceptedCount, errno)
                }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            acceptedCount += 1
            // Darwin inherits O_NONBLOCK from the listening socket. Request
            // workers intentionally use bounded blocking reads, so clear it on
            // each accepted connection before handing the descriptor off.
            let acceptedFlags = fcntl(fd, F_GETFL)
            guard acceptedFlags >= 0,
                  fcntl(fd, F_SETFL, acceptedFlags & ~O_NONBLOCK) >= 0 else {
                close(fd)
                continue
            }
            // A dead subscriber must not SIGPIPE the whole app.
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
            // Bound each connection even though it has an independent worker.
            var tv = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))
            guard connectionSlots.wait(timeout: .now()) == .success else {
                close(fd)
                continue
            }
            let slots = connectionSlots
            connectionQueue.async { [weak self, slots] in
                defer { slots.signal() }
                let keepOpen = self?.handle(fd: fd) ?? false
                if !keepOpen { close(fd) }
            }
        }
    }

    @discardableResult
    private func handle(fd: Int32) -> Bool {
        guard let (head, body) = readRequest(fd: fd) else { return false }
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return false }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1].split(separator: "?")[0])

        // Auth: every route except /health needs an exact bearer token. A
        // plugin token carries process ownership into the request; the root
        // discovery token intentionally has no plugin owner.
        var pluginOwner: String?
        var pluginID: String?
        var pluginName: String?
        var extensionCapabilities: Set<ExtensionCapability>?
        var authenticationCompleted: (() -> Void)?
        if path != "/health" {
            let presented = lines.compactMap { line -> String? in
                let text = String(line)
                let lower = text.lowercased()
                if lower.hasPrefix("authorization:") {
                    let value = text.dropFirst("authorization:".count)
                        .trimmingCharacters(in: .whitespaces)
                    guard value.lowercased().hasPrefix("bearer ") else { return nil }
                    return String(value.dropFirst("bearer ".count))
                }
                if lower.hasPrefix("x-term64-token:") {
                    return text.dropFirst("x-term64-token:".count)
                        .trimmingCharacters(in: .whitespaces)
                }
                return nil
            }.first
            guard let presented else {
                write(fd: fd, status: 401, json: ["error": "missing or invalid token"])
                return false
            }
            if presented != authToken {
                credentialLock.lock()
                let credential = pluginCredentials[presented]
                let authenticationHandler = pluginAuthenticationHandler
                credentialLock.unlock()
                guard let credential else {
                    write(fd: fd, status: 401, json: ["error": "missing or invalid token"])
                    return false
                }
                pluginOwner = presented
                pluginID = credential.id
                pluginName = credential.name
                extensionCapabilities = credential.capabilities
                authenticationCompleted = { authenticationHandler?(presented) }
            } else if presented.isEmpty {
                write(fd: fd, status: 401, json: ["error": "missing or invalid token"])
                return false
            }
        }

        // SSE stream: send the header, greet, and keep the socket for pushes.
        if method == "GET", let required = streamCapability(path) {
            if let capability = required,
               let granted = extensionCapabilities,
               !granted.contains(capability) {
                write(fd: fd, status: 403,
                      json: ["error": "extension capability required: \(capability.rawValue)"])
                return false
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                     + "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
                     + "data: {\"kind\":\"hello\"}\n\n"
            let header = Data(head.utf8)
            let established = queue.sync {
                guard acceptsSubscribers,
                      writeAll(fd: fd, data: header),
                      makeNonBlocking(fd: fd) else { return false }
                subscribers.append(Subscriber(fd: fd, owner: pluginOwner))
                publishSubscriberCount()
                return true
            }
            if established { authenticationCompleted?() }
            return established
        }

        var response = PluginHTTPResponse.notFound("no route for \(method) \(path)")
        if let route = matchingRoute(method: method, path: path) {
            if route.prefix {
                let request = PluginHTTPRequest(method: method, path: path,
                                                pathTail: String(path.dropFirst(route.path.count)),
                                                body: body, pluginOwner: pluginOwner,
                                                pluginID: pluginID, pluginName: pluginName,
                                                extensionCapabilities: extensionCapabilities)
                response = route.runsOnMain
                    ? dispatchToMain(route.handler, request) : route.handler(request)
            } else {
                let request = PluginHTTPRequest(method: method, path: path, pathTail: "",
                                                body: body, pluginOwner: pluginOwner,
                                                pluginID: pluginID, pluginName: pluginName,
                                                extensionCapabilities: extensionCapabilities)
                response = route.runsOnMain
                    ? dispatchToMain(route.handler, request) : route.handler(request)
            }
        }
        write(fd: fd, status: response.status, json: response.json)
        authenticationCompleted?()
        return false
    }

    /// The outer optional distinguishes an unregistered path from a stream
    /// that intentionally has no capability requirement.
    private func streamCapability(_ path: String) -> ExtensionCapability?? {
        routeLock.lock()
        defer { routeLock.unlock() }
        guard let requirement = streamPaths[path] else { return nil }
        switch requirement {
        case .none: return .some(nil)
        case .capability(let capability): return .some(capability)
        }
    }

    private func matchingRoute(method: String, path: String) -> Route? {
        routeLock.lock()
        defer { routeLock.unlock() }
        return routes.first { route in
            route.method == method && (route.prefix ? path.hasPrefix(route.path) : path == route.path)
        }
    }

    private func dispatchToMain(_ handler: @escaping Handler, _ request: PluginHTTPRequest) -> PluginHTTPResponse {
        if Thread.isMainThread { return handler(request) }
        var out = PluginHTTPResponse.badRequest("handler failed")
        DispatchQueue.main.sync { out = handler(request) }
        return out
    }

    private func readRequest(fd: Int32) -> (head: String, body: Data)? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        var headEnd: Range<Data.Index>?
        // Read until the blank line, then honor Content-Length.
        while headEnd == nil {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            data.append(buf, count: n)
            headEnd = data.range(of: Data("\r\n\r\n".utf8))
            if data.count > 4_000_000 { return nil }
        }
        guard let headRange = headEnd,
              let head = String(data: data[..<headRange.lowerBound], encoding: .utf8) else { return nil }
        var contentLength = 0
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        // Reject an oversized (or absurd attacker-supplied) Content-Length
        // before buffering it — the body loop below would otherwise honor any
        // value and grow `body` to OOM. Plugin requests are small.
        if contentLength < 0 || contentLength > 16_000_000 { return nil }
        var body = Data(data[headRange.upperBound...])
        while body.count < contentLength {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            body.append(buf, count: n)
        }
        if body.count > contentLength {
            body.removeSubrange(contentLength..<body.count)
        }
        return (head, body)
    }

    private func write(fd: Int32, status: Int, json: Any) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 429: reason = "Too Many Requests"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        _ = writeAll(fd: fd, data: out)
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Streaming writes must never hold the subscriber queue behind a slow
    /// client. Once the greeting is sent, a full socket buffer drops that
    /// subscriber instead of delaying every other event and server shutdown.
    private func makeNonBlocking(fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
    }
}
