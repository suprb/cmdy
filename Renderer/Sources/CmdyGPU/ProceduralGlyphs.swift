import AppKit
import CoreGraphics
import Foundation

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
        self.x0 = min(8, x0)
        self.x1 = min(8, max(x0, x1))
        self.y0 = min(8, y0)
        self.y1 = min(8, max(y0, y1))
        self.alpha = alpha
    }

    /// Eighth coordinates use a terminal-style y-down origin.
    public func rect(in cellOrigin: CGPoint,
                     xEighth: CGFloat,
                     yEighth: CGFloat,
                     cellHeight: CGFloat) -> CGRect {
        CGRect(x: cellOrigin.x + CGFloat(x0) * xEighth,
               y: cellOrigin.y + cellHeight - CGFloat(y1) * yEighth,
               width: CGFloat(x1 - x0) * xEighth,
               height: CGFloat(y1 - y0) * yEighth)
    }
}

public struct BlockElementMapping {
    public static let lowerBoundary = 0x2580
    public static let upperBoundary = 0x259F

    public static func rects(for codePoint: UInt32) -> [BlockElementRect]? {
        guard Int(codePoint) >= lowerBoundary, Int(codePoint) <= upperBoundary else {
            return nil
        }
        func r(_ x0: UInt8, _ x1: UInt8, _ y0: UInt8, _ y1: UInt8,
               _ alpha: BlockAlpha = .full) -> BlockElementRect {
            BlockElementRect(x0: x0, x1: x1, y0: y0, y1: y1, alpha: alpha)
        }
        switch codePoint {
        case 0x2580: return [r(0, 8, 0, 4)]                       // upper half
        case 0x2581...0x2588:
            let eighths = UInt8(codePoint - 0x2580)
            return [r(0, 8, 8 - eighths, 8)]                    // lower n eighths
        case 0x2589...0x258F:
            let eighths = UInt8(0x2590 - codePoint)
            return [r(0, eighths, 0, 8)]                        // left n eighths
        case 0x2590: return [r(4, 8, 0, 8)]
        case 0x2591: return [r(0, 8, 0, 8, .light)]
        case 0x2592: return [r(0, 8, 0, 8, .medium)]
        case 0x2593: return [r(0, 8, 0, 8, .dark)]
        case 0x2594: return [r(0, 8, 0, 1)]
        case 0x2595: return [r(7, 8, 0, 8)]
        case 0x2596: return [r(0, 4, 4, 8)]
        case 0x2597: return [r(4, 8, 4, 8)]
        case 0x2598: return [r(0, 4, 0, 4)]
        case 0x2599: return [r(0, 4, 0, 4), r(0, 4, 4, 8), r(4, 8, 4, 8)]
        case 0x259A: return [r(0, 4, 0, 4), r(4, 8, 4, 8)]
        case 0x259B: return [r(0, 4, 0, 4), r(4, 8, 0, 4), r(0, 4, 4, 8)]
        case 0x259C: return [r(0, 4, 0, 4), r(4, 8, 0, 4), r(4, 8, 4, 8)]
        case 0x259D: return [r(4, 8, 0, 4)]
        case 0x259E: return [r(4, 8, 0, 4), r(0, 4, 4, 8)]
        case 0x259F: return [r(4, 8, 0, 4), r(0, 4, 4, 8), r(4, 8, 4, 8)]
        default: return nil
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
        CGPoint(x: origin.x + CGFloat(x) * CGFloat(cellWidthPx),
                y: origin.y + CGFloat(y) * CGFloat(cellHeightPx))
    }

    func line(from: CGPoint, to: CGPoint, thicknessPx: Int) {
        let lineThickness = max(minStrokeThicknessPx, thicknessPx)
        context.setLineWidth(CGFloat(lineThickness))
        context.setLineCap(.butt)
        let start = CGPoint(x: from.x.rounded(), y: from.y.rounded())
        let end = CGPoint(x: to.x.rounded(), y: to.y.rounded())
        let dx = end.x - start.x
        let dy = end.y - start.y
        let xExtension = min(1, CGFloat(cellWidthPx) / CGFloat(cellHeightPx)) / 2
        let yExtension = min(1, CGFloat(cellHeightPx) / CGFloat(cellWidthPx)) / 2
        let xDirection: CGFloat = dx < 0 ? -1 : (dx > 0 ? 1 : 0)
        let yDirection: CGFloat = dy < 0 ? -1 : (dy > 0 ? 1 : 0)
        context.move(to: CGPoint(
            x: start.x - xDirection * xExtension,
            y: start.y - yDirection * yExtension))
        context.addLine(to: CGPoint(
            x: end.x + xDirection * xExtension,
            y: end.y + yDirection * yExtension))
        context.strokePath()
    }

    func box(x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let x0 = min(cellWidthPx, max(0, x))
        let y0 = min(cellHeightPx, max(0, y))
        let x1 = min(cellWidthPx, max(x0, x + width))
        let y1 = min(cellHeightPx, max(y0, y + height))
        guard x1 > x0, y1 > y0 else { return }
        context.fill(CGRect(x: origin.x + CGFloat(x0),
                            y: origin.y + CGFloat(y0),
                            width: CGFloat(x1 - x0),
                            height: CGFloat(y1 - y0)))
    }

    func centeredBand(length: Int,
                      thickness: Int,
                      upperBias: Bool = false) -> Range<Int> {
        let clampedThickness = min(max(1, thickness), max(1, length))
        let remainder = length - clampedThickness
        let lower = max(0, (remainder + (upperBias ? 1 : 0)) / 2)
        return lower..<min(length, lower + clampedThickness)
    }

    fileprivate func drawOrthogonal(_ sides: BoxDrawingSides) {
        let centerX = centeredBand(length: cellWidthPx,
                                   thickness: minStrokeThicknessPx)
        let centerY = centeredBand(length: cellHeightPx,
                                   thickness: minStrokeThicknessPx)

        func thickness(_ stroke: BoxDrawingStroke) -> Int {
            switch stroke {
            case .none:
                return 0
            case .light, .single:
                return minStrokeThicknessPx
            case .heavy:
                return minStrokeThicknessPx * 2
            case .double:
                return minStrokeThicknessPx
            }
        }

        func horizontal(_ side: BoxDrawingSide, _ stroke: BoxDrawingStroke) {
            let lineThickness = thickness(stroke)
            guard lineThickness > 0 else { return }
            let y = centeredBand(length: cellHeightPx,
                                 thickness: lineThickness)
            switch side {
            case .left:
                box(x: 0, y: y.lowerBound,
                    width: centerX.upperBound, height: y.count)
            case .right:
                let x = centerX.lowerBound
                box(x: x, y: y.lowerBound,
                    width: cellWidthPx - x, height: y.count)
            default:
                break
            }
        }

        func vertical(_ side: BoxDrawingSide, _ stroke: BoxDrawingStroke) {
            let lineThickness = thickness(stroke)
            guard lineThickness > 0 else { return }
            let x = centeredBand(length: cellWidthPx, thickness: lineThickness)
            switch side {
            case .up:
                box(x: x.lowerBound, y: 0,
                    width: x.count, height: centerY.upperBound)
            case .down:
                let y = centerY.lowerBound
                box(x: x.lowerBound, y: y,
                    width: x.count, height: cellHeightPx - y)
            default:
                break
            }
        }

        horizontal(.left, sides.left)
        horizontal(.right, sides.right)
        vertical(.up, sides.up)
        vertical(.down, sides.down)

        // A perpendicular heavy-heavy join otherwise leaves a one-pixel
        // notch at the outside corner because terminal half-lines deliberately
        // overlap the center by only one device pixel.
        let verticalThickness = max(thickness(sides.up), thickness(sides.down))
        let horizontalThickness = max(thickness(sides.left), thickness(sides.right))
        if verticalThickness > 0, horizontalThickness > 0 {
            let x = centeredBand(length: cellWidthPx, thickness: verticalThickness)
            let y = centeredBand(length: cellHeightPx,
                                 thickness: horizontalThickness)
            box(x: x.lowerBound, y: y.lowerBound, width: x.count, height: y.count)
        }
    }
}

private enum BoxDrawingSide {
    case up, right, down, left
}

private enum BoxDrawingStroke: Int {
    case none
    case light
    case heavy
    case single
    case double
}

private struct BoxDrawingSides {
    var up: BoxDrawingStroke = .none
    var right: BoxDrawingStroke = .none
    var down: BoxDrawingStroke = .none
    var left: BoxDrawingStroke = .none

