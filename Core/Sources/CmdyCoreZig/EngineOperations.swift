import Foundation
import CmdyNative

extension CmdyTerminal {
    private func operation(_ kind: UInt32, _ first: Int = 0, _ second: Int = 0,
                           _ third: Int = 0, params: [Int] = []) {
        params.withUnsafeBufferPointer {
            checkedNative(cmdy_zig_terminal_operation(nativeOwner.handle, kind,
                first, second, third, $0.baseAddress, $0.count))
        }
    }
    func applySGR(_ params: [Int]) { operation(1, params: params) }
    func printScalar(_ scalar: UnicodeScalar) { operation(2, Int(scalar.value)) }
    func setPrivateMode(_ mode: Int, _ value: Bool) { operation(3, mode, value ? 1 : 0) }
    func setCursorPosition(row: Int, col: Int) { operation(4, row, col) }
    func marginModeShift(insert: Bool, at y: Int, count: Int) { operation(5, insert ? 1 : 0, y, count) }
    func marginModeScroll(up: Bool) { operation(6, up ? 1 : 0) }
    func engineScrollUp(markNewWrapped: Bool = false, clearNewRow: Bool = true,
                        hardenPrewrappedDestinations: Bool = false) {
        operation(7, markNewWrapped ? 1 : 0, clearNewRow ? 1 : 0, hardenPrewrappedDestinations ? 1 : 0)
    }
    func engineScrollDown(hardenPrewrappedDestinations: Bool = false) {
        operation(8, hardenPrewrappedDestinations ? 1 : 0)
    }
    func lineFeed() { operation(9) }
    func indexLineFeed() { operation(10) }
    func reverseLineFeed() { operation(11) }
    func dcsHook(final: UInt8, params: [Int], collect: [UInt8]) { parserDCSHook(final: final, params: params, collect: collect) }
    func dcsPut(_ bytes: ArraySlice<UInt8>) { parserDCSPut(bytes) }
    func dcsUnhook() { parserDCSUnhook() }
    func insertCellDirect(_ cell: Cell) {
        var value = nativeCell(cell)
        withNativeExtras(cell) {
            checkedNative(cmdy_zig_terminal_insert_cell(nativeOwner.handle, &value, $0, $1, $2))
        }
    }
    static func pngDimensions(_ data: Data) -> (Int, Int)? {
        var width = 0, height = 0
        let valid = data.withUnsafeBytes {
            cmdy_zig_png_dimensions($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &width, &height)
        }
        return valid == 0 ? nil : (width, height)
    }

    func preservingClusterOwnerCoordinateThroughCellEdit(row: Int, columns: ClosedRange<Int>,
        preserveBackwardAttachmentCoordinateOnInvalidation: Bool = false, _ edit: () -> Void) {
        _ = preservingClusterOwnerCoordinateThroughCellEdit(rows: row...row, columns: columns,
            preserveBackwardAttachmentCoordinateOnInvalidation: preserveBackwardAttachmentCoordinateOnInvalidation, edit)
    }
    @discardableResult
    func preservingClusterOwnerCoordinateThroughCellEdit(rows: ClosedRange<Int>, columns: ClosedRange<Int>,
        refreshSelectorMotion: Bool = false,
        preserveBackwardAttachmentCoordinateOnInvalidation: Bool = false,
        preserveLineRotationOwnerOnInvalidation: Bool = false,
        refreshLineRotationOwnerAtSavedCoordinate: Bool = false, _ edit: () -> Void) -> Bool {
        var flags: UInt8 = 0
        if refreshSelectorMotion { flags |= 1 }
        if preserveBackwardAttachmentCoordinateOnInvalidation { flags |= 2 }
        if preserveLineRotationOwnerOnInvalidation { flags |= 4 }
        if refreshLineRotationOwnerAtSavedCoordinate { flags |= 8 }
        return withoutActuallyEscaping(edit) { edit in
            var callback = edit
            var handled: UInt8 = 0
            withUnsafeMutablePointer(to: &callback) { context in
                checkedNative(cmdy_zig_terminal_cell_edit(nativeOwner.handle, rows.lowerBound, rows.upperBound,
                    columns.lowerBound, columns.upperBound, flags, context, { context in
                        context!.assumingMemoryBound(to: (() -> Void).self).pointee()
                    }, &handled))
            }
            return handled != 0
        }
    }

    struct ActiveMarginReflowBoundary { let line: Line }
    struct KittyDisplayReflowClaim { let line: Line }
    struct KittyDisplayReflowBoundary { let line: Line }
    struct KittyDisplayClippedTopReflowRank { let line: Line }
    private func witnessLines(_ kind: UInt32) -> [Line] {
        (0..<cmdy_zig_terminal_witness_count(nativeOwner.handle, kind)).map {
            Line.wrapping(retained: OpaquePointer(cmdy_zig_terminal_witness(nativeOwner.handle, kind, $0)!))
        }
    }
    var activeMarginReflowBoundaries: [ActiveMarginReflowBoundary] { witnessLines(1).map { .init(line: $0) } }
    var kittyDisplayReflowClaims: [KittyDisplayReflowClaim] { witnessLines(2).map { .init(line: $0) } }
    var kittyDisplayReflowBoundaries: [KittyDisplayReflowBoundary] { witnessLines(3).map { .init(line: $0) } }
    var kittyDisplayClippedTopReflowRanks: [KittyDisplayClippedTopReflowRank] { witnessLines(4).map { .init(line: $0) } }
    var kittyDisplayReflowImages: [LineImage] {
        (0..<cmdy_zig_terminal_witness_count(nativeOwner.handle, 5)).map {
            LineImage.wrapping(retained: OpaquePointer(cmdy_zig_terminal_witness(nativeOwner.handle, 5, $0)!))
        }
    }
}
