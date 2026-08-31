import AppKit

/// A color theme: 16 ANSI colors plus background / foreground / cursor / border.
/// The border color is used for the C64-style chunky frame around the grid.
public struct Theme: Sendable {
    public let name: String
    public let ansi: [TermColor]  // exactly 16 entries (ANSI 0-15)
    public let background: TermColor
    public let foreground: TermColor
    public let cursor: TermColor
    public let border: TermColor

    public func ns(_ c: TermColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red) / 65535.0,
                green: CGFloat(c.green) / 65535.0,
                blue: CGFloat(c.blue) / 65535.0,
                alpha: 1.0)
    }

    public func replacingCursor(with color: TermColor) -> Theme {
        Theme(name: name, ansi: ansi, background: background,
              foreground: foreground, cursor: color, border: border)
    }

    // MARK: - Hex construction

    /// Parse "#rrggbb" / "rrggbb" into a TermColor. Returns nil on malformed input.
    public static func hex(_ s: String) -> TermColor? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        let r = Int((v >> 16) & 0xFF), g = Int((v >> 8) & 0xFF), b = Int(v & 0xFF)
        return TermColor(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
    }

    /// Compact builder: 16 ANSI hex strings + the four scalar colors.
    /// Traps on malformed built-in definitions (programmer error, caught in --selftest).
    public static func make(_ name: String, ansi: [String], bg: String, fg: String,
                     cursor: String? = nil, border: String? = nil) -> Theme {
        precondition(ansi.count == 16, "theme \(name): need 16 ANSI colors")
        let colors = ansi.map { hex($0)! }
        return Theme(name: name, ansi: colors, background: hex(bg)!, foreground: hex(fg)!,
                     cursor: hex(cursor ?? fg)!, border: hex(border ?? bg)!)
    }

    // MARK: - Registry

    /// User themes from ~/.config/cmdy/themes/*.json, loaded at launch and on
    /// config reload. A user theme with a built-in's name overrides it.
    nonisolated(unsafe) private(set) static var userThemes: [String: Theme] = loadUserThemes()

    public static func reloadUserThemes() { userThemes = loadUserThemes() }

    public static func named(_ name: String) -> Theme {
        userThemes[name] ?? builtins.first { $0.name == name } ?? c64
    }

    /// Menu order: the five originals, the gallery, then user themes (alphabetical).
    public static var names: [String] {
        builtins.map(\.name) + userThemes.keys.filter { n in !builtins.contains { $0.name == n } }.sorted()
    }

    public static let builtins: [Theme] = [
        c64, dark, amber, green, light, blackWhite, whiteBlack,
        dracula, nord, catppuccinMocha, gruvboxDark, tokyoNight,
        solarizedDark, solarizedLight, monokai, rosePine, oneDark,
    ]

    // MARK: - User themes (JSON)

    /// Format: {"name": "...", "background": "#...", "foreground": "#...",
    ///          "cursor": "#...", "border": "#...", "ansi": ["#...", x16]}
    /// cursor/border are optional (default fg/bg). Malformed files are skipped.
    private static func loadUserThemes() -> [String: Theme] {
        let dir = ConfigFile.directory.appendingPathComponent("themes")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: Theme] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? BoundedFileReader.data(
                    at: url, maxBytes: 1024 * 1024),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String,
                  let bgs = obj["background"] as? String, let bg = hex(bgs),
                  let fgs = obj["foreground"] as? String, let fg = hex(fgs),
                  let ansiStrings = obj["ansi"] as? [String], ansiStrings.count == 16
            else { NSLog("cmdy: skipping malformed theme %@", url.lastPathComponent); continue }
            let ansi = ansiStrings.compactMap { hex($0) }
            guard ansi.count == 16 else { NSLog("cmdy: bad color in theme %@", url.lastPathComponent); continue }
            let cursor = (obj["cursor"] as? String).flatMap { hex($0) } ?? fg
            let border = (obj["border"] as? String).flatMap { hex($0) } ?? bg
            out[name] = Theme(name: name, ansi: ansi, background: bg, foreground: fg,
                              cursor: cursor, border: border)
        }
        return out
    }

    // MARK: - Originals

    /// Commodore 64 (Pepto palette). Blue background, light-blue text & border.
    public static let c64 = make("C64",
        ansi: ["#000000", "#68372B", "#588D43", "#B8C76F", "#352879", "#6F3D86", "#70A4B2", "#959595",
               "#444444", "#9A6759", "#9AD284", "#6F4F25", "#6C5EB5", "#6F3D86", "#70A4B2", "#FFFFFF"],
        bg: "#352879", fg: "#6C5EB5", cursor: "#6C5EB5", border: "#6C5EB5")

    public static let dark = make("Dark",
        ansi: ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
               "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#efefef"],
        bg: "#1d1f21", fg: "#c5c8c6", cursor: "#81a2be", border: "#2b2e31")

    public static let amber: Theme = {
        let fg = "#FFB000"
        return make("Amber", ansi: Array(repeating: fg, count: 16),
                    bg: "#1a1000", fg: fg, cursor: fg, border: "#B07800")
    }()

    public static let green: Theme = {
        let fg = "#33FF33"
        return make("Green", ansi: Array(repeating: fg, count: 16),
                    bg: "#001400", fg: fg, cursor: fg, border: "#1fa01f")
    }()

    /// Pure monochrome, one ink each way (like Amber/Green: every ANSI slot is
    /// the ink, so nothing ever disappears into the background).
    public static let blackWhite = make("B/W",
        ansi: Array(repeating: "#FFFFFF", count: 16),
        bg: "#000000", fg: "#FFFFFF", cursor: "#FFFFFF", border: "#333333")

    public static let whiteBlack = make("W/B",
        ansi: Array(repeating: "#000000", count: 16),
        bg: "#FFFFFF", fg: "#000000", cursor: "#000000", border: "#CCCCCC")

    public static let light = make("Light",
        ansi: ["#000000", "#c82829", "#008e00", "#7a6a00", "#0043c8", "#a51ca5", "#00838b", "#d8d8d8",
               "#707070", "#f05050", "#30c030", "#c0a000", "#4080f0", "#d060d0", "#40b0b0", "#1a1a1a"],
        bg: "#fafaf5", fg: "#1a1a1a", cursor: "#0043c8", border: "#e0e0da")

    // MARK: - Gallery (faithful ports of the classics)

    public static let dracula = make("Dracula",
        ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
               "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"],
        bg: "#282a36", fg: "#f8f8f2", cursor: "#f8f8f2", border: "#21222c")

    public static let nord = make("Nord",
        ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
               "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"],
        bg: "#2e3440", fg: "#d8dee9", cursor: "#d8dee9", border: "#3b4252")

    public static let catppuccinMocha = make("Catppuccin Mocha",
        ansi: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
               "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"],
        bg: "#1e1e2e", fg: "#cdd6f4", cursor: "#f5e0dc", border: "#313244")

    public static let gruvboxDark = make("Gruvbox Dark",
        ansi: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
               "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"],
        bg: "#282828", fg: "#ebdbb2", cursor: "#ebdbb2", border: "#3c3836")

    public static let tokyoNight = make("Tokyo Night",
        ansi: ["#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
               "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"],
        bg: "#1a1b26", fg: "#c0caf5", cursor: "#c0caf5", border: "#24283b")

    public static let solarizedDark = make("Solarized Dark",
        ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
               "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"],
        bg: "#002b36", fg: "#839496", cursor: "#839496", border: "#073642")

    public static let solarizedLight = make("Solarized Light",
        ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
               "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"],
        bg: "#fdf6e3", fg: "#657b83", cursor: "#657b83", border: "#eee8d5")

    public static let monokai = make("Monokai",
        ansi: ["#272822", "#f92672", "#a6e22e", "#e6db74", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
               "#75715e", "#f92672", "#a6e22e", "#e6db74", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"],
        bg: "#272822", fg: "#f8f8f2", cursor: "#f8f8f2", border: "#3e3d32")

    public static let rosePine = make("Rosé Pine",
        ansi: ["#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
               "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4"],
        bg: "#191724", fg: "#e0def4", cursor: "#e0def4", border: "#26233a")

    public static let oneDark = make("One Dark",
        ansi: ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
               "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"],
        bg: "#282c34", fg: "#abb2bf", cursor: "#528bff", border: "#21252b")
}
