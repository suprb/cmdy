import Foundation
import CmdyNative

// Public value types shared with the existing macOS surface. Engine state is native.
public enum TermCursorShape: Equatable, Sendable {
    case blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar
}

/// Mouse tracking modes, ordered by capability.
public enum MouseMode: Equatable, Sendable, CustomStringConvertible {
    case off
    case x10               // ?9 press only
    case vt200             // ?1000 press+release
    case buttonEvent       // ?1002 + drag
    case anyEvent          // ?1003 + motion
    public var description: String {
        switch self {
        case .off: return "off"
        case .x10: return "x10"
        case .vt200: return "vt200"
        case .buttonEvent: return "buttonEventTracking"
        case .anyEvent: return "anyEvent"
        }
    }
}

public enum MouseProtocolEncoding: Equatable, Sendable {
    case x10               // legacy bytes
    case utf8              // ?1005
    case sgr               // ?1006
    case urxvt             // ?1015
}


public struct CoreGridSnapshot: Sendable {
    public let rows: Int
    public let cols: Int
    public let bufferLineCount: Int
    /// Cumulative rows discarded before local buffer row 0. Local engine
    /// coordinates still rebase; renderers can add this to obtain a stable row.
    public let retainedRowOrigin: Int
    public let displayTopRow: Int
    public let liveTopRow: Int
    public let cursorRow: Int
    public let cursorCol: Int
    public let cursorHidden: Bool
    public let cursorStyle: TermCursorShape
    public let isAlternateBuffer: Bool
}

/// Immutable row storage published from the terminal worker. Native rows share
/// copy-on-write cell storage; Swift cells are projected only for API readers.
private final class NativeSnapshotLine: @unchecked Sendable {
    let handle: OpaquePointer
    init(retainingFrozen source: OpaquePointer) {
        handle = cmdy_zig_line_retain(source)!
    }
    init(_ source: OpaquePointer) {
        guard let frozen = cmdy_zig_line_render_snapshot(source) else {
            preconditionFailure("Cannot allocate native terminal snapshot")
        }
        handle = frozen
    }
    init(cells: [Cell], isWrapped: Bool, renderMode: LineRenderMode, version: UInt64) {
        var extras: [UInt32] = []
        let values = cells.map { cell -> CmdyZigStoredCell in
            var value = CmdyZigStoredCell()
            value.cell = nativeCell(cell)
            value.cluster_offset = .max
            if let cluster = cell.clusterExtras {
                guard let offset = UInt32(exactly: extras.count), offset != .max,
                      let count = UInt32(exactly: cluster.count) else {
                    preconditionFailure("Native snapshot cluster data exceeds representation bounds")
                }
                value.cluster_offset = offset
                value.cluster_count = count
                extras.append(contentsOf: cluster)
            }
            return value
        }
        let mode: UInt8
        switch renderMode {
        case .single: mode = 0
        case .doubleWidth: mode = 1
        case .doubledTop: mode = 2
        case .doubledDown: mode = 3
        }
        let frozen = values.withUnsafeBufferPointer { values in
            extras.withUnsafeBufferPointer { extras in
                cmdy_zig_line_snapshot_from_cells(values.baseAddress, values.count,
                    extras.baseAddress, extras.count, isWrapped ? 1 : 0, mode, version)
            }
        }
        guard let frozen else { preconditionFailure("Cannot allocate native terminal snapshot") }
        handle = frozen
    }
    deinit { cmdy_zig_line_release(handle) }
}

public struct CoreLineSnapshot: Sendable {
    private let nativeStorage: NativeSnapshotLine
    public var cells: [Cell] { withExtendedLifetime(nativeStorage) { Line.copyCells(from: nativeStorage.handle) } }
    public let isWrapped: Bool
    public let renderMode: LineRenderMode
    public let images: [CoreLineImageSnapshot]
    public let version: UInt64

    public init(cells: [Cell], isWrapped: Bool, renderMode: LineRenderMode,
                images: [CoreLineImageSnapshot], version: UInt64) {
        nativeStorage = NativeSnapshotLine(cells: cells, isWrapped: isWrapped,
                                           renderMode: renderMode, version: version)
        self.isWrapped = isWrapped
        self.renderMode = renderMode
        self.images = images
        self.version = version
    }

    init(line: Line, images: [CoreLineImageSnapshot]) {
        self.init(nativeLine: line.native, images: images)
    }

    init(nativeLine: OpaquePointer, images: [CoreLineImageSnapshot]) {
        self.init(storage: NativeSnapshotLine(nativeLine), images: images)
    }

    init(frozenNativeLine: OpaquePointer, images: [CoreLineImageSnapshot]) {
        self.init(storage: NativeSnapshotLine(retainingFrozen: frozenNativeLine), images: images)
    }

    private init(storage: NativeSnapshotLine, images: [CoreLineImageSnapshot]) {
        nativeStorage = storage
        let frozen = nativeStorage.handle
        isWrapped = cmdy_zig_line_metadata(frozen, 0) != 0
        switch cmdy_zig_line_metadata(frozen, 2) {
        case 1: renderMode = .doubleWidth
        case 2: renderMode = .doubledTop
        case 3: renderMode = .doubledDown
        default: renderMode = .single
        }
        self.images = images
        version = cmdy_zig_line_version(frozen)
    }

    /// Borrow immutable native storage without projecting a Swift cell array.
    /// The renderer must not retain or mutate the pointer outside this call.
    @_spi(CmdyApp) public func withNativeLine<T>(_ body: (UnsafeRawPointer) throws -> T) rethrows -> T {
        try withExtendedLifetime(nativeStorage) { try body(UnsafeRawPointer(nativeStorage.handle)) }
    }

