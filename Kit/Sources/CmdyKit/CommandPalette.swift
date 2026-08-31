import Foundation

/// One entry in the command palette (rendered by InlinePanel — the palette
/// is part of the terminal, not a floating window). An item with `children`
/// is a SECTION: ⏎/→ descends into it, ← backs out (tree navigation).
public struct PaletteItem {
    public let title: String
    public var subtitle: String = ""
    public var action: () -> Void = {}
    /// Set on settings rows (theme/font/shader/cursor): applied live while
    /// the row is selected — ⏎ keeps it, esc/moving away reverts.
    public var preview: (() -> Void)?
    /// Non-nil → this is a navigable section.
    public var children: [PaletteItem]?

    public init(title: String, subtitle: String = "", action: @escaping () -> Void = {},
                preview: (() -> Void)? = nil, children: [PaletteItem]? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.preview = preview
        self.children = children
    }

    /// Section constructor.
    public static func section(_ title: String, _ subtitle: String = "", _ children: [PaletteItem]) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle, children: children)
    }

    /// This item and every descendant, sections excluded — the pool a
    /// root-level search runs over (scales to any tree size).
    static func flatten(_ items: [PaletteItem]) -> [PaletteItem] {
        var out: [PaletteItem] = []
        for item in items {
            if let kids = item.children {
                out.append(contentsOf: flatten(kids))
            } else {
                out.append(item)
            }
        }
        return out
    }
}

/// The palette's fuzzy matcher (kept as a pure function — selftest-covered).
public enum CommandPalette {
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