    mutating func set(_ stroke: BoxDrawingStroke, for token: Substring) {
        switch token {
        case "UP": up = stroke
        case "RIGHT": right = stroke
        case "DOWN": down = stroke
        case "LEFT": left = stroke
        case "VERTICAL": up = stroke; down = stroke
        case "HORIZONTAL": left = stroke; right = stroke
        default: break
        }
    }
}

public struct BoxDrawingRenderer {
    public static let lowerBoundary: Int32 = 0x2500
    public static let upperBoundary: Int32 = 0x257F

    public static func draw(codePoint: UInt32,
                            in context: CGContext,
                            cellOrigin: CGPoint,
                            cellSize: CGSize,
                            scale: CGFloat,
                            color: TTColor,
                            baseThicknessPx: Int) {
        guard codePoint >= UInt32(lowerBoundary), codePoint <= UInt32(upperBoundary),
              cellSize.width > 0, cellSize.height > 0,
              scale.isFinite, scale > 0 else { return }
        let width = max(1, Int((cellSize.width * scale).rounded()))
        let height = max(1, Int((cellSize.height * scale).rounded()))
        let canvas = BoxDrawingCanvas(context: context, origin: cellOrigin,
                                      cellWidthPx: width, cellHeightPx: height,
                                      minStrokeThicknessPx: max(1, baseThicknessPx))
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)

