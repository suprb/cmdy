// Compiled with the actual font catalog/appearance declarations from
// App/WorkspaceContext.swift and the current CmdyKit objects. Fresh process,
// no application, window, preferences writes or accounting.
import AppKit
import CoreText
import CmdyKit

func availableNames() -> Set<String> {
    Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
}

let before = availableNames()
let bundledFonts = FontLoader.bundledFonts
let bundledNames = Set(bundledFonts.map(\.fontName))
let initiallyRegistered = before.intersection(bundledNames)

func requireLoaded(_ selected: Set<String>) {
    precondition(availableNames().intersection(bundledNames) == initiallyRegistered.union(selected))
}

precondition(bundledFonts.count == 35)
precondition(TerminalAppearanceFontCatalog.choices.count == 36)
for item in bundledFonts {
    precondition(TerminalAppearanceFontCatalog.displayName(for: item.fontName) == item.displayName)
}
requireLoaded([])

let first = Preferences.defaultFontName
precondition(ConfigFile.validationIssues(for: ["font-family":first]).isEmpty)
precondition(TerminalAppearanceFontCatalog.resolvedFont(name: first, size: 15).fontName == first)
requireLoaded([first])

let restored = "GeistMono-Regular"
let appearance = TerminalTabAppearance.restored(themeName: nil, shaderName: nil, fontName: " \(restored) ")
precondition(appearance.fontName == restored)
precondition(appearance.resolvedFontName(global: first) == restored)
requireLoaded([first, restored])

let inherited = TerminalTabAppearance.restored(themeName: nil, shaderName: nil)
precondition(inherited.resolvedFontName(global: first) == first)
precondition(TerminalAppearanceFontCatalog.validated("System") == "System")
precondition(TerminalAppearanceFontCatalog.validated("Menlo-Regular") == "Menlo-Regular")
requireLoaded([first, restored])

// Family aliases stay usable in configuration; persisted workspace names keep
// the existing stricter requirement of a registered PostScript name.
precondition(ConfigFile.validationIssues(for: ["font-family":"JetBrains Mono"]).isEmpty)
precondition(TerminalAppearanceFontCatalog.validated("JetBrains Mono") == nil)
requireLoaded([first, restored, "JetBrainsMono-Regular"])
precondition(TerminalAppearanceFontCatalog.validated("CMDY Missing Font 73DA33") == nil)
precondition(!ConfigFile.validationIssues(for: ["font-family":"CMDY Missing Font 73DA33"]).isEmpty)
precondition(FontLoader.ensureFallbackFontsRegistered())
requireLoaded(bundledNames)
print("PASS: metadata-only menus, selected/configured/restored fonts, family aliases, inherited/system fonts, invalid names, full fallback registration")
