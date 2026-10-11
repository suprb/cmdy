import Foundation
import Synchronization

/// Independent positive-width bases, already validated by the engine.
struct OrdinaryUnicodeCell {
    let scalar: UInt32
    let width: Int8
}

/// DECDWL/DECDHL state of a row.
public enum LineRenderMode: Equatable, Sendable {
    case single, doubleWidth, doubledTop, doubledDown
}

/// An inline image attached to a buffer line (kitty / sixel / iTerm2).
/// The pixel payload stays encoded — the platform layer decodes; core only
/// tracks identity, geometry, and placement.
public final class LineImage: @unchecked Sendable {
    public enum Payload: Sendable {
        case png(Data)
        case rgba(bytes: [UInt8], width: Int, height: Int)
    }
    public let payload: Payload
    /// Stable renderer cache key that survives immutable snapshot publication.
    public let renderIdentity = UUID()
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Column where the image was attached.
    public var col: Int
    // Kitty placement bookkeeping (0/false for sixel/iTerm2 images).
    public var kittyIsKitty = false
    public var kittyImageId: UInt32?
    public var kittyPlacementId: UInt32?
    public var kittyZIndex = 0
    public var kittyPixelOffsetX = 0
    public var kittyPixelOffsetY = 0

    public init(payload: Payload, pixelWidth: Int, pixelHeight: Int, col: Int) {
        self.payload = payload
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.col = col
    }
}

/// One buffer row: cells + the flags that survive reflow.
public final class Line {
    private var cellStorage: [Cell]
    /// Conservative physical-storage flag. Plain ASCII rows keep this false,
    /// allowing hot writes to leave the already-nil cluster reference untouched
    /// instead of paying retain/release traffic for every cell.
    private var storageHasClusterExtras = false
    /// A recycled blank row can postpone its O(cols) clear until its backing
    /// cells are needed. Single-cell reads resolve the logical fill directly;
    /// PTY bursts can populate the row before full-row reads materialize it.
    private var deferredFill: Cell?
    /// Physical cells inside this range already contain post-clear writes;
    /// cells outside it still read as `deferredFill` until materialized.
    private var deferredValidRange: Range<Int>?
    public var cells: [Cell] {
        materializeDeferredFill()
        return cellStorage
    }
    /// True when this row is a soft-wrap continuation of the previous row.
    /// Logical (unwrapped) lines — the unit reflow and block anchors work
    /// in — are maximal runs of [unwrapped row, wrapped rows…].
    public var isWrapped: Bool { didSet { bumpVersion() } }
    /// Host-owned prose may wrap at word boundaries. PTY rows always keep
    /// traditional cell wrapping so terminal output remains byte-faithful.
    enum WrapStyle { case cells, words }
    var wrapStyle: WrapStyle = .cells
    public var renderMode: LineRenderMode = .single { didSet { bumpVersion() } }
    public var images: [LineImage]? { didSet { bumpVersion() } }

    /// A globally-unique stamp bumped on every content mutation. The GPU
    /// renderer stores it per cached row and rebuilds when it changes — so a
    /// missed dirty-mark can never leave a stale (blank) row on screen. The
    /// stamp is global (not per-line) so a row that a scroll swaps for a
    /// different Line object also reads as changed.
    public private(set) var version: UInt64 = 0
    private static let versionCounter = Atomic<UInt64>(0)
    @inline(__always) func bumpVersion() {
        version = Line.versionCounter.wrappingAdd(1, ordering: .relaxed).newValue
    }

    public init(cols: Int, fill: Cell = Cell()) {
        cellStorage = Array(repeating: fill, count: cols)
        storageHasClusterExtras = fill.clusterExtras != nil
        isWrapped = false
        bumpVersion()
    }

    public init(cells: [Cell], isWrapped: Bool) {
        cellStorage = cells
        storageHasClusterExtras = cells.contains { $0.clusterExtras != nil }
        self.isWrapped = isWrapped
        bumpVersion()
    }

