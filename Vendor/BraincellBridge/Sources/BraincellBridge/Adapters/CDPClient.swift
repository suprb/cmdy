import Foundation

/// Chrome DevTools Protocol client using JSON-RPC over WebSocket.
actor CDPClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var messageId = 0
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var eventHandlers: [String: [([String: Any]) -> Void]] = [:]
    private var isConnected = false

    enum CDPError: Error, LocalizedError {
        case notConnected
        case connectionFailed(String)
        case requestFailed(String)
        case timeout
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to Chrome"
            case .connectionFailed(let msg): return "Connection failed: \(msg)"
            case .requestFailed(let msg): return "CDP request failed: \(msg)"
            case .timeout: return "Request timed out"
            case .invalidResponse: return "Invalid CDP response"
            }
        }
    }

    // MARK: - Connection

    func connect(to url: URL) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)

        guard let session = session else {
            throw CDPError.connectionFailed("Failed to create URLSession")
        }

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true

        // Start receive loop
        Task { await receiveLoop() }

        NSLog("[CDP] Connected to %@", url.absoluteString)
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false

        // Fail all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: CDPError.notConnected)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Sending

    func send(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        guard isConnected, webSocketTask != nil else {
            throw CDPError.notConnected
        }

        messageId += 1
        let id = messageId

        var message: [String: Any] = ["id": id, "method": method]
        if let params = params {
            message["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        let string = String(data: data, encoding: .utf8)!

        try await webSocketTask?.send(.string(string))

        // Wait for response with timeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            self.storeContinuation(id: id, continuation: continuation)
        }
    }

    private func storeContinuation(id: Int, continuation: CheckedContinuation<[String: Any], Error>) {
        pendingRequests[id] = continuation

        // 30 second timeout
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if let cont = pendingRequests.removeValue(forKey: id) {
                cont.resume(throwing: CDPError.timeout)
            }
        }
    }

    /// Fire-and-forget send (no response needed)
    func sendNoWait(method: String, params: [String: Any]? = nil) throws {
        guard isConnected, let ws = webSocketTask else {
            throw CDPError.notConnected
        }

        messageId += 1
        var message: [String: Any] = ["id": messageId, "method": method]
        if let params = params {
            message["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        let string = String(data: data, encoding: .utf8)!
        ws.send(.string(string)) { _ in }
    }

    // MARK: - Events

    func subscribe(to event: String, handler: @escaping ([String: Any]) -> Void) {
        eventHandlers[event, default: []].append(handler)
    }

    // MARK: - Receive Loop

    /// Called once when the WebSocket dies unexpectedly (page closed, Chrome quit,
    /// network blip). Set by `ChromeAdapter` so the popover can flip to its
    /// "Reopen Chrome" state even when Chrome's process stays alive in the
    /// background after the user closed the last window (so `Process.terminationHandler`
    /// alone wouldn't fire).
    private var onDisconnected: (() -> Void)?

    func setOnDisconnected(_ handler: @escaping () -> Void) {
        self.onDisconnected = handler
    }

    private func receiveLoop() async {
        guard let ws = webSocketTask else { return }

        while isConnected {
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isConnected {
                    NSLog("[CDP] WebSocket receive error: %@", String(describing: error))
                    isConnected = false
                    let cb = onDisconnected
                    onDisconnected = nil   // fire at most once per connection
                    cb?()
                }
                break
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Response to a request
        if let id = json["id"] as? Int {
            if let continuation = pendingRequests.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    continuation.resume(throwing: CDPError.requestFailed(message))
                } else {
                    let result = json["result"] as? [String: Any] ?? [:]
                    continuation.resume(returning: result)
                }
            }
            return
        }

        // Event
        if let method = json["method"] as? String,
           let handlers = eventHandlers[method] {
            let params = json["params"] as? [String: Any] ?? [:]
            for handler in handlers {
                handler(params)
            }
        }
    }
}
