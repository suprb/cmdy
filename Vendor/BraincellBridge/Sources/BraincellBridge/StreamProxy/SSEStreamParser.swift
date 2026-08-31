import Foundation

/// Stateful incremental parser for Anthropic's SSE message format. Feed
/// arbitrary chunks of bytes via `feed(_:)` — events fire as soon as a full
/// SSE event (event:/data:/blank-line) has been buffered.
///
/// Only `tool_use` content blocks are tracked. Text deltas are parsed but
/// discarded so we never accidentally surface user-facing prose as "intent".
///
/// All defensive: malformed JSON, missing fields, or unexpected event types
/// are silently ignored — the proxy must keep streaming bytes through to
/// Claude Code regardless of what we can or can't interpret.
final class SSEStreamParser {
    private let sessionId: String
    private let onEvent: (ToolStreamEvent) -> Void

    /// Per-tool_use-block state. Keyed by `index` from the Anthropic event.
    private struct BlockState {
        let toolName: String
        var accumulatedJSON: String
    }
    private var toolBlocks: [Int: BlockState] = [:]

    /// Buffer for incomplete UTF-8 lines that span `feed` calls. SSE may
    /// split a single line (or a single multi-line event) across TCP chunks.
    private var lineBuffer = Data()

    /// In-progress SSE event being assembled across consecutive non-blank
    /// lines. Cleared on every blank-line dispatch.
    private var currentEventName: String?
    private var currentDataLines: [String] = []

    /// Configure with the sessionId so emitted events carry it.
    init(sessionId: String, onEvent: @escaping (ToolStreamEvent) -> Void) {
        self.sessionId = sessionId
        self.onEvent = onEvent
    }

    /// Feed a chunk of response bytes (any size, any boundary).
    func feed(_ data: Data) {
        lineBuffer.append(data)

        // Pull complete lines (LF-terminated) out of the buffer. SSE allows
        // CRLF too — strip a trailing CR if present.
        while let nlIdx = lineBuffer.firstIndex(of: 0x0A) {
            var lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nlIdx)
            // Drop trailing CR.
            if lineData.last == 0x0D { lineData.removeLast() }
            // Advance buffer past the LF.
            lineBuffer.removeSubrange(lineBuffer.startIndex...nlIdx)

            let line = String(data: lineData, encoding: .utf8) ?? ""
            consume(line: line)
        }
    }

    /// Caller invokes when stream ends (closes any in-flight content block).
    func finish() {
        // If there's a partial line lingering in the buffer, attempt to
        // consume it — Anthropic events end with blank lines so anything
        // un-terminated is incomplete and safe to drop, but we still try.
        if !lineBuffer.isEmpty {
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            lineBuffer.removeAll(keepingCapacity: false)
            if !line.isEmpty { consume(line: line) }
        }
        // Flush any in-progress event (defensive — unlikely in practice).
        if currentEventName != nil || !currentDataLines.isEmpty {
            dispatchCurrentEvent()
        }
        // Emit composeStop for any tool_use blocks still open (truncated stream).
        for (_, state) in toolBlocks {
            onEvent(.composeStop(
                sessionId: sessionId,
                toolName: state.toolName,
                fullArgs: state.accumulatedJSON
            ))
        }
        toolBlocks.removeAll()
    }

    // MARK: - Line/Event handling

    private func consume(line: String) {
        // Blank line = event boundary.
        if line.isEmpty {
            dispatchCurrentEvent()
            return
        }
        // Comment line per SSE spec — ignore.
        if line.hasPrefix(":") { return }

        if let colonIdx = line.firstIndex(of: ":") {
            let field = String(line[..<colonIdx])
            var value = String(line[line.index(after: colonIdx)...])
            // SSE spec: a single leading space after the colon is ignored.
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event":
                currentEventName = value
            case "data":
                currentDataLines.append(value)
            default:
                // Unknown SSE field (id, retry, etc) — ignore.
                break
            }
        }
        // Lines without a colon are technically valid SSE field names with
        // empty values; Anthropic doesn't emit those, so ignore.
    }

    private func dispatchCurrentEvent() {
        defer {
            currentEventName = nil
            currentDataLines.removeAll(keepingCapacity: true)
        }
        guard !currentDataLines.isEmpty else { return }
        let dataString = currentDataLines.joined(separator: "\n")
        guard let dataBytes = dataString.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any] else {
            return
        }

        // Anthropic encodes the event type both in the SSE `event:` line and
        // in the JSON `type` field. Trust the JSON — it's authoritative and
        // robust to unusual framing.
        guard let type = json["type"] as? String else { return }

        switch type {
        case "content_block_start":
            handleContentBlockStart(json)
        case "content_block_delta":
            handleContentBlockDelta(json)
        case "content_block_stop":
            handleContentBlockStop(json)
        default:
            // message_start, message_delta, message_stop, ping, error, etc —
            // not our concern; we're only watching for tool_use composition.
            break
        }
    }

    private func handleContentBlockStart(_ json: [String: Any]) {
        guard let index = (json["index"] as? NSNumber)?.intValue,
              let block = json["content_block"] as? [String: Any],
              let blockType = block["type"] as? String,
              blockType == "tool_use",
              let name = block["name"] as? String else {
            return
        }
        toolBlocks[index] = BlockState(toolName: name, accumulatedJSON: "")
        onEvent(.composeStart(
            sessionId: sessionId,
            toolName: name,
            contentBlockIndex: index
        ))
    }

    private func handleContentBlockDelta(_ json: [String: Any]) {
        guard let index = (json["index"] as? NSNumber)?.intValue,
              var state = toolBlocks[index],
              let delta = json["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String,
              deltaType == "input_json_delta",
              let partial = delta["partial_json"] as? String else {
            return
        }
        state.accumulatedJSON.append(partial)
        toolBlocks[index] = state
        onEvent(.composeDelta(
            sessionId: sessionId,
            toolName: state.toolName,
            partialJSON: state.accumulatedJSON
        ))
    }

    private func handleContentBlockStop(_ json: [String: Any]) {
        guard let index = (json["index"] as? NSNumber)?.intValue,
              let state = toolBlocks[index] else {
            return
        }
        toolBlocks.removeValue(forKey: index)
        onEvent(.composeStop(
            sessionId: sessionId,
            toolName: state.toolName,
            fullArgs: state.accumulatedJSON
        ))
    }
}