        let scalar = Unicode.Scalar(codePoint)
        let name = scalar?.properties.name ?? ""
        if name.contains("DIAGONAL") {
            drawDiagonal(named: name, canvas: canvas, thickness: baseThicknessPx)
        } else if name.contains("ARC") || (0x256D...0x2570).contains(codePoint) {
            drawArc(codePoint: codePoint, canvas: canvas, thickness: baseThicknessPx)
        } else if name.contains("DASH") {
            drawDashed(named: name, canvas: canvas)
        } else {
            drawOrthogonal(named: name, codePoint: codePoint, canvas: canvas)
        }
        context.restoreGState()
    }

    private static func drawDiagonal(named name: String,
                                     canvas: BoxDrawingCanvas,
                                     thickness: Int) {
        // A diagonal traverses more device pixels per unit distance than an
        // axis-aligned stroke. The 3:2 compensation keeps its apparent weight
        // equal to a light horizontal/vertical line at Retina scale.
        let diagonalThickness = diagonalStrokeThickness(base: thickness)
        if name.contains("UPPER RIGHT TO LOWER LEFT") || name.contains("CROSS") {
            canvas.line(from: canvas.point(x: 1, y: 0),
                        to: canvas.point(x: 0, y: 1), thicknessPx: diagonalThickness)
        }
        if name.contains("UPPER LEFT TO LOWER RIGHT") || name.contains("CROSS") {
            canvas.line(from: canvas.point(x: 0, y: 0),
                        to: canvas.point(x: 1, y: 1), thicknessPx: diagonalThickness)
        }
    }

    static func diagonalStrokeThickness(base: Int) -> Int {
        max(1, base + max(0, base / 2))
    }

