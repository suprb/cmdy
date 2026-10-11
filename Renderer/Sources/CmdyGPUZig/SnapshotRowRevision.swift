import CmdyNative

@_spi(CmdyApp)
public struct SnapshotRowRevision: Equatable {
    public let content: UInt64
    public let context: UInt64
    public init(content: UInt64, context: UInt64) {
        self.content = content
        self.context = context
    }
    var native: CmdyRenderRevision { .init(content: content, context: context) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        cmdy_render_revision_equal(lhs.native, rhs.native)
    }
}

@_spi(CmdyApp)
@MainActor
public protocol SnapshotRowRevisionSource: MetalRenderSource {
    func snapshotRowRevision(forRow row: Int) -> SnapshotRowRevision?
}
