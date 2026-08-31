import Foundation

/// Events emitted by `SSEStreamParser` while observing an Anthropic SSE
/// response. Each event corresponds to a `tool_use` content block being
/// composed by Claude — text blocks are intentionally ignored.
///
/// The `sessionId` carried on every case is the bridge session id extracted
/// from the proxy URL path (`/sess/<sessionId>/v1/...`), letting downstream
/// consumers route the intent to the right bound terminal/Chrome pair.
enum ToolStreamEvent {
    /// A tool_use content block has just begun. Carries the tool name as
    /// soon as Anthropic announces it (before any input deltas arrive).
    case composeStart(sessionId: String, toolName: String, contentBlockIndex: Int)

    /// `partialJSON` is the cumulative concatenation of all `partial_json`
    /// fragments seen so far for this content block. Caller can render
    /// progressively or wait for `composeStop`.
    case composeDelta(sessionId: String, toolName: String, partialJSON: String)

    /// Called on content_block_stop for a tool_use block. `fullArgs` is the
    /// full reconstructed JSON string (may not always be valid JSON if the
    /// stream was truncated mid-block).
    case composeStop(sessionId: String, toolName: String, fullArgs: String)
}
