import Foundation

/// Tiny dependency-free HTTP/1.1 server on 127.0.0.1 — the transport behind
/// the chromium plugin's browser API. Same shape as cmdy's own
/// LocalHTTPServer (BSD sockets + DispatchSources, Connection: close, bearer
/// token on everything but /health), with one difference: handlers take a
/// `respond` completion instead of returning a value, because browser tools
/// finish asynchronously (the JS eval round-trip comes back through the CEF
/// console callback on the main thread — a synchronous main-queue handler
/// would deadlock waiting for it).
public final class BrowserHTTPServer {
    public struct Request {
        public let method: String
        public let path: String
        public let body: Data
        public var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    /// Called on the main queue. `respond` may be called once, from any thread.
    public typealias Handler = (Request, _ respond: @escaping (Int, Any) -> Void) -> Void

    public private(set) var port: Int = 0
    /// Bearer token required on every route except /health.
    public let authToken = UUID().uuidString

    public var handler: Handler?

    public init() {}

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "chromium.browser-http")
    private let connectionQueue = DispatchQueue(
        label: "chromium.browser-http.connections",
        qos: .userInitiated,
        attributes: .concurrent)
    private let connectionSlots = DispatchSemaphore(value: 64)
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 16 * 1024 * 1024

    /// Bind 127.0.0.1 on the first free port at/after `preferredPort`.
    /// Returns false when no port in the window was free.
    @discardableResult
    public func start(preferredPort: UInt16) -> Bool {
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
        guard listenFD >= 0 else { return false }
        let fd = listenFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(from: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        return true
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        port = 0
    }

    private func acceptPending(from listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            // Accepted sockets inherit O_NONBLOCK on Darwin. Workers below use
            // bounded blocking reads, so restore that behavior per connection.
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0,
                  fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
                close(fd)
                continue
            }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            guard connectionSlots.wait(timeout: .now()) == .success else {
                close(fd)
                continue
            }
            let slots = connectionSlots
            connectionQueue.async { [weak self, slots] in
                defer { slots.signal() }
                guard let self else {
                    close(fd)
                    return
                }
                self.handle(fd: fd)
            }
        }
    }

    private func handle(fd: Int32) {
        guard let (head, body) = readRequest(fd: fd) else { close(fd); return }
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { close(fd); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { close(fd); return }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1].split(separator: "?")[0])

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
                if lower.hasPrefix("x-cmdy-browser-token:") {
                    return text.dropFirst("x-cmdy-browser-token:".count)
                        .trimmingCharacters(in: .whitespaces)
                }
                return nil
            }.first
            guard presented == authToken, !authToken.isEmpty else {
                write(fd: fd, status: 401, json: ["error": "missing or invalid token"])
                close(fd)
                return
            }
        }

        guard let handler else {
            write(fd: fd, status: 503, json: ["error": "not ready"])
            close(fd)
            return
        }

        // The handler responds whenever the tool finishes; the completion
        // hops back to the socket queue and must fire exactly once.
        let request = Request(method: method, path: path, body: body)
        nonisolated(unsafe) var responded = false
        let respond: (Int, Any) -> Void = { [weak self] status, json in
            self?.queue.async {
                guard !responded else { return }
                responded = true
                self?.write(fd: fd, status: status, json: json)
                close(fd)
            }
        }
        DispatchQueue.main.async { handler(request, respond) }
    }

    private func readRequest(fd: Int32) -> (head: String, body: Data)? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            data.append(buf, count: n)
            headEnd = data.range(of: Data("\r\n\r\n".utf8))
            if headEnd == nil, data.count > Self.maxHeaderBytes { return nil }
        }
        guard let headRange = headEnd,
              let head = String(data: data[..<headRange.lowerBound], encoding: .utf8) else { return nil }
        var contentLength = 0
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else { return nil }
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
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 503: reason = "Service Unavailable"
        default: reason = "Bad Request"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