    private static func drawArc(codePoint: UInt32,
                                canvas: BoxDrawingCanvas,
                                thickness: Int) {
        let arms: (up: Bool, right: Bool, down: Bool, left: Bool)
        switch codePoint {
        case 0x256D: // down and right
            arms = (false, true, true, false)
        case 0x256E: // down and left
            arms = (false, false, true, true)
        case 0x256F: // up and left
            arms = (true, false, false, true)
        case 0x2570: // up and right
            arms = (true, true, false, false)
        default:
            return
        }

        let stroke = max(1, thickness)
        let minimumDimension = CGFloat(min(canvas.cellWidthPx,
                                           canvas.cellHeightPx))
        let halfStroke = CGFloat(stroke) / 2
        let radius = min(
            minimumDimension * 0.30,
            max(0, minimumDimension / 2 - halfStroke))
        guard radius > 0 else { return }
        let context = canvas.context
        let centerX = arcAxisCoordinate(length: canvas.cellWidthPx,
                                        thickness: stroke)
        let centerY = arcAxisCoordinate(length: canvas.cellHeightPx,
                                        thickness: stroke)
        let centerBandX = max(0, (canvas.cellWidthPx - stroke) / 2)
        let centerBandY = max(0, (canvas.cellHeightPx - stroke) / 2)
        let xLow = max(0, min(canvas.cellWidthPx,
                              Int(ceil(centerX - radius))))
        let xHigh = max(0, min(canvas.cellWidthPx,
                               Int(floor(centerX + radius))))
        let yLow = max(0, min(canvas.cellHeightPx,
                              Int(ceil(centerY - radius))))
        let yHigh = max(0, min(canvas.cellHeightPx,
                               Int(floor(centerY + radius))))

        if arms.up {
            canvas.box(x: centerBandX, y: 0,
                       width: stroke, height: yLow)
        }
        if arms.down {
            canvas.box(x: centerBandX, y: yHigh,
                       width: stroke, height: canvas.cellHeightPx - yHigh)
        }
        if arms.left {
            canvas.box(x: 0, y: centerBandY,
                       width: xLow, height: stroke)
        }
        if arms.right {
            canvas.box(x: xHigh, y: centerBandY,
                       width: canvas.cellWidthPx - xHigh, height: stroke)
        }

        // The frozen raster fills an even-odd quarter annulus instead of
        // stroking a tangent arc. Besides matching its topology, this keeps
        // CoreGraphics' exact 8-bit antialias quantization at 1x and 2x.
        let circleX = centerX + (arms.right ? radius : -radius)
        let circleY = centerY + (arms.down ? radius : -radius)
        let outerRadius = radius + halfStroke
        let innerRadius = max(0, radius - halfStroke)
        let cellRect = CGRect(x: canvas.origin.x, y: canvas.origin.y,
                              width: CGFloat(canvas.cellWidthPx),
                              height: CGFloat(canvas.cellHeightPx))
        let clipRect = CGRect(
            x: arms.right ? cellRect.minX : canvas.origin.x + circleX,
            y: arms.down ? cellRect.minY : canvas.origin.y + circleY,
            width: arms.right
                ? circleX
                : CGFloat(canvas.cellWidthPx) - circleX,
            height: arms.down
                ? circleY
                : CGFloat(canvas.cellHeightPx) - circleY)
        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.clip(to: clipRect)
        let path = CGMutablePath()
        let absoluteCenter = CGPoint(x: canvas.origin.x + circleX,
                                     y: canvas.origin.y + circleY)
        path.addEllipse(in: CGRect(
            x: absoluteCenter.x - outerRadius,
            y: absoluteCenter.y - outerRadius,
            width: outerRadius * 2, height: outerRadius * 2))
        if innerRadius > 0 {
            path.addEllipse(in: CGRect(
                x: absoluteCenter.x - innerRadius,
                y: absoluteCenter.y - innerRadius,
                width: innerRadius * 2, height: innerRadius * 2))
        }
        context.addPath(path)
        context.drawPath(using: innerRadius > 0 ? .eoFill : .fill)
        context.restoreGState()
    }

