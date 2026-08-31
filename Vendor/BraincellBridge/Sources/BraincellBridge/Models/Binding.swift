import Foundation

/// A terminal session is bound to one target. The MCP server uses the binding to route
/// tool calls (sessionId → binding → target adapter).
struct SessionBinding: Codable, Identifiable, Equatable {
    var id: String { sessionId }
    let sessionId: String
    let target: Target
    let createdAt: Date
}
