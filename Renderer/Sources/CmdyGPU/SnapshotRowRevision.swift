/// App-only evidence that a row inside a conservative dirty span still has
/// exactly the same captured content and shaping inputs. Tokens are compared
/// only within one renderer/source lifetime; zero values opt out.
@_spi(CmdyApp)
public struct SnapshotRowRevision: Equatable {
    public let content: UInt64
    public let context: UInt64

    public init(content: UInt64, context: UInt64) {
        self.content = content
        self.context = context
    }
}

/// Optional immutable-snapshot contract for the Cmdy app. `content` must be a
/// unique row-content revision equal to `lineVersion(forRow:)`; `context` must
/// change whenever any effective input to `lineInfo` changes. Both refer to
/// the same capture established by `captureGrid`, never a newer live model.
/// Return nil for rows whose external payloads cannot satisfy that contract.
/// Explicit invalidation still discards the cache, and the renderer accepts
/// this shortcut only for complete, supported shared-text keys.
@_spi(CmdyApp)
@MainActor
public protocol SnapshotRowRevisionSource: MetalRenderSource {
    func snapshotRowRevision(forRow row: Int) -> SnapshotRowRevision?
}