    static func arcAxisCoordinate(length: Int, thickness: Int) -> CGFloat {
        let center = CGFloat(length) / 2
        return thickness.isMultiple(of: 2) ? center : center - 0.5
    }

    private static func drawDashed(named name: String, canvas: BoxDrawingCanvas) {
        let tokens = name.split(separator: " ")
        let count = tokens.contains("QUADRUPLE") ? 4 : (tokens.contains("TRIPLE") ? 3 : 2)
        let heavy = tokens.contains("HEAVY")
        let thickness = heavy
            ? canvas.minStrokeThicknessPx * 2
            : canvas.minStrokeThicknessPx
        let horizontal = tokens.contains("HORIZONTAL")
        let length = horizontal ? canvas.cellWidthPx : canvas.cellHeightPx
        let crossLength = horizontal ? canvas.cellHeightPx : canvas.cellWidthPx
        let cross = canvas.centeredBand(length: crossLength,
                                        thickness: thickness,
                                        upperBias: false)
        let spans = dashSpans(length: length, count: count,
                              horizontal: horizontal, heavy: heavy,
                              minimumThickness: canvas.minStrokeThicknessPx)

        for span in spans {
            if horizontal {
                canvas.box(x: span.lowerBound, y: cross.lowerBound,
                           width: span.count, height: cross.count)
            } else {
                canvas.box(x: cross.lowerBound, y: span.lowerBound,
                           width: cross.count, height: span.count)
            }
        }
    }

    static func dashSpans(length: Int,
                          count: Int,
                          horizontal: Bool,
                          heavy: Bool,
                          minimumThickness: Int) -> [Range<Int>] {
        guard length > 0, count > 0 else { return [] }
        let thickness = max(1, minimumThickness)
        if thickness == 2 {
            // Keep the established 16x24-point compatibility gallery exact.
            let stroke = heavy ? thickness * 2 : thickness
            let compatibilityGap = max(2, thickness * 2)
            if count == 2 {
                if horizontal {
                    let leading = max(0, stroke / 2)
                    let segment = max(1,
                        (length - stroke - leading * 2) / 2)
                    return [leading..<(leading + segment),
                            (length - leading - segment)..<(length - leading)]
                }
                let segment = max(1,
                    (length - compatibilityGap * 2) / 2)
                return [0..<segment,
                        (segment + compatibilityGap)..<(segment * 2 + compatibilityGap)]
            }
            let leading = horizontal ? max(1, compatibilityGap / 2) : 0
            let trailing = horizontal ? leading : compatibilityGap
            let available = max(count,
                length - leading - trailing - compatibilityGap * (count - 1))
            let base = available / count
            let remainder = available % count
            var cursor = leading
            return (0..<count).map { index in
                let segment = base + (index < remainder ? 1 : 0)
                defer { cursor += segment + compatibilityGap }
                return cursor..<(cursor + segment)
            }
        }
        let scaleUnit = max(1, (thickness + 1) / 2)
        let leading: Int
        let gap: Int
        let trailing: Int
        if horizontal {
            switch count {
            case 2 where heavy:
                leading = thickness
                gap = thickness * 2
                trailing = thickness
            case 2:
                leading = max(0, scaleUnit - 1)
                gap = max(1, scaleUnit * 2 - 1)
                trailing = scaleUnit
            case 3:
                leading = scaleUnit
                gap = scaleUnit * 2
                trailing = scaleUnit
            default:
                leading = max(0, scaleUnit - 1)
                gap = max(1, scaleUnit * 2 - 1)
                trailing = scaleUnit
            }
        } else {
            switch count {
            case 2:
                leading = 0
                gap = thickness * 2
                trailing = gap
            case 3:
                leading = 0
                gap = 4
                trailing = gap
            default:
                leading = 0
                gap = scaleUnit + 2
                trailing = gap
            }
        }

        let available = max(count,
                            length - leading - trailing - gap * (count - 1))
        let base = max(1, available / count)
        let remainder = max(0, available % count)
        var cursor = min(length, leading)
        var result: [Range<Int>] = []
        for index in 0..<count where cursor < length {
            let segment = base + (index < remainder ? 1 : 0)
            let upper = min(length, cursor + segment)
            if upper > cursor { result.append(cursor..<upper) }
            cursor = upper + gap
        }
        return result
    }

