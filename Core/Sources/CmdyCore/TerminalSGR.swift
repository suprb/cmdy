import Foundation

// Select Graphic Rendition is decoded in two phases: a bounded scanner turns
// the flat VT parameter stream into semantic operations, then the reducer
// applies those operations to the current cell attributes. Keeping those
// phases separate makes malformed/truncated parameter consumption explicit.
private enum SGRColorTarget {
    case foreground
    case background
    case underline
}

private enum SGROperation {
    case reset
    case addStyle(CellStyle)
    case removeStyle(CellStyle)
    case underline(UnderlineKind)
    case color(SGRColorTarget, CellColor?)
    case ignore
}

private struct SGRScanner {
    private let values: [Int]
    private var cursor = 0
    private let separator = VTParser.colonSeparator

    init(_ rawValues: [Int]) {
        values = rawValues.isEmpty ? [0] : rawValues
    }

    mutating func next() -> SGROperation? {
        guard cursor < values.count else { return nil }
        let selector = values[cursor]

        if selector == separator {
            cursor += 1
            return .ignore
        }

        if hasColonGroup(at: cursor) {
            let group = takeColonGroup(startingAt: cursor)
            switch selector {
            case 4:
                return decodeUnderline(group)
            case 38:
                return decodeColor(group, target: .foreground)
            case 48:
                return decodeColor(group, target: .background)
            case 58:
                return decodeColor(group, target: .underline)
            default:
                return .ignore
            }
        }

        switch selector {
        case 38:
            return takeSemicolonColor(target: .foreground)
        case 48:
            return takeSemicolonColor(target: .background)
        case 58:
            return takeSemicolonColor(target: .underline)
        default:
            cursor += 1
            return Self.simpleOperations[selector]
                ?? Self.ansiColorOperation(selector: selector)
                ?? .ignore
        }
    }

    private func hasColonGroup(at index: Int) -> Bool {
        index + 1 < values.count && values[index + 1] == separator
    }

    /// Consumes the selector plus every `:<value>` pair in this one group.
    /// A dangling colon is consumed as part of the malformed group.
    private mutating func takeColonGroup(startingAt start: Int) -> [Int] {
        var group: [Int] = []
        var index = start + 1
        while index < values.count, values[index] == separator {
            index += 1
            guard index < values.count else { break }
            group.append(values[index])
            index += 1
        }
        cursor = index
        return group
    }

    private func decodeUnderline(_ group: [Int]) -> SGROperation {
        guard group.count == 1 else { return .ignore }
        switch group[0] {
        case 0: return .underline(.none)
        case 1: return .underline(.single)
        case 2: return .underline(.double)
        case 3: return .underline(.curly)
        case 4: return .underline(.dotted)
        case 5: return .underline(.dashed)
        default: return .ignore
        }
    }

    private func decodeColor(_ group: [Int], target: SGRColorTarget) -> SGROperation {
        guard let mode = group.first else { return .ignore }
        switch mode {
        case 5:
            guard group.count == 2, let color = Self.indexed(group[1]) else {
                return .ignore
            }
            return .color(target, color)
        case 2:
            let channels: ArraySlice<Int>
            if group.count == 4 {
                channels = group[1...3]
            } else if group.count == 5, group[1] == 0 {
                // ISO-8613-6 color-space slot. Empty sub-parameters arrive as
                // zero because the VT parser deliberately normalizes them.
                channels = group[2...4]
            } else {
                return .ignore
            }
            guard let color = Self.rgb(Array(channels)) else { return .ignore }
            return .color(target, color)
        default:
            return .ignore
        }
    }

    /// Legacy semicolon forms have fixed arity. A complete form owns all of
    /// its operands. A truncated RGB form owns only the selector and mode, so
    /// partial channel values retain their ordinary SGR meaning.
    private mutating func takeSemicolonColor(target: SGRColorTarget) -> SGROperation {
        let start = cursor
        guard start + 1 < values.count else {
            cursor += 1
            return .ignore
        }

        let mode = values[start + 1]
        switch mode {
        case 5:
            let end = min(values.count, start + 3)
            cursor = end
            guard end == start + 3, let color = Self.indexed(values[start + 2]) else {
                return .ignore
            }
            return .color(target, color)
        case 2:
            let end = start + 5
            guard end <= values.count else {
                cursor = start + 2
                return .ignore
            }
            cursor = end
            guard let color = Self.rgb(Array(values[(start + 2)..<end])) else {
                return .ignore
            }
            return .color(target, color)
        default:
            cursor = start + 2
            return .ignore
        }
    }

    private static func indexed(_ value: Int) -> CellColor? {
        guard (0...255).contains(value) else { return nil }
        return .ansi256(UInt8(value))
    }

    private static func rgb(_ channels: [Int]) -> CellColor? {
        guard channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return .trueColor(UInt8(channels[0]), UInt8(channels[1]), UInt8(channels[2]))
    }

    private static let simpleOperations: [Int: SGROperation] = [
        0: .reset,
        1: .addStyle(.bold),
        2: .addStyle(.dim),
        3: .addStyle(.italic),
        4: .underline(.single),
        5: .addStyle(.blink),
        6: .addStyle(.blink),
        7: .addStyle(.inverse),
        8: .addStyle(.invisible),
        9: .addStyle(.crossedOut),
        21: .underline(.double),
        22: .removeStyle([.bold, .dim]),
        23: .removeStyle(.italic),
        24: .underline(.none),
        25: .removeStyle(.blink),
        27: .removeStyle(.inverse),
        28: .removeStyle(.invisible),
        29: .removeStyle(.crossedOut),
        39: .color(.foreground, .defaultColor),
        49: .color(.background, .defaultColor),
        59: .color(.underline, nil),
    ]
}

extension CmdyTerminal {
    func applySGR(_ rawParams: [Int]) {
        var scanner = SGRScanner(rawParams)
        while let operation = scanner.next() {
            reduceSGR(operation)
        }
    }

    private func reduceSGR(_ operation: SGROperation) {
        switch operation {
        case .reset:
            currentAttribute = .empty
        case .addStyle(let style):
            currentAttribute.style.formUnion(style)
        case .removeStyle(let style):
            currentAttribute.style.subtract(style)
        case .underline(let kind):
            currentAttribute.underlineKind = kind
            if kind == .none {
                currentAttribute.style.remove(.underline)
            } else {
                currentAttribute.style.insert(.underline)
            }
        case .color(.foreground, let color):
            if let color { currentAttribute.fg = color }
        case .color(.background, let color):
            if let color { currentAttribute.bg = color }
        case .color(.underline, let color):
            currentAttribute.underlineColor = color
        case .ignore:
            break
        }
    }
}

private extension SGRScanner {
    static func ansiColorOperation(selector: Int) -> SGROperation? {
        switch selector {
        case 30...37:
            return .color(.foreground, .ansi256(UInt8(selector - 30)))
        case 40...47:
            return .color(.background, .ansi256(UInt8(selector - 40)))
        case 90...97:
            return .color(.foreground, .ansi256(UInt8(selector - 90 + 8)))
        case 100...107:
            return .color(.background, .ansi256(UInt8(selector - 100 + 8)))
        default:
            return nil
        }
    }
}
