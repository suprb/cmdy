import AppKit
import CmdyCore
import CmdyGPU

/// Exact UTF-16/segment fixtures for the private in-place PendingRun candidate.
/// The public cell seam permits clusters spanning explicit neighboring cells.
@MainActor
enum CmdyShaperPendingRunHarness {
    static func run(_ check: (Bool, String) -> Void) {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let style = CmdyShapingStyle(palette: Array(repeating: .white, count: 256),
            normalFont: font, boldFont: font, italicFont: font, boldItalicFont: font,
            foreground: .white, background: .black, selectionBackground: .gray,
            failedRows: [], failedForeground: .red, failedBackground: .black)
        let attribute = CellAttribute(bg: .trueColor(14, 28, 42))
        func shape(_ cells: [Cell]) -> ViewLineInfo {
            let terminal = CmdyTerminal(cols: max(2, cells.count), rows: 2)
            let line = terminal.lineForDiff(absolute: 0)!
            for (column, cell) in cells.enumerated() { line[column] = cell }
            return CmdySnapshotShaper.lineInfo(snapshot: terminal.captureTerminalSnapshot(),
                absoluteRow: 0, style: style, selectedColumns: nil)
        }
        let adjacent = shape([
            Cell(scalar: 0x65, attribute: attribute),
            Cell(scalar: 0x301, attribute: attribute),
            Cell(scalar: 0x1F469, width: 2, attribute: attribute),
            Cell(width: 0, attribute: attribute),
            Cell(scalar: 0x200D, attribute: attribute),
            Cell(scalar: 0x1F4BB, width: 2, attribute: attribute),
            Cell(width: 0, attribute: attribute),
            Cell(scalar: 0x2764, attribute: attribute),
            Cell(scalar: 0xFE0F, attribute: attribute),
            Cell(scalar: 0xD800, attribute: attribute),
            Cell(scalar: 0x10EEEE, attribute: attribute),
        ])
        let expectedUTF16: [[UInt16]] = [
            [0x65, 0x301], [0xD83D, 0xDC69], [0x200D], [0xD83D, 0xDCBB],
            [0x2764, 0xFE0F, 0x20, 0x20],
        ]
        check(adjacent.segments.map { Array($0.attributedString.string.utf16) } == expectedUTF16
                && adjacent.segments.map(\.column) == [0, 2, 4, 5, 7]
                && adjacent.segments.map(\.columnWidth) == [1, 2, 1, 2, 1]
                && adjacent.segments.map(\.cellUTF16Boundaries) == [
                    [0, 1, 2], [0, 2], [0, 1], [0, 2], [0, 1, 2, 3, 4]]
                && adjacent.kittyPlaceholders.isEmpty,
              "pending run: combining, ZWJ and VS across explicit cells preserve exact code units and run-local boundaries")

        let clusters = shape(Array(repeating: Cell(scalar: 0x65, clusterExtras: [0x301],
            attribute: attribute), count: 120))
        check(clusters.segments.count == 1
                && clusters.segments.first?.characterCount == 120
                && clusters.segments.first?.attributedString.length == 240
                && clusters.segments.first?.cellUTF16Boundaries == Array(stride(from: 0, through: 240, by: 2))
                && clusters.segments.first?.attributedString.string.utf16.elementsEqual(
                    (0..<120).flatMap { _ in [UInt16(0x65), UInt16(0x301)] }) == true,
              "pending run: a complete combining row preserves all 120 engine-cell boundaries")

        let wide = shape((0..<60).flatMap { _ in [
            Cell(scalar: 0x1F642, width: 2, attribute: attribute),
            Cell(width: 0, attribute: attribute),
        ] })
        check(wide.segments.count == 1 && wide.segments.first?.columnWidth == 2
                && wide.segments.first?.characterCount == 60
                && wide.segments.first?.attributedString.length == 120
                && wide.segments.first?.cellUTF16Boundaries == Array(stride(from: 0, through: 120, by: 2)),
              "pending run: a full wide-emoji row skips continuation cells and retains surrogate-pair boundaries")

        let second = CellAttribute(fg: .trueColor(180, 20, 40), bg: attribute.bg)
        let styles = shape([
            Cell(scalar: 0x41, attribute: attribute),
            Cell(scalar: 0x65, clusterExtras: [0x301], attribute: attribute),
            Cell(scalar: 0x1F642, width: 2, attribute: second),
            Cell(width: 0, attribute: second),
            Cell(scalar: 0x42, attribute: attribute),
        ])
        check(styles.segments.count == 3
                && styles.segments.map(\.column) == [0, 2, 4]
                && styles.segments.map(\.cellUTF16Boundaries) == [[0, 1, 3], [0, 2], [0, 1]],
              "pending run: attribute and width changes restart each run's boundary origin")
    }
}