    private static func drawOrthogonal(named name: String,
                                       codePoint: UInt32,
                                       canvas: BoxDrawingCanvas) {
        let descriptor = name.hasPrefix("BOX DRAWINGS ")
            ? String(name.dropFirst("BOX DRAWINGS ".count))
            : name
        var clauses = descriptor.components(separatedBy: " AND ")
        var defaultStroke: BoxDrawingStroke?
        if let first = clauses.first {
            for (word, stroke) in [("LIGHT", BoxDrawingStroke.light),
                                   ("HEAVY", .heavy),
                                   ("SINGLE", .single),
                                   ("DOUBLE", .double)] where first.hasPrefix(word + " ") {
                defaultStroke = stroke
                clauses[0].removeFirst(word.count + 1)
                break
            }
        }

        var sides = BoxDrawingSides()
        for clause in clauses {
            let tokens = clause.split(separator: " ")
            let stroke: BoxDrawingStroke
            if tokens.contains("HEAVY") {
                stroke = .heavy
            } else if tokens.contains("DOUBLE") {
                stroke = .double
            } else if tokens.contains("SINGLE") {
                stroke = .single
            } else if tokens.contains("LIGHT") {
                stroke = .light
            } else {
                stroke = defaultStroke ?? .light
            }
            for token in tokens {
                sides.set(stroke, for: token)
            }
        }
        if (0x2550...0x256C).contains(codePoint) {
            drawSingleDouble(codePoint: codePoint, canvas: canvas)
        } else {
            canvas.drawOrthogonal(sides)
        }
    }

