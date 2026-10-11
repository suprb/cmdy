import AppKit
import CoreGraphics
import Foundation
import CmdyNative

public enum BlockAlpha: CGFloat, Sendable {
    case full = 1.0
    case dark = 0.75
    case medium = 0.5
    case light = 0.25
}

public struct BlockElementRect: Sendable {
    public let x0: UInt8
    public let x1: UInt8
    public let y0: UInt8
    public let y1: UInt8
    public let alpha: BlockAlpha

    init(x0: UInt8, x1: UInt8, y0: UInt8, y1: UInt8,
         alpha: BlockAlpha = .full) {
        let value = cmdy_render_block_rect(x0, x1, y0, y1, alpha.rawValue)
        self.x0 = value.x0; self.x1 = value.x1; self.y0 = value.y0; self.y1 = value.y1
        self.alpha = alpha
    }

    @_spi(CmdyApp) public init(native: CmdyRenderBlockRect) {
        x0 = native.x0; x1 = native.x1; y0 = native.y0; y1 = native.y1
        alpha = BlockAlpha(rawValue: native.alpha)!
    }

    /// Eighth coordinates use a terminal-style y-down origin.
    public func rect(in cellOrigin: CGPoint,
                     xEighth: CGFloat,
                     yEighth: CGFloat,
                     cellHeight: CGFloat) -> CGRect {
        let value = CmdyRenderBlockRect(x0: x0, x1: x1, y0: y0, y1: y1, alpha: alpha.rawValue)
        return cmdy_render_block_geometry(value, cellOrigin.x, cellOrigin.y, xEighth, yEighth, cellHeight).cgRect
    }
}

public struct BlockElementMapping {
    public static let lowerBoundary = 0x2580
    public static let upperBoundary = 0x259F

    public static func rects(for codePoint: UInt32) -> [BlockElementRect]? {
        var records = [CmdyRenderBlockRect](repeating: CmdyRenderBlockRect(), count: 3)
        let count = cmdy_render_block_rects(codePoint, &records, records.count)
        guard count > 0 else { return nil }
        return records.prefix(count).map {
            BlockElementRect(x0: $0.x0, x1: $0.x1, y0: $0.y0, y1: $0.y1,
                             alpha: BlockAlpha(rawValue: $0.alpha)!)
        }
    }
}

public struct BlockElementRenderItem {
    public let column: Int
    public let columnWidth: Int
    public let codePoint: UInt32
    public let rects: [BlockElementRect]
    public let foregroundColor: TTColor

    public init(column: Int,
                columnWidth: Int,
                codePoint: UInt32,
                rects: [BlockElementRect],
                foregroundColor: TTColor) {
        self.column = column
        self.columnWidth = max(0, columnWidth)
        self.codePoint = codePoint
        self.rects = rects
        self.foregroundColor = foregroundColor
    }
}

public struct BoxDrawingRenderItem {
    public let column: Int
    public let columnWidth: Int
    public let codePoint: UInt32
    public let foregroundColor: TTColor

    public init(column: Int,
                columnWidth: Int,
                codePoint: UInt32,
                foregroundColor: TTColor) {
        self.column = column
        self.columnWidth = max(0, columnWidth)
        self.codePoint = codePoint
        self.foregroundColor = foregroundColor
    }
}

struct BoxDrawingCanvas {
    let context: CGContext
    let origin: CGPoint
    let cellWidthPx: Int
    let cellHeightPx: Int
    let minStrokeThicknessPx: Int
    func point(x: Double, y: Double) -> CGPoint {
        let point = cmdy_render_canvas_point(origin.x, origin.y, cellWidthPx, cellHeightPx, x, y)
        return CGPoint(x: point.x, y: point.y)
    }
    func line(from: CGPoint, to: CGPoint, thicknessPx: Int) {
        cmdy_render_canvas_line(Unmanaged.passUnretained(context).toOpaque(), origin.x, origin.y,
                                cellWidthPx, cellHeightPx, minStrokeThicknessPx,
                                from.x, from.y, to.x, to.y, thicknessPx)
    }
    func box(x: Int, y: Int, width: Int, height: Int) {
        cmdy_render_canvas_box(Unmanaged.passUnretained(context).toOpaque(), origin.x, origin.y,
                               cellWidthPx, cellHeightPx, x, y, width, height)
    }
    func centeredBand(length: Int, thickness: Int, upperBias: Bool = false) -> Range<Int> {
        let value = cmdy_render_centered_band(length, thickness, upperBias ? 1 : 0)
        return value.lower..<value.upper
    }
}
public struct BoxDrawingRenderer {
    public static let lowerBoundary: Int32 = 0x2500
    public static let upperBoundary: Int32 = 0x257F
    public static func draw(codePoint: UInt32, in context: CGContext,
                            cellOrigin: CGPoint, cellSize: CGSize, scale: CGFloat,
                            color: TTColor, baseThicknessPx: Int) {
        cmdy_render_box_draw(codePoint, Unmanaged.passUnretained(context).toOpaque(),
                            cellOrigin.x, cellOrigin.y, cellSize.width, cellSize.height,
                            scale, Unmanaged.passUnretained(color).toOpaque(), baseThicknessPx)
    }
    static func diagonalStrokeThickness(base: Int) -> Int { cmdy_render_diagonal_thickness(base) }
    static func arcAxisCoordinate(length: Int, thickness: Int) -> CGFloat { cmdy_render_arc_axis(length, thickness) }
    static func dashSpans(length: Int, count: Int, horizontal: Bool, heavy: Bool, minimumThickness: Int) -> [Range<Int>] {
        let size = cmdy_render_dash_spans(length, count, horizontal ? 1 : 0, heavy ? 1 : 0, minimumThickness, nil, 0)
        var records = [CmdyRenderSpan](repeating: CmdyRenderSpan(), count: size)
        _ = cmdy_render_dash_spans(length, count, horizontal ? 1 : 0, heavy ? 1 : 0, minimumThickness, &records, size)
        return records.map { $0.lower..<$0.upper }
    }
}
