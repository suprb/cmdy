import AppKit
import XCTest
@testable import CmdyGPU

@MainActor
final class SharedTextAttributeKeyTests: XCTestCase {
    func testEverySupportedAttributeContributesToEqualityAndHashLookup() throws {
        let attributes = completeAttributes()
        let range = NSRange(location: 3, length: 7)
        let original = try key(attributes, range: range)
        let indexed = [original: "raster"]
        var reordered: [NSAttributedString.Key: Any] = [:]
        for name in attributes.keys.sorted(by: { $0.rawValue > $1.rawValue }) {
            reordered[name] = attributes[name]
        }
        XCTAssertEqual(indexed[try key(reordered, range: range)], "raster")

        // Omitting any raster input must not collide with a fully specified
        // key, even where multiple decoration or selection aliases coexist.
        for name in attributes.keys {
            var omitted = attributes
            omitted.removeValue(forKey: name)
            let changed = try key(omitted, range: range)
            XCTAssertNotEqual(changed, original, name.rawValue)
            XCTAssertNil(indexed[changed], name.rawValue)
        }
        XCTAssertNotEqual(original, try key(attributes, range: NSRange(location: 4, length: 7)))
        XCTAssertNotEqual(original, try key(attributes, range: NSRange(location: 3, length: 6)))
    }

    func testMalformedAndUnknownValuesDisableSharingWithoutPartialKeys() {
        let attributes = completeAttributes()
        for name in attributes.keys {
            for invalid: Any in [NSNull(), "not an attribute value", [1, 2]] {
                var changed = attributes
                changed[name] = invalid
                XCTAssertNil(IndependentSharedTextAttributeRunKey(
                    range: NSRange(location: 0, length: 1), attributes: changed), name.rawValue)
            }
        }
        var unknown = attributes
        unknown[NSAttributedString.Key("cmdy.unmodeled")] = NSColor.red
        XCTAssertNil(IndependentSharedTextAttributeRunKey(
            range: NSRange(location: 0, length: 1), attributes: unknown))
    }

    func testNumericBridgingAndAbsentVersusZeroKeepExistingSemantics() throws {
        for name: NSAttributedString.Key in [
            .ligature, .underlineStyle, .cmdyUnderlineStyle, .strikethroughStyle,
        ] {
            let expected = try key([name: 3])
            for value: Any in [NSNumber(value: 3), UInt8(3), CGFloat(3), NSNumber(value: 3.75)] {
                XCTAssertEqual(try key([name: value]), expected, name.rawValue)
            }
            XCTAssertNotEqual(try key([name: 0]), try key([:]), name.rawValue)
            XCTAssertEqual(try key([name: -2]), try key([name: NSNumber(value: -2)]))
        }
        let kern = try key([.kern: 1.25])
        for value: Any in [CGFloat(1.25), Float(1.25), NSNumber(value: 1.25)] {
            XCTAssertEqual(try key([.kern: value]), kern)
        }
        XCTAssertEqual(kern.kernBits, Double(1.25).bitPattern)
        XCTAssertEqual(try key([.kern: -0.0]).kernBits, Double(-0.0).bitPattern)
        XCTAssertNotEqual(try key([.kern: 0.0]), try key([.kern: -0.0]))
        XCTAssertNotEqual(try key([.kern: 0]), try key([:]))
    }

    func testMixedAttributedRunsPreserveRangesAndDistinctAliases() throws {
        let attributed = NSMutableAttributedString(string: "ABCD", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white,
        ])
        attributed.setAttributes(completeAttributes(), range: NSRange(location: 1, length: 2))
        let original = try XCTUnwrap(IndependentSharedTextSegmentKey(segment(attributed)))
        XCTAssertEqual(original.attributeRuns.map(\.location), [0, 1, 3])
        XCTAssertEqual(original.attributeRuns.map(\.length), [1, 2, 1])
        let styled = original.attributeRuns[1]
        XCTAssertEqual(styled.selectionBackground, .blue)
        XCTAssertEqual(styled.cmdySelectionBackground, .yellow)
        XCTAssertEqual(styled.underlineColor, .orange)
        XCTAssertEqual(styled.cmdyUnderlineColor, .cyan)
        XCTAssertEqual(styled.underlineStyle, 1)
        XCTAssertEqual(styled.cmdyUnderlineStyle, 3)

        // Same text and attributes over different characters change the key.
        attributed.setAttributes(completeAttributes(), range: NSRange(location: 0, length: 1))
        XCTAssertNotEqual(original, IndependentSharedTextSegmentKey(segment(attributed)))
        attributed.addAttribute(NSAttributedString.Key("cmdy.unmodeled"), value: 1,
                                range: NSRange(location: 3, length: 1))
        XCTAssertNil(IndependentSharedTextSegmentKey(segment(attributed)))
    }

    private func completeAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
            .selectionBackgroundColor: NSColor.blue,
            .cmdySelectionBackground: NSColor.yellow,
            .underlineColor: NSColor.orange,
            .cmdyUnderlineColor: NSColor.cyan,
            .strikethroughColor: NSColor.magenta,
            .ligature: 0,
            .kern: 1.25,
            .underlineStyle: 1,
            .cmdyUnderlineStyle: UInt8(3),
            .strikethroughStyle: NSNumber(value: 1),
        ]
    }

    private func key(_ attributes: [NSAttributedString.Key: Any],
                     range: NSRange = NSRange(location: 0, length: 1)) throws
        -> IndependentSharedTextAttributeRunKey {
        try XCTUnwrap(IndependentSharedTextAttributeRunKey(range: range, attributes: attributes))
    }

    private func segment(_ attributed: NSAttributedString) -> ViewLineSegment {
        ViewLineSegment(column: 0, columnWidth: 1, characterCount: 4,
                        attributedString: attributed, cellUTF16Boundaries: [0, 1, 2, 3, 4])
    }
}
