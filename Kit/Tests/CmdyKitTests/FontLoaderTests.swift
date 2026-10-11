import AppKit
import CoreText
import ProductIdentity
import XCTest
@testable import CmdyKit

final class FontLoaderTests: XCTestCase {
    private let entries = [
        FontLoader.Entry(displayName: "First Mono", fontName: "First-Regular", resource: "First.ttf"),
        FontLoader.Entry(displayName: "Second Mono", fontName: "Second-Regular", resource: "Second.otf"),
    ]

    private var urls: [URL] { entries.map { URL(fileURLWithPath: "/fonts/" + $0.resource) } }

    func testCatalogMatchesEveryShippedFontDescriptor() throws {
        let bundle = try XCTUnwrap(ProductResourceBundle.bundle(named: "Kit_CmdyKit"))
        let catalog = try XCTUnwrap(bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Fonts"))
        let entries = try JSONDecoder().decode([FontLoader.Entry].self, from: Data(contentsOf: catalog))
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            + (bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? [])
        XCTAssertEqual(entries.count, 35)
        XCTAssertEqual(Set(entries.map(\.resource)), Set(urls.map(\.lastPathComponent)))
        XCTAssertEqual(Set(entries.map(\.fontName)).count, entries.count)
        for entry in entries {
            let url = try XCTUnwrap(urls.first { $0.lastPathComponent == entry.resource })
            let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
            let descriptor = try XCTUnwrap(descriptors.first)
            XCTAssertEqual(CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, entry.fontName)
            XCTAssertEqual(CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String, entry.displayName)
        }
    }

    func testEnumerationDoesNotRegisterAndSelectionLoadsOnlyItsFace() throws {
        var calls: [URL] = []
        let registry = FontLoader.Registry(entries: entries, urls: urls) { calls.append($0); return true }
        XCTAssertEqual(registry.fonts.map(\.fontName), entries.map(\.fontName))
        let selected = try XCTUnwrap(registry.entry(named: "second mono"))
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(registry.registerSelected(selected))
        XCTAssertTrue(registry.registerSelected(selected))
        XCTAssertEqual(calls, [urls[1]])
        XCTAssertEqual(registry.entry(named: "SECOND-REGULAR")?.resource, selected.resource)
        XCTAssertNil(registry.entry(named: "Missing"))
    }

    func testConcurrentSelectionAndFallbackRegisterEachFaceOnce() {
        var calls: [URL: Int] = [:]
        let registry = FontLoader.Registry(entries: entries, urls: urls) {
            calls[$0, default: 0] += 1
            return true
        }
        let selected = entries[1]
        DispatchQueue.concurrentPerform(iterations: 128) { i in
            XCTAssertTrue(i % 2 == 0 ? registry.registerSelected(selected) : registry.registerAll())
        }
        XCTAssertEqual(calls, Dictionary(uniqueKeysWithValues: urls.map { ($0, 1) }))
    }

    func testFailureRetriesOnlyTheFailedFace() {
        let paths = urls
        var calls: [URL: Int] = [:]
        let registry = FontLoader.Registry(entries: entries, urls: paths) {
            calls[$0, default: 0] += 1
            return $0 != paths[0] || calls[$0] != 1
        }
        XCTAssertFalse(registry.registerAll())
        XCTAssertEqual(calls, [paths[0]: 1, paths[1]: 1])
        XCTAssertTrue(registry.registerAll())
        XCTAssertTrue(registry.registerAll())
        XCTAssertEqual(calls, [paths[0]: 2, paths[1]: 1])
    }

    func testMissingOrStaleMetadataDiscoversPackagedFaces() throws {
        let source = try XCTUnwrap(ProductResourceBundle.bundle(named: "Kit_CmdyKit"))
        let font = try XCTUnwrap(source.url(forResource: "FragmentMono", withExtension: "ttf", subdirectory: "Fonts"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fonts"), withIntermediateDirectories: true)
        let copied = root.appendingPathComponent("Fonts/FragmentMono.ttf")
        try FileManager.default.copyItem(at: font, to: copied)
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(FontLoader.entries(in: bundle, urls: [copied]).map(\.fontName), [Preferences.defaultFontName])
        try Data("[]".utf8).write(to: root.appendingPathComponent("Fonts/catalog.json"))
        XCTAssertEqual(FontLoader.entries(in: bundle, urls: [copied]).map(\.fontName), [Preferences.defaultFontName])
    }

    func testSelectedFontResolutionPreservesPostscriptAndFamilyNames() {
        for entry in FontLoader.bundledFonts {
            XCTAssertEqual(FontLoader.font(named: entry.fontName, size: 13)?.fontName, entry.fontName)
            XCTAssertEqual(FontLoader.font(named: entry.displayName, size: 13)?.fontName, entry.fontName)
        }
        XCTAssertEqual(FontLoader.font(named: "Menlo-Regular", size: 13)?.fontName, "Menlo-Regular")
        XCTAssertNil(FontLoader.font(named: "CMDY Missing Font 73DA33", size: 13))
        XCTAssertNil(FontLoader.font(named: "System", size: 13))
    }
}