    init(fullASCII bytes: ArraySlice<UInt8>, attribute: CellAttribute,
         linkId: UInt16, isWrapped: Bool) {
        cellStorage = Array(unsafeUninitializedCapacity: bytes.count) { buffer, count in
            guard let base = buffer.baseAddress else { count = 0; return }
            var cell = Cell(scalar: 0, width: 1, attribute: attribute, linkId: linkId)
            var target = base
            for byte in bytes {
                cell.scalar = UInt32(byte)
                target.initialize(to: cell)
                target = target.advanced(by: 1)
            }
            count = bytes.count
        }
        storageHasClusterExtras = false
        self.isWrapped = isWrapped
        bumpVersion()
    }

    init(ascii bytes: ArraySlice<UInt8>, cols: Int, fill: Cell,
         attribute: CellAttribute, linkId: UInt16, isWrapped: Bool) {
        precondition(bytes.count <= cols)
        cellStorage = Array(unsafeUninitializedCapacity: cols) { buffer, count in
            guard let base = buffer.baseAddress else { count = 0; return }
            var source = bytes.startIndex
            var textCell = Cell(scalar: 0, width: 1,
                                attribute: attribute, linkId: linkId)
            for column in 0..<cols {
                if source < bytes.endIndex {
                    textCell.scalar = UInt32(bytes[source])
                    base.advanced(by: column).initialize(to: textCell)
                    source = bytes.index(after: source)
                } else {
                    base.advanced(by: column).initialize(to: fill)
                }
            }
            count = cols
        }
        storageHasClusterExtras = fill.clusterExtras != nil
        self.isWrapped = isWrapped
        bumpVersion()
    }

    public var count: Int { cellStorage.count }

    /// Read ownership geometry without retaining a cell's cluster or attributes.
    /// Deferred rows and out-of-range reads have the public subscript's semantics;
    /// this does not materialize storage or publish a new row generation.
    func scalarAndWidth(at index: Int) -> (scalar: UInt32, width: Int8) {
        guard index >= 0 && index < cellStorage.count else {
            let cell = Cell()
            return (cell.scalar, cell.width)
        }
        if let fill = deferredFill, deferredValidRange?.contains(index) != true {
            return (fill.scalar, fill.width)
        }
        let cell = cellStorage[index]
        return (cell.scalar, cell.width)
    }

    public subscript(index: Int) -> Cell {
        get {
            guard index >= 0 && index < cellStorage.count else { return Cell() }
            if let fill = deferredFill, deferredValidRange?.contains(index) != true {
                return fill
            }
            return cellStorage[index]
        }
        set {
            materializeDeferredFill()
            if index >= 0 && index < cellStorage.count {
                cellStorage[index] = newValue
                if newValue.clusterExtras != nil { storageHasClusterExtras = true }
                bumpVersion()
            }
        }
    }

    /// Append to a freshly validated lead without retaining another copy of
    /// its extras. The caller must release its temporary extras capture first;
    /// row snapshots and externally retained cells still use normal array COW.
    /// Like the public setter, this materializes a deferred fill and publishes
    /// exactly one content mutation. No caller code runs inside the borrow.
    func appendClusterScalar(_ scalar: UInt32, at column: Int, width: Int8) {
        materializeDeferredFill()
        guard column >= 0, column < cellStorage.count else { return }
        cellStorage.withUnsafeMutableBufferPointer { storage in
            if storage[column].clusterExtras == nil {
                storage[column].clusterExtras = [scalar]
            } else {
                storage[column].clusterExtras!.append(scalar)
            }
            storage[column].width = width
        }
        storageHasClusterExtras = true
        bumpVersion()
    }

