import Foundation

/// One entry in the command palette (rendered by InlinePanel — the palette
/// is part of the terminal, not a floating window). An item with `children`
/// is a SECTION: ⏎/→ descends into it, ← backs out (tree navigation).
public struct PaletteItem {
    public enum Kind: Equatable {
        case action
        /// Selecting the item immediately submits text to the focused shell.
        case shellCommand
    }

    public let title: String
    public var subtitle: String = ""
    public var action: () -> Void = {}
    public var kind: Kind
    /// Alternative names are inherited by descendants during search.
    public var keywords: [String]
    /// Filled when indexing a tree, so a result keeps the setting it belongs to.
    public private(set) var ancestors: [String] = []
    /// Set on settings rows (theme/font/shader/cursor): applied live while
    /// the row is selected — ⏎ keeps it, esc/moving away reverts.
    public var preview: (() -> Void)?
    /// Non-nil → this is a navigable section.
    public var children: [PaletteItem]?

    public init(title: String, subtitle: String = "", action: @escaping () -> Void = {},
                preview: (() -> Void)? = nil, children: [PaletteItem]? = nil,
                kind: Kind = .action, keywords: [String] = []) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.preview = preview
        self.children = children
        self.kind = kind
        self.keywords = keywords
    }

    /// Section constructor.
    public static func section(_ title: String, _ subtitle: String = "", _ children: [PaletteItem],
                               keywords: [String] = []) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle, children: children, keywords: keywords)
    }

    public var displayTitle: String {
        guard let parent = ancestors.last else { return title }
        return "\(parent) → \(title)"
    }

    public var displaySubtitle: String {
        let context = ancestors.dropLast().joined(separator: " › ")
        return [context, subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Stable within a catalog. Store this instead of retaining action closures.
    public var identifier: String { (ancestors + [title]).joined(separator: "\u{1f}") }

    public func inContext(_ path: [String]) -> PaletteItem {
        var copy = self
        if copy.ancestors.isEmpty { copy.ancestors = path }
        return copy
    }

    /// This item and every descendant, sections excluded — the pool a
    /// root-level search runs over (scales to any tree size).
    static func flatten(_ items: [PaletteItem], ancestors: [String] = [],
                        keywords: [String] = []) -> [PaletteItem] {
        var out: [PaletteItem] = []
        for item in items {
            if let kids = item.children {
                out.append(contentsOf: flatten(kids, ancestors: ancestors + [item.title],
                                               keywords: keywords + item.keywords))
            } else {
                var leaf = item.inContext(ancestors)
                leaf.keywords = keywords + item.keywords
                out.append(leaf)
            }
        }
        return out
    }
}

/// The palette's fuzzy matcher (kept as a pure function — selftest-covered).
public enum CommandPalette {
    /// Search the whole subtree without losing labels such as Settings → Ghost
    /// Text → Off. Tokens may be entered in any order. Equal scores retain the
    /// catalog's order, and immediate shell executions are grouped last.
    public static func search(query: String, items: [PaletteItem],
                              ancestors: [String] = []) -> [PaletteItem] {
        let query = normalized(query)
        guard !query.isEmpty else { return items }
        var seen = Set<String>()
        return PaletteItem.flatten(items, ancestors: ancestors).enumerated()
            .compactMap { offset, item -> (item: PaletteItem, score: Int, offset: Int)? in
                guard seen.insert(item.identifier).inserted,
                      let score = searchScore(query: query, item: item) else { return nil }
                return (item, score, offset)
            }
            .sorted {
                if $0.item.kind != $1.item.kind { return $0.item.kind == .action }
                return $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score
            }
            .map(\.item)
    }

    /// Resolves remembered identifiers against fresh actions for the current
    /// pane. Shell history is kept out of the frequently used action area.
    public static func recentActions(identifiers: [String], items: [PaletteItem],
                                     limit: Int = 4) -> [PaletteItem] {
        let leaves = PaletteItem.flatten(items)
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted else { return nil }
            return leaves.first { $0.identifier == identifier && $0.kind == .action }
        }.prefix(max(0, limit)).map { $0 }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func searchScore(query: String, item: PaletteItem) -> Int? {
        let title = normalized(item.title)
        let parent = normalized(item.ancestors.last ?? "")
        let fields: [(String, Int)] = [(title, 100), (parent, 90)]
            + item.ancestors.dropLast().map { (normalized($0), 65) }
            + item.keywords.map { (normalized($0), 55) }
            + [(normalized(item.subtitle), 25)]
        var score = 0
        for token in query.split(separator: " ").map(String.init) {
            let best = fields.compactMap { field, weight -> Int? in
                guard !field.isEmpty else { return nil }
                let words = field.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                if words.contains(where: { $0 == token }) { return weight + 100 }
                if words.contains(where: { $0.hasPrefix(token) }) { return weight + 70 }
                if field.contains(token) { return weight + 40 }
                return fuzzyScore(query: token, target: field).map { weight + min(30, $0) }
            }.max()
            guard let best else { return nil }
            score += best
        }
        // A setting name is a stronger match than an unrelated action whose
        // description happens to contain the same words.
        if title == query { score += 1_200 }
        else if parent == query { score += 1_100 }
        else if title.hasPrefix(query) { score += 700 }
        else if parent.hasPrefix(query) { score += 600 }
        else if title.contains(query) || parent.contains(query) { score += 350 }
        return score
    }

    /// Subsequence match with a simple score: consecutive hits and word-starts
    /// score higher; nil when `query` is not a subsequence of `target`.
    public static func fuzzyScore(query: String, target: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased()), t = Array(target.lowercased())
        var qi = 0, score = 0, streak = 0
        for (i, ch) in t.enumerated() where qi < q.count {
            if ch == q[qi] {
                qi += 1
                streak += 1
                score += 1 + streak * 2
                if i == 0 || t[i - 1] == " " || t[i - 1] == ":" { score += 8 }   // word start
            } else {
                streak = 0
            }
        }
        return qi == q.count ? score - t.count / 4 : nil   // light penalty for long targets
    }
}
