import Foundation

// Surface-support facilities: row damage for the GPU renderer, mouse report
// encoding, and buffer text search. Engine-level, platform-free.

// MARK: - Damage tracking

extension CmdyTerminal {
    /// Mark an absolute row dirty (the renderer rebuilds only these).
    func markDirty(absoluteRow row: Int) {
        if let current = dirtyRowSpan {
            dirtyRowSpan = min(current.lowerBound, row)...max(current.upperBound, row)
        } else {
            dirtyRowSpan = row...row
        }
    }

    func markDirty(absoluteRows range: ClosedRange<Int>) {
        markDirty(absoluteRow: range.lowerBound)
        markDirty(absoluteRow: range.upperBound)
    }

    /// Everything visible changed (scroll, clear, resize, buffer switch).
    func markAllDirty() {
        let buf = buffer
        dirtyRowSpan = buf.yDisp...(buf.yDisp + buf.rows - 1)
    }

    /// The renderer consumes and clears the span each frame.
    public func consumeDirtyRows() -> ClosedRange<Int>? {
        let span = dirtyRowSpan
        dirtyRowSpan = nil
        return span
    }
}

// MARK: - Mouse encoding

extension CmdyTerminal {
    /// Encode a mouse event per the active tracking mode + protocol and send
    /// it to the process. Returns true when the event was reported.
    /// `button`: 0 left, 1 middle, 2 right, 3 release(list), 64/65 wheel.
    @discardableResult
    public func sendMouseEvent(button: Int, pressed: Bool, motion: Bool,
                               modifiers: MouseModifiers, col: Int, row: Int) -> Bool {
        guard mouseMode != .off else { return false }
        if motion {
            switch mouseMode {
            case .anyEvent: break
            case .buttonEvent:
                guard pressed || button >= 0 else { return false }
            default:
                return false
            }
        } else {
            // x10 reports presses only.
            if mouseMode == .x10 && !pressed { return false }
        }

        var flags = button >= 64 ? button : (pressed || mouseProtocol == .sgr ? button : 3)
        if motion { flags += 32 }
        if modifiers.contains(.shift) { flags |= 4 }
        if modifiers.contains(.meta) { flags |= 8 }
        if modifiers.contains(.control) { flags |= 16 }

        let clampedCol = max(0, min(col, buffer.cols - 1))
        let clampedRow = max(0, min(row, buffer.rows - 1))

        switch mouseProtocol {
        case .sgr:
            let action = pressed ? "M" : "m"
            sendResponse("\u{1b}[<\(flags);\(clampedCol + 1);\(clampedRow + 1)\(action)")
        case .urxvt:
            sendResponse("\u{1b}[\(flags + 32);\(clampedCol + 1);\(clampedRow + 1)M")
        case .utf8, .x10:
            let b = UInt8(clamping: flags + 32)
            let cx = UInt8(clamping: clampedCol + 1 + 32)
            let cy = UInt8(clamping: clampedRow + 1 + 32)
            delegate?.send(self, data: ArraySlice([0x1B, 0x5B, 0x4D, b, cx, cy]))
        }
        return true
    }

    public struct MouseModifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = MouseModifiers(rawValue: 1)
        public static let meta = MouseModifiers(rawValue: 2)
        public static let control = MouseModifiers(rawValue: 4)
    }
}

// MARK: - Search

/// Plain-text search over the whole buffer (scrollback + live screen).
/// Matches are (absolute row, column, length-in-cells).
public struct TerminalSearchHit: Equatable {
    public let row: Int
    public let col: Int
    public let length: Int
}

extension CmdyTerminal {
    public struct SearchSpec {
        public var caseSensitive = false
        public var regex = false
        public init(caseSensitive: Bool = false, regex: Bool = false) {
            self.caseSensitive = caseSensitive
            self.regex = regex
        }
    }

    /// All hits, top to bottom. Logical lines are searched UNWRAPPED so a
    /// term straddling a soft wrap still matches.
    public func searchAll(_ term: String, spec: SearchSpec) -> [TerminalSearchHit] {
        guard !term.isEmpty else { return [] }
        var hits: [TerminalSearchHit] = []

        var row = 0
        while row < buffer.lineCount {
            // Assemble the logical line + a map from character offset → (row, col).
            var text = ""
            var positions: [(row: Int, col: Int)] = []
            var r = row
            repeat {
                guard let line = buffer.line(absolute: r) else { break }
                for (col, cell) in line.cells.enumerated() {
                    if cell.width == 0 { continue }
                    let t = cell.scalar == 0 ? " " : cell.text
                    text += t
                    positions.append((r, col))
                }
                r += 1
            } while r < buffer.lineCount && (buffer.line(absolute: r)?.isWrapped ?? false)

            let trimmed = text                     // keep offsets aligned
            if spec.regex {
                let options: NSRegularExpression.Options = spec.caseSensitive ? [] : [.caseInsensitive]
                if let re = try? NSRegularExpression(pattern: term, options: options) {
                    let ns = trimmed as NSString
                    for m in re.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                        if m.range.length > 0, m.range.location < positions.count {
                            let start = positions[m.range.location]
                            hits.append(TerminalSearchHit(row: start.row, col: start.col,
                                                          length: m.range.length))
                        }
                    }
                }
            } else {
                let haystack = spec.caseSensitive ? trimmed : trimmed.lowercased()
                let needle = spec.caseSensitive ? term : term.lowercased()
                var searchFrom = haystack.startIndex
                while let found = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
                    let offset = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
                    if offset < positions.count {
                        let start = positions[offset]
                        hits.append(TerminalSearchHit(row: start.row, col: start.col,
                                                      length: needle.count))
                    }
                    searchFrom = found.upperBound
                }
            }
            row = r
        }
        return hits
    }
}