    /// Replace a contiguous cell range with single-width printable ASCII and
    /// publish one row generation. Terminal semantics (wrap, margins, cursor)
    /// remain the caller's responsibility.
    func writeASCII(_ bytes: ArraySlice<UInt8>, at column: Int,
                    attribute: CellAttribute, linkId: UInt16) {
        guard column >= 0, column + bytes.count <= cellStorage.count, !bytes.isEmpty else { return }
        let writeRange = column..<(column + bytes.count)
        if let valid = deferredValidRange,
           writeRange.lowerBound > valid.upperBound || writeRange.upperBound < valid.lowerBound {
            // Two separated islands would need a heap-allocated range set.
            // Materialize the rare cursor-jump case and keep the common
            // sequential PTY path allocation-free.
            materializeDeferredFill()
        }
        if deferredFill?.clusterExtras != nil || (deferredFill != nil && storageHasClusterExtras) {
            materializeDeferredFill()
        }
        let pendingFill = deferredFill
        let storedClustersBeforeWrite = storageHasClusterExtras
        var storedClustersAfterWrite = storedClustersBeforeWrite
        cellStorage.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            let canStoreFieldsOnly = !storedClustersBeforeWrite
                && (pendingFill?.clusterExtras == nil)
            if canStoreFieldsOnly {
                var target = base.advanced(by: column)
                if _isPOD(CellAttribute.self),
                   (8...16).contains(MemoryLayout<CellAttribute>.size) {
                    // Copy only the attribute value. Two possibly overlapping
                    // words cover its complete representation without touching
                    // the surrounding Cell or retained cluster storage.
                    var copiedAttribute = attribute
                    withUnsafeBytes(of: &copiedAttribute) { sourceAttribute in
                        let tailOffset = sourceAttribute.count - 8
                        let firstWord = sourceAttribute.loadUnaligned(as: UInt64.self)
                        let lastWord = sourceAttribute.loadUnaligned(
                            fromByteOffset: tailOffset, as: UInt64.self)
                        for byte in bytes {
                            target.pointee.scalar = UInt32(byte)
                            target.pointee.width = 1
                            withUnsafeMutableBytes(of: &target.pointee.attribute) {
                                $0.storeBytes(of: firstWord, as: UInt64.self)
                                $0.storeBytes(of: lastWord, toByteOffset: tailOffset, as: UInt64.self)
                            }
                            target.pointee.linkId = linkId
                            target = target.advanced(by: 1)
                        }
                    }
                } else {
                    // Preserve typed ownership if attributes gain references
                    // or their representation outgrows the bounded copy.
                    for byte in bytes {
                        target.pointee.scalar = UInt32(byte)
                        target.pointee.width = 1
                        target.pointee.attribute = attribute
                        target.pointee.linkId = linkId
                        target = target.advanced(by: 1)
                    }
                }
            } else {
                var target = base.advanced(by: column)
                var cell = Cell(scalar: 0, width: 1,
                                attribute: attribute, linkId: linkId)
                for byte in bytes {
                    cell.scalar = UInt32(byte)
                    target.pointee = cell
                    target = target.advanced(by: 1)
                }
            }
            if column == 0 && bytes.count == destination.count { storedClustersAfterWrite = false }
        }
        storageHasClusterExtras = storedClustersAfterWrite
        if pendingFill != nil {
            if let valid = deferredValidRange {
                let lower = min(valid.lowerBound, writeRange.lowerBound)
                let upper = max(valid.upperBound, writeRange.upperBound)
                deferredValidRange = lower..<upper
            } else {
                deferredValidRange = writeRange
            }
            if deferredValidRange?.count == cellStorage.count {
                deferredFill = nil
                deferredValidRange = nil
            }
        }
        bumpVersion()
    }

    /// Commit validated independent bases without publishing intermediate
    /// cells. Swift array COW detaches retained snapshots before mutation.
    func writeOrdinaryUnicode(
        _ cells: UnsafeBufferPointer<OrdinaryUnicodeCell>, at column: Int,
        columns: Int, attribute: CellAttribute, linkId: UInt16,
        eraseAttribute: CellAttribute, stubAttribute: CellAttribute
    ) {
        precondition(!cells.isEmpty && column >= 0 && column + columns <= cellStorage.count)
        materializeDeferredFill()
        let hasClusters = storageHasClusterExtras
        let stub = Cell(scalar: 0, width: 0, attribute: stubAttribute)
        cellStorage.withUnsafeMutableBufferPointer { destination in
            var target = column
            var cell = Cell(scalar: 0, width: 1, attribute: attribute, linkId: linkId)
            for value in cells {
                // Every target receives its complete final value below. No
                // callback observes this commit, so transient blank writes
                // before the lead/stub assignment are unnecessary. Neighbors
                // outside the written span remain untouched.
                if hasClusters {
                    cell.scalar = value.scalar
                    cell.width = value.width
                    destination[target] = cell
                } else {
                    // All extras are nil: keep POD fields in place and avoid
                    // copying a whole retained Cell for every independent base.
                    destination[target].scalar = value.scalar
                    destination[target].width = value.width
                    destination[target].attribute = attribute
                    destination[target].linkId = linkId
                }
                if value.width == 2 { destination[target + 1] = stub }
                target += Int(value.width)
            }
            precondition(target == column + columns)
        }
        if column == 0 && columns == cellStorage.count { storageHasClusterExtras = false }
        bumpVersion()
    }

    /// Reinitialize a row in place so scrolling can rotate retained storage
    /// instead of allocating and destroying a full Cell array for every line.
    func reset(fill: Cell, isWrapped: Bool = false) {
        deferredFill = nil
        deferredValidRange = nil
        cellStorage.withUnsafeMutableBufferPointer { buffer in
            for index in buffer.indices { buffer[index] = fill }
        }
        storageHasClusterExtras = fill.clusterExtras != nil
        resetMetadata(isWrapped: isWrapped)
    }

    func resetDeferred(fill: Cell, isWrapped: Bool = false) {
        if storageHasClusterExtras {
            reset(fill: fill, isWrapped: isWrapped)
            return
        }
        resetMetadata(isWrapped: isWrapped)
        deferredFill = fill
        deferredValidRange = nil
    }

    /// The caller will overwrite every cell before publishing the row.
    func resetMetadata(isWrapped: Bool = false) {
        deferredFill = nil
        deferredValidRange = nil
        self.isWrapped = isWrapped
        wrapStyle = .cells
        renderMode = .single
        images = nil
        bumpVersion()
    }

    public func resize(to cols: Int, fill: Cell) {
        materializeDeferredFill()
        if cols > cellStorage.count {
            cellStorage.append(contentsOf: Array(repeating: fill, count: cols - cellStorage.count))
            if fill.clusterExtras != nil { storageHasClusterExtras = true }
        } else if cols < cellStorage.count {
            cellStorage.removeSubrange(cols...)
        }
        bumpVersion()
    }

    public func fill(with cell: Cell, from start: Int = 0, to end: Int? = nil) {
        let upper = min(end ?? cellStorage.count, cellStorage.count)
        guard start < upper, start >= 0 else { return }
        if start == 0, upper == cellStorage.count {
            if storageHasClusterExtras {
                deferredFill = nil
                deferredValidRange = nil
                cellStorage.withUnsafeMutableBufferPointer { buffer in
                    for index in buffer.indices { buffer[index] = cell }
                }
                storageHasClusterExtras = cell.clusterExtras != nil
                bumpVersion()
                return
            }
            deferredFill = cell
            deferredValidRange = nil
            bumpVersion()
            return
        }
        materializeDeferredFill()
        for i in start..<upper { cellStorage[i] = cell }
        if cell.clusterExtras != nil { storageHasClusterExtras = true }
        bumpVersion()
    }

    /// Insert `n` blank cells at `pos`, pushing cells right WITHIN
    /// [0, rightMargin]. An out-of-range pos WRAPS (pos % (margin+1)) —
    /// reference-engine modulo, reachable via a pending-wrap cursor.
    public func insertCells(at pos: Int, count n: Int, rightMargin: Int? = nil, fill: Cell) {
        guard !cellStorage.isEmpty, pos >= 0, n > 0 else { return }
        let requestedMargin = rightMargin ?? (cellStorage.count - 1)
        guard requestedMargin >= 0 else { return }

        let activeEnd = min(requestedMargin, cellStorage.count - 1)
        let activeCount = activeEnd + 1
        let insertionIndex = pos % activeCount
        let replacedCount = activeCount - insertionIndex
        let insertedCount = min(n, replacedCount)

        materializeDeferredFill()
        var replacement = Array(repeating: fill, count: insertedCount)
        if insertedCount < replacedCount {
            replacement.append(contentsOf:
                cellStorage[insertionIndex..<(activeCount - insertedCount)])
        }
        cellStorage.replaceSubrange(insertionIndex..<activeCount, with: replacement)
        if fill.clusterExtras != nil { storageHasClusterExtras = true }
        bumpVersion()
    }

    /// Delete `n` cells at `pos`, pulling cells left WITHIN [0, rightMargin].
    public func deleteCells(at pos: Int, count n: Int, rightMargin: Int? = nil, fill: Cell) {
        guard !cellStorage.isEmpty, pos >= 0, n > 0 else { return }
        let requestedMargin = rightMargin ?? (cellStorage.count - 1)
        guard requestedMargin >= 0 else { return }

        let activeEnd = min(requestedMargin, cellStorage.count - 1)
        let activeCount = activeEnd + 1
        guard pos < activeCount else { return }

        let removedCount = min(n, activeCount - pos)
        materializeDeferredFill()
        var replacement = Array(cellStorage[(pos + removedCount)..<activeCount])
        replacement.append(contentsOf: repeatElement(fill, count: removedCount))
        cellStorage.replaceSubrange(pos..<activeCount, with: replacement)
        if fill.clusterExtras != nil { storageHasClusterExtras = true }
        bumpVersion()
    }

    /// Copy a column range from another line (margin-mode scrolling).
    public func copyColumns(from src: Line, in range: ClosedRange<Int>) {
        materializeDeferredFill()
        let source = src.cells
        if source.contains(where: { $0.clusterExtras != nil }) {
            storageHasClusterExtras = true
        }
        for i in range where i < cellStorage.count && i < source.count {
            cellStorage[i] = source[i]
        }
            bumpVersion()
    }

    /// Fill a column range (margin-mode blanking).
    public func fillColumns(_ range: ClosedRange<Int>, with cell: Cell) {
        materializeDeferredFill()
        for i in range where i < cellStorage.count {
            cellStorage[i] = cell
        }
        if cell.clusterExtras != nil { storageHasClusterExtras = true }
            bumpVersion()
    }

    /// Right-trimmed plain text of the row, mirroring the reference trim:
    /// range = last nonzero cell + ITS width (a trailing wide char keeps its
    /// stub), and every in-range cell maps blank/stub → space.
    public func trimmedText() -> String {
        materializeDeferredFill()
        let length = min(trimmedLength, cellStorage.count)
        guard length > 0 else { return "" }
        var out = ""
        for i in 0..<length {
            let c = cellStorage[i]
            out += c.scalar == 0 ? " " : c.text
        }
        return out
    }

    /// Last nonzero cell index + its width (reference getTrimmedLength).
    public var trimmedLength: Int {
        materializeDeferredFill()
        for i in stride(from: cellStorage.count - 1, through: 0, by: -1) {
            if cellStorage[i].scalar != 0 { return i + Int(cellStorage[i].width) }
        }
        return 0
    }

    private func materializeDeferredFill() {
        guard let fill = deferredFill else { return }
        deferredFill = nil
        let valid = deferredValidRange
        deferredValidRange = nil
        cellStorage.withUnsafeMutableBufferPointer { buffer in
            if let valid {
                for index in 0..<valid.lowerBound { buffer[index] = fill }
                if valid.upperBound < buffer.count {
                    for index in valid.upperBound..<buffer.count { buffer[index] = fill }
                }
            } else {
                for index in buffer.indices { buffer[index] = fill }
            }
        }
        if fill.clusterExtras != nil { storageHasClusterExtras = true }
    }

    /// Index one past the last non-blank cell (0 when the row is empty).
    public var usedLength: Int {
        materializeDeferredFill()
        for i in stride(from: cellStorage.count - 1, through: 0, by: -1) {
            if cellStorage[i].scalar != 0 { return i + 1 }
        }
        return 0
    }

    public func clone() -> Line {
        materializeDeferredFill()
        let line = Line(cells: cellStorage, isWrapped: isWrapped)
        line.wrapStyle = wrapStyle
        line.renderMode = renderMode
        line.images = images
        return line
    }
}
