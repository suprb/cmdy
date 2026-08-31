import XCTest
@testable import CmdyKit

final class WindowGridLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let gap: CGFloat = 10

    func testRequestedOneThroughFourWindowSequence() throws {
        var tree: WindowGridNode?

        tree = insert("a", into: tree)
        XCTAssertEqual(
            WindowGridLayout.frames(for: tree, in: screen, gap: gap, scale: 2)["a"],
            screen)

        tree = insert("b", into: tree)
        var frames = WindowGridLayout.frames(
            for: tree, in: screen, gap: gap, scale: 2)
        assertFrame(frames["a"], x: 0, y: 0, width: 595, height: 800)
        assertFrame(frames["b"], x: 605, y: 0, width: 595, height: 800)

        tree = insert("c", into: tree)
        frames = WindowGridLayout.frames(
            for: tree, in: screen, gap: gap, scale: 2)
        assertFrame(frames["a"], x: 0, y: 0, width: 595, height: 800)
        assertFrame(frames["b"], x: 605, y: 405, width: 595, height: 395)
        assertFrame(frames["c"], x: 605, y: 0, width: 595, height: 395)

        tree = insert("d", into: tree)
        frames = WindowGridLayout.frames(
            for: tree, in: screen, gap: gap, scale: 2)
        assertFrame(frames["a"], x: 0, y: 405, width: 595, height: 395)
        assertFrame(frames["d"], x: 0, y: 0, width: 595, height: 395)
        assertFrame(frames["b"], x: 605, y: 405, width: 595, height: 395)
        assertFrame(frames["c"], x: 605, y: 0, width: 595, height: 395)
    }

    func testMovingReordersLeavesWithoutChangingTopology() {
        var tree: WindowGridNode?
        for id in ["a", "b", "c", "d"] { tree = insert(id, into: tree) }
        let original = try! XCTUnwrap(tree)
        let moved = WindowGridLayout.moving("c", to: "a", in: original)

        XCTAssertEqual(WindowGridLayout.leafIDs(in: original), ["a", "d", "b", "c"])
        XCTAssertEqual(WindowGridLayout.leafIDs(in: moved), ["c", "a", "d", "b"])
        XCTAssertEqual(
            WindowGridLayout.frames(for: original, in: screen, gap: gap, scale: 2)
                .values.sorted(by: frameOrder),
            WindowGridLayout.frames(for: moved, in: screen, gap: gap, scale: 2)
                .values.sorted(by: frameOrder))
    }

    func testMovingAcrossFiveWindowNestedTopologyUsesEveryExactSlot() throws {
        var tree: WindowGridNode?
        for id in ["a", "b", "c", "d", "e"] {
            tree = insert(id, into: tree)
        }
        let original = try XCTUnwrap(tree)
        let ids = WindowGridLayout.leafIDs(in: original)
        let originalFrames = WindowGridLayout.frames(
            for: original, in: screen, gap: gap, scale: 2)

        for source in ids {
            for target in ids where target != source {
                let moved = WindowGridLayout.moving(
                    source, to: target, in: original)
                let movedFrames = WindowGridLayout.frames(
                    for: moved, in: screen, gap: gap, scale: 2)
                XCTAssertEqual(
                    movedFrames[source], originalFrames[target],
                    "\(source) should occupy \(target)'s nested slot")
                XCTAssertEqual(Set(WindowGridLayout.leafIDs(in: moved)), Set(ids))
                XCTAssertEqual(
                    movedFrames.values.sorted(by: frameOrder),
                    originalFrames.values.sorted(by: frameOrder))
            }
        }
    }

    func testRemovingCollapsesTheEmptyBranch() throws {
        let two = insert("b", into: insert("a", into: nil))
        let remaining = WindowGridLayout.removing("a", from: two)
        XCTAssertEqual(remaining, .leaf("b"))
        XCTAssertNil(WindowGridLayout.removing("b", from: remaining))
    }

    func testInsertionRefusesAWindowThatCannotMeetMinimumSize() {
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertNil(WindowGridLayout.inserting(
            "b", into: .leaf("a"), in: small, gap: gap, scale: 2,
            minimumSizes: [
                "a": CGSize(width: 320, height: 220),
                "b": CGSize(width: 320, height: 220),
            ]))
    }

    func testDefaultMinimumAllowsVeryCompactTiles() throws {
        let compactScreen = CGRect(x: 0, y: 0, width: 250, height: 160)
        let tree = try XCTUnwrap(WindowGridLayout.inserting(
            "b", into: .leaf("a"), in: compactScreen,
            gap: gap, scale: 2))
        let frames = WindowGridLayout.frames(
            for: tree, in: compactScreen, gap: gap, scale: 2)
        let a = try XCTUnwrap(frames["a"])
        let b = try XCTUnwrap(frames["b"])
        XCTAssertEqual(a.width, 120, accuracy: 0.001)
        XCTAssertEqual(b.width, 120, accuracy: 0.001)
        XCTAssertEqual(a.height, 160, accuracy: 0.001)
        XCTAssertEqual(b.height, 160, accuracy: 0.001)
    }

    func testResizeBoundaryUpdatesBothNeighborsAndKeepsGap() throws {
        let tree = try XCTUnwrap(insert("b", into: insert("a", into: nil)))
        let boundary = try XCTUnwrap(WindowGridLayout.resizeBoundaries(
            for: "a", in: tree, frame: screen, gap: gap, scale: 2).first)
        XCTAssertEqual(boundary.edge, .right)

        let dragged = CGRect(x: 0, y: 0, width: 700, height: 800)
        let ratio = WindowGridLayout.ratio(for: dragged, boundary: boundary)
        let resized = WindowGridLayout.settingRatio(
            ratio, at: boundary.splitPath, in: tree)
        let frames = WindowGridLayout.frames(
            for: resized, in: screen, gap: gap, scale: 2)
        let first = try XCTUnwrap(frames["a"])
        let second = try XCTUnwrap(frames["b"])

        XCTAssertEqual(first.width, 700, accuracy: 0.5)
        XCTAssertEqual(second.minX - first.maxX, gap, accuracy: 0.001)
        XCTAssertEqual(second.maxX, screen.maxX, accuracy: 0.001)
    }

    func testGapIsRoundedToADevicePixel() {
        XCTAssertEqual(WindowGridLayout.resolvedGap(7.3, scale: 2), 7.5)
        XCTAssertEqual(WindowGridLayout.resolvedGap(7.3, scale: 1), 7)
    }

    func testStoredStateRoundTripsAndRejectsCorruptRatio() throws {
        let state = WindowGridStoredState(
            trees: ["display": .split(
                axis: .vertical, ratio: 0.5,
                first: .leaf("a"), second: .leaf("b"))],
            manualFrames: ["a": WindowGridStoredFrame(screen)])
        XCTAssertEqual(
            try JSONDecoder().decode(
                WindowGridStoredState.self,
                from: JSONEncoder().encode(state)),
            state)

        let corrupt = #"{"type":"split","axis":"vertical","ratio":2,"first":{"type":"leaf","id":"a"},"second":{"type":"leaf","id":"b"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            WindowGridNode.self, from: Data(corrupt.utf8)))
    }

    private func insert(
        _ id: String,
        into tree: WindowGridNode?
    ) -> WindowGridNode? {
        WindowGridLayout.inserting(
            id, into: tree, in: screen, gap: gap, scale: 2)
    }

    private func assertFrame(
        _ frame: CGRect?,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let frame else {
            XCTFail("Missing frame", file: file, line: line)
            return
        }
        XCTAssertEqual(frame.minX, x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(frame.minY, y, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(frame.width, width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(frame.height, height, accuracy: 0.001, file: file, line: line)
    }

    private func frameOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        return lhs.minY < rhs.minY
    }
}
