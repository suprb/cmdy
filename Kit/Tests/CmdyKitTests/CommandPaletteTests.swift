import XCTest
@testable import CmdyKit

final class CommandPaletteTests: XCTestCase {
    private func settingsTree(on: @escaping () -> Void = {},
                              off: @escaping () -> Void = {}) -> [PaletteItem] {
        [.section("Settings", "", [
            .section("Ghost Text", "on", [
                PaletteItem(title: "On", subtitle: "current", action: on),
                PaletteItem(title: "Off", action: off),
            ], keywords: ["autocomplete", "autosuggestion", "history completion"]),
            .section("Sounds", "off", [
                PaletteItem(title: "On"), PaletteItem(title: "Off", subtitle: "current"),
            ]),
        ], keywords: ["preferences"])]
    }

    func testSearchFindsSettingNameAndKeepsItsActionAndVisibleContext() throws {
        var picks: [String] = []
        let results = CommandPalette.search(
            query: "ghost text",
            items: settingsTree(on: { picks.append("on") }, off: { picks.append("off") }))

        XCTAssertEqual(results.map(\.title), ["On", "Off"])
        XCTAssertEqual(results.map(\.displayTitle), ["Ghost Text → On", "Ghost Text → Off"])
        XCTAssertEqual(results.first?.ancestors, ["Settings", "Ghost Text"])
        XCTAssertEqual(results.first?.displaySubtitle, "Settings · current")
        XCTAssertTrue(picks.isEmpty, "Indexing must never run an action or change a setting")
        try XCTUnwrap(results.last).action()
        XCTAssertEqual(picks, ["off"])
    }

    func testSearchSupportsTokensInAnyOrderAndInheritedSynonyms() {
        for query in ["ghost text off", "off ghost text", "autocomplete off",
                      "preferences ghost text off", "HISTORY completion OFF"] {
            let first = CommandPalette.search(query: query, items: settingsTree()).first
            XCTAssertEqual(first?.title, "Off", query)
            XCTAssertEqual(first?.ancestors.last, "Ghost Text", query)
        }
    }

    func testExactSettingNameRanksAboveAnIncidentalDescription() {
        let incidental = PaletteItem(title: "Troubleshoot Rendering", subtitle: "ghost text diagnostics")
        let results = CommandPalette.search(query: "ghost text", items: [incidental] + settingsTree())
        XCTAssertEqual(results.prefix(2).map(\.ancestors),
                       [["Settings", "Ghost Text"], ["Settings", "Ghost Text"]])
        XCTAssertEqual(results.last?.title, "Troubleshoot Rendering")
    }

    func testEqualScoresKeepCatalogOrderingAndDistinctSettingIdentities() {
        let items: [PaletteItem] = [.section("Choices", "", [
            PaletteItem(title: "Zulu"), PaletteItem(title: "Alpha"), PaletteItem(title: "Beta"),
        ])]
        for _ in 0..<10 {
            XCTAssertEqual(CommandPalette.search(query: "choices", items: items).map(\.title),
                           ["Zulu", "Alpha", "Beta"])
        }
        let toggles = CommandPalette.search(query: "settings off", items: settingsTree())
        XCTAssertEqual(toggles.count, 2)
        XCTAssertEqual(Set(toggles.map(\.identifier)).count, 2)
    }

    func testSubtreeSearchRetainsTheNavigationPath() {
        let result = CommandPalette.search(
            query: "ghost text off", items: [PaletteItem(title: "Off")],
            ancestors: ["Settings", "Ghost Text"]).first
        XCTAssertEqual(result?.displayTitle, "Ghost Text → Off")
        XCTAssertEqual(result?.displaySubtitle, "Settings")
    }

    func testImmediateShellExecutionIsDistinctAndRankedAfterActions() {
        let items: [PaletteItem] = [
            .section("Shell History", "", [
                PaletteItem(title: "git", subtitle: "runs immediately", kind: .shellCommand),
            ]),
            .section("Workspaces", "", [PaletteItem(title: "Open Git Worktree")]),
        ]
        let results = CommandPalette.search(query: "git", items: items)
        XCTAssertEqual(results.map(\.kind), [.action, .shellCommand])
        XCTAssertEqual(results.last?.displayTitle, "Shell History → git")
        XCTAssertEqual(results.last?.displaySubtitle, "runs immediately")
    }

    func testRecentActionsResolveFreshClosuresAndExcludeShellHistory() throws {
        var picked = ""
        let old: [PaletteItem] = [.section("Terminal", "", [
            PaletteItem(title: "Find", action: { picked = "old pane" }),
            PaletteItem(title: "Run: pwd", kind: .shellCommand),
        ])]
        let identifiers = PaletteItem.flatten(old).map(\.identifier)
        let fresh: [PaletteItem] = [.section("Terminal", "", [
            PaletteItem(title: "Find", action: { picked = "current pane" }),
            PaletteItem(title: "Run: pwd", kind: .shellCommand),
        ])]
        let recent = CommandPalette.recentActions(
            identifiers: identifiers + identifiers + ["removed action"], items: fresh)
        XCTAssertEqual(recent.map(\.title), ["Find"])
        XCTAssertTrue(picked.isEmpty)
        try XCTUnwrap(recent.first).action()
        XCTAssertEqual(picked, "current pane")

        let results = CommandPalette.search(query: "find", items: recent + fresh)
        XCTAssertEqual(results.count, 1, "Recent picks must not duplicate search results")
    }

    func testEmptyQueryKeepsNavigableSectionsAndFuzzyAbbreviationsStillWork() {
        let tree = settingsTree()
        let emptyResults = CommandPalette.search(query: "  \n ", items: tree)
        XCTAssertEqual(emptyResults.first?.title, "Settings")
        XCTAssertNotNil(emptyResults.first?.children)
        XCTAssertNotNil(CommandPalette.fuzzyScore(query: "thdra", target: "Theme: Dracula"))
        XCTAssertEqual(CommandPalette.search(query: "ghst txt", items: tree).count, 2)
        XCTAssertTrue(CommandPalette.search(query: "zzzzz", items: tree).isEmpty)
    }
}
