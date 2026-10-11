import Foundation

// Foundation supplies Unicode text search and regular expressions over native rows.
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