    @_spi(CmdyApp) public var nativeCellCount: Int {
        withExtendedLifetime(nativeStorage) { cmdy_zig_line_count(nativeStorage.handle) }
    }
}

/// One native owner for a bounded row window, including frozen image geometry.
/// The Swift row projections share these exact immutable rows. No live buffer
/// or terminal handle is retained or accessed after construction.
final class NativeSnapshotRows: @unchecked Sendable {
    let handle: OpaquePointer
    init(buffer: OpaquePointer, first: Int, count: Int) {
        var status: Int32 = 0
        guard let handle = cmdy_zig_buffer_snapshot_capture(buffer, first, count, &status) else {
            preconditionFailure("Cannot capture native terminal viewport (status \(status))")
        }
        self.handle = handle
    }
    deinit { cmdy_zig_buffer_snapshot_release(handle) }

    func withLine<T>(at index: Int, _ body: (OpaquePointer) -> T) -> T {
        withExtendedLifetime(self) {
            guard let line = cmdy_zig_buffer_snapshot_line(handle, index) else {
                preconditionFailure("Missing captured native row")
            }
            return body(line)
        }
    }
}

/// Frozen global graphics metadata with shared immutable native payloads.
/// The mutable registry and its Swift image identity observers stay on the
/// terminal owner. Empty registries need no additional allocation.
final class NativeSnapshotGraphics: @unchecked Sendable {
    let handle: OpaquePointer
    init?(store: OpaquePointer) {
        guard cmdy_zig_graphics_get(store, 3) != 0 || cmdy_zig_graphics_get(store, 4) != 0 else { return nil }
        var status: UInt32 = 0
        guard let handle = cmdy_render_graphics_input_capture(store, &status) else {
            preconditionFailure("Cannot capture native terminal graphics (status \(status))")
        }
        self.handle = handle
    }
    deinit { cmdy_render_graphics_input_release(handle) }
}

/// Immutable form of a line image. `LineImage` itself is mutable during
/// reflow, so renderer snapshots must not retain the live object.
public struct CoreLineImageSnapshot: Sendable {
    public let renderIdentity: UUID
    public let payload: LineImage.Payload
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let col: Int
    public let kittyIsKitty: Bool
    public let kittyImageId: UInt32?
    public let kittyPlacementId: UInt32?
    public let kittyZIndex: Int
    public let kittyPixelOffsetX: Int
    public let kittyPixelOffsetY: Int

    public init(renderIdentity: UUID, payload: LineImage.Payload,
                pixelWidth: Int, pixelHeight: Int,
                col: Int, kittyIsKitty: Bool, kittyImageId: UInt32?,
                kittyPlacementId: UInt32?, kittyZIndex: Int,
                kittyPixelOffsetX: Int, kittyPixelOffsetY: Int) {
        self.renderIdentity = renderIdentity
        self.payload = payload
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.col = col
        self.kittyIsKitty = kittyIsKitty
        self.kittyImageId = kittyImageId
        self.kittyPlacementId = kittyPlacementId
        self.kittyZIndex = kittyZIndex
        self.kittyPixelOffsetX = kittyPixelOffsetX
        self.kittyPixelOffsetY = kittyPixelOffsetY
    }
}

public struct CoreKittyPlacementSnapshot: Sendable {
    public let imageId: UInt32
    public let placementId: UInt32
    public let col: Int
    public let row: Int
    public let cols: Int
    public let rows: Int
    public let zIndex: Int
    public let pixelOffsetX: Int
    public let pixelOffsetY: Int
    public let isVirtual: Bool
    public let isAlternateBuffer: Bool
}

public struct CoreKittyImageSnapshot: Sendable {
    public let id: UInt32
    public let payload: LineImage.Payload
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// Everything a frame and the input router need from one coherent parser
/// generation. Only a bounded window around the viewport is copied; search,
/// block export, and other cold whole-buffer operations stay on the model
/// queue.
public struct CoreTerminalSnapshot: Sendable {
    /// Assigned by the serial app-model owner before publishing this value.
    @_spi(CmdyApp) public var modelPublicationGeneration: UInt64 = 0
    public let grid: CoreGridSnapshot
    public let firstLineRow: Int
    public let lines: [CoreLineSnapshot]
    let nativeRows: NativeSnapshotRows
    let nativeGraphics: NativeSnapshotGraphics?
    public let dirtyRows: ClosedRange<Int>?

    public let applicationCursorKeys: Bool
    public let bracketedPaste: Bool
    public let focusReporting: Bool
    public let mouseMode: MouseMode
    public let mouseProtocol: MouseProtocolEncoding
    public let kittyKeyboardFlags: Int

    public let kittyPlacements: [CoreKittyPlacementSnapshot]
    public let kittyImages: [UInt32: CoreKittyImageSnapshot]
    public let kittyNextImageId: UInt32
    public let kittyNextPlacementId: UInt32

    public func line(absolute row: Int) -> CoreLineSnapshot? {
        let index = row - firstLineRow
        return index >= 0 && index < lines.count ? lines[index] : nil
    }

    /// Lend one immutable row-window handle without traversing Swift rows.
    /// Native consumers must retain it before the closure returns if they need
    /// asynchronous access. Mutating any borrowed row is forbidden.
    @_spi(CmdyApp) public func withNativeRows<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try withExtendedLifetime(nativeRows) { try body(nativeRows.handle) }
    }

    /// Borrow frozen graphics without traversing Swift images or copying bytes.
    /// Nil means the captured registry is empty. Retain for asynchronous use.
    @_spi(CmdyApp) public func withNativeGraphics<T>(_ body: (OpaquePointer?) throws -> T) rethrows -> T {
        try withExtendedLifetime(nativeGraphics) { try body(nativeGraphics?.handle) }
    }
}