    /// Unicode's single/double junctions route the two tracks around a
    /// two-device-pixel center channel. Describing those routes explicitly is
    /// less ambiguous than trying to infer topology from the English name.
    private static func drawSingleDouble(codePoint: UInt32,
                                         canvas: BoxDrawingCanvas) {
        let thickness = canvas.minStrokeThicknessPx
        let xCenter = canvas.centeredBand(length: canvas.cellWidthPx,
                                          thickness: thickness)
        let yCenter = canvas.centeredBand(length: canvas.cellHeightPx,
                                          thickness: thickness)
        let xBefore = max(0, xCenter.lowerBound - thickness)..<xCenter.lowerBound
        let xAfter = xCenter.upperBound..<min(canvas.cellWidthPx,
                                              xCenter.upperBound + thickness)
        let yBefore = max(0, yCenter.lowerBound - thickness)..<yCenter.lowerBound
        let yAfter = yCenter.upperBound..<min(canvas.cellHeightPx,
                                              yCenter.upperBound + thickness)
        let fullX = 0..<canvas.cellWidthPx
        let fullY = 0..<canvas.cellHeightPx

        func fill(_ x: Range<Int>, _ y: Range<Int>) {
            canvas.box(x: x.lowerBound, y: y.lowerBound,
                       width: x.count, height: y.count)
        }
        func horizontal(_ y: Range<Int>, from x0: Int, to x1: Int) {
            fill(max(0, x0)..<min(canvas.cellWidthPx, x1), y)
        }
        func vertical(_ x: Range<Int>, from y0: Int, to y1: Int) {
            fill(x, max(0, y0)..<min(canvas.cellHeightPx, y1))
        }

        switch codePoint {
        case 0x2550: // double horizontal
            fill(fullX, yBefore); fill(fullX, yAfter)
        case 0x2551: // double vertical
            fill(xBefore, fullY); fill(xAfter, fullY)

        case 0x2552: // down single, right double
            horizontal(yBefore, from: xCenter.lowerBound, to: fullX.upperBound)
            horizontal(yAfter, from: xCenter.lowerBound, to: fullX.upperBound)
            vertical(xCenter, from: yCenter.lowerBound, to: fullY.upperBound)
        case 0x2553: // down double, right single
            horizontal(yCenter, from: xBefore.lowerBound, to: fullX.upperBound)
            vertical(xBefore, from: yCenter.lowerBound, to: fullY.upperBound)
            vertical(xAfter, from: yCenter.lowerBound, to: fullY.upperBound)
        case 0x2554: // double down and right
            horizontal(yBefore, from: xBefore.lowerBound, to: fullX.upperBound)
            vertical(xBefore, from: yBefore.lowerBound, to: fullY.upperBound)
            horizontal(yAfter, from: xAfter.lowerBound, to: fullX.upperBound)
            vertical(xAfter, from: yAfter.lowerBound, to: fullY.upperBound)
        case 0x2555: // down single, left double
            horizontal(yBefore, from: 0, to: xCenter.upperBound)
            horizontal(yAfter, from: 0, to: xCenter.upperBound)
            vertical(xCenter, from: yCenter.lowerBound, to: fullY.upperBound)
        case 0x2556: // down double, left single
            horizontal(yCenter, from: 0, to: xAfter.upperBound)
            vertical(xBefore, from: yCenter.lowerBound, to: fullY.upperBound)
            vertical(xAfter, from: yCenter.lowerBound, to: fullY.upperBound)
        case 0x2557: // double down and left
            horizontal(yBefore, from: 0, to: xAfter.upperBound)
            vertical(xAfter, from: yBefore.lowerBound, to: fullY.upperBound)
            horizontal(yAfter, from: 0, to: xBefore.upperBound)
            vertical(xBefore, from: yAfter.lowerBound, to: fullY.upperBound)

        case 0x2558: // up single, right double
            horizontal(yBefore, from: xCenter.lowerBound, to: fullX.upperBound)
            horizontal(yAfter, from: xCenter.lowerBound, to: fullX.upperBound)
            vertical(xCenter, from: 0, to: yCenter.upperBound)
        case 0x2559: // up double, right single
            horizontal(yCenter, from: xBefore.lowerBound, to: fullX.upperBound)
            vertical(xBefore, from: 0, to: yCenter.upperBound)
            vertical(xAfter, from: 0, to: yCenter.upperBound)
        case 0x255A: // double up and right
            vertical(xBefore, from: 0, to: yAfter.upperBound)
            vertical(xAfter, from: 0, to: yBefore.upperBound)
            horizontal(yBefore, from: xAfter.lowerBound, to: fullX.upperBound)
            horizontal(yAfter, from: xBefore.lowerBound, to: fullX.upperBound)
        case 0x255B: // up single, left double
            horizontal(yBefore, from: 0, to: xCenter.upperBound)
            horizontal(yAfter, from: 0, to: xCenter.upperBound)
            vertical(xCenter, from: 0, to: yCenter.upperBound)
        case 0x255C: // up double, left single
            horizontal(yCenter, from: 0, to: xAfter.upperBound)
            vertical(xBefore, from: 0, to: yCenter.upperBound)
            vertical(xAfter, from: 0, to: yCenter.upperBound)
        case 0x255D: // double up and left
            vertical(xAfter, from: 0, to: yAfter.upperBound)
            vertical(xBefore, from: 0, to: yBefore.upperBound)
            horizontal(yBefore, from: 0, to: xBefore.upperBound)
            horizontal(yAfter, from: 0, to: xAfter.upperBound)

        case 0x255E: // vertical single, right double
            fill(xCenter, fullY)
            horizontal(yBefore, from: xCenter.lowerBound, to: fullX.upperBound)
            horizontal(yAfter, from: xCenter.lowerBound, to: fullX.upperBound)
        case 0x255F: // vertical double, right single
            fill(xBefore, fullY); fill(xAfter, fullY)
            horizontal(yCenter, from: xAfter.lowerBound, to: fullX.upperBound)
        case 0x2560: // double vertical and right
            fill(xBefore, fullY)
            vertical(xAfter, from: 0, to: yBefore.upperBound)
            vertical(xAfter, from: yAfter.lowerBound, to: fullY.upperBound)
            horizontal(yBefore, from: xAfter.lowerBound, to: fullX.upperBound)
            horizontal(yAfter, from: xAfter.lowerBound, to: fullX.upperBound)
        case 0x2561: // vertical single, left double
            fill(xCenter, fullY)
            horizontal(yBefore, from: 0, to: xCenter.upperBound)
            horizontal(yAfter, from: 0, to: xCenter.upperBound)
        case 0x2562: // vertical double, left single
            fill(xBefore, fullY); fill(xAfter, fullY)
            horizontal(yCenter, from: 0, to: xBefore.upperBound)
        case 0x2563: // double vertical and left
            fill(xAfter, fullY)
            vertical(xBefore, from: 0, to: yBefore.upperBound)
            vertical(xBefore, from: yAfter.lowerBound, to: fullY.upperBound)
            horizontal(yBefore, from: 0, to: xBefore.upperBound)
            horizontal(yAfter, from: 0, to: xBefore.upperBound)

        case 0x2564: // down single, horizontal double
            fill(fullX, yBefore); fill(fullX, yAfter)
            vertical(xCenter, from: yAfter.lowerBound, to: fullY.upperBound)
        case 0x2565: // down double, horizontal single
            fill(fullX, yCenter)
            vertical(xBefore, from: yCenter.lowerBound, to: fullY.upperBound)
            vertical(xAfter, from: yCenter.lowerBound, to: fullY.upperBound)
        case 0x2566: // double down and horizontal
            fill(fullX, yBefore)
            horizontal(yAfter, from: 0, to: xBefore.upperBound)
            horizontal(yAfter, from: xAfter.lowerBound, to: fullX.upperBound)
            vertical(xBefore, from: yAfter.lowerBound, to: fullY.upperBound)
            vertical(xAfter, from: yAfter.lowerBound, to: fullY.upperBound)
        case 0x2567: // up single, horizontal double
            fill(fullX, yBefore); fill(fullX, yAfter)
            vertical(xCenter, from: 0, to: yBefore.upperBound)
        case 0x2568: // up double, horizontal single
            fill(fullX, yCenter)
            vertical(xBefore, from: 0, to: yCenter.upperBound)
            vertical(xAfter, from: 0, to: yCenter.upperBound)
        case 0x2569: // double up and horizontal
            horizontal(yBefore, from: 0, to: xBefore.upperBound)
            horizontal(yBefore, from: xAfter.lowerBound, to: fullX.upperBound)
            fill(fullX, yAfter)
            vertical(xBefore, from: 0, to: yBefore.upperBound)
            vertical(xAfter, from: 0, to: yBefore.upperBound)
        case 0x256A: // vertical single, horizontal double
            fill(xCenter, fullY); fill(fullX, yBefore); fill(fullX, yAfter)
        case 0x256B: // vertical double, horizontal single
            fill(xBefore, fullY); fill(xAfter, fullY); fill(fullX, yCenter)
        case 0x256C: // double vertical and horizontal
            vertical(xBefore, from: 0, to: yBefore.upperBound)
            vertical(xAfter, from: 0, to: yBefore.upperBound)
            vertical(xBefore, from: yAfter.lowerBound, to: fullY.upperBound)
            vertical(xAfter, from: yAfter.lowerBound, to: fullY.upperBound)
            horizontal(yBefore, from: 0, to: xBefore.upperBound)
            horizontal(yBefore, from: xAfter.lowerBound, to: fullX.upperBound)
            horizontal(yAfter, from: 0, to: xBefore.upperBound)
            horizontal(yAfter, from: xAfter.lowerBound, to: fullX.upperBound)
        default:
            break
        }
    }
}
