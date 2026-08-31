import Foundation

/// A command block: one prompt → command → output → exit cycle, tracked
/// from OSC 133 markers. Rows are ABSOLUTE buffer rows; they are rebased
/// when scrollback trims and remapped through reflow BY CONSTRUCTION —
/// the tracker participates in the engine's row lifecycle, it doesn't
/// watch from outside.
public final class TerminalBlock {
    public let index: Int
    public internal(set) var promptRow: Int
    /// Where the user's input starts (OSC 133;B) — ghost-text anchor.
    public internal(set) var inputStart: (row: Int, col: Int)?
    public internal(set) var commandRow: Int
    public internal(set) var endRow: Int?
    public internal(set) var exitCode: Int?
    public internal(set) var running = false
    /// Injected timestamps (delegate clock) — replay-deterministic.
    public internal(set) var startedAt: Double
    public internal(set) var finishedAt: Double?

    init(index: Int, promptRow: Int, timestamp: Double) {
        self.index = index
        self.promptRow = promptRow
        self.commandRow = promptRow
        self.startedAt = timestamp
    }
}

/// The engine-native block store.
public final class BlockTracker {
    public private(set) var blocks: [TerminalBlock] = []
    private var nextIndex = 1

    /// Fired on every state change (host refreshes chrome).
    public var onChange: (() -> Void)?
    /// Fired when a command finishes (host notifications).
    public var onCommandFinished: ((TerminalBlock) -> Void)?

    public var promptRows: [Int] { blocks.map(\.promptRow) }
    public var isRunning: Bool { blocks.last?.running ?? false }
    public var lastCompletedBlock: TerminalBlock? {
        blocks.last { !$0.running && $0.endRow != nil }
    }

    func promptStarted(row: Int, timestamp: Double) {
        let block = TerminalBlock(index: nextIndex, promptRow: row, timestamp: timestamp)
        nextIndex += 1
        blocks.append(block)
        onChange?()
    }

    func promptEnded(row: Int, col: Int) {
        blocks.last?.inputStart = (row, col)
        onChange?()
    }

    func commandStarted(row: Int) {
        guard let block = blocks.last else { return }
        block.commandRow = row
        block.running = true
        onChange?()
    }

    @discardableResult
    func commandFinished(row: Int, exitCode: Int?, timestamp: Double) -> TerminalBlock? {
        // zsh runs `precmd` after a blank Return too, which emits OSC 133 D
        // without a matching C. That marker closes no command and must not be
        // applied to the previous failure or to an empty prompt block.
        guard let block = blocks.last(where: { $0.running }) else { return nil }
        block.endRow = row
        block.exitCode = exitCode
        block.running = false
        block.finishedAt = timestamp
        onChange?()
        onCommandFinished?(block)
        return block
    }

    /// Scrollback trimmed `dropped` rows off the top: shift every anchor.
    func rebase(droppedLines dropped: Int) {
        guard dropped > 0 else { return }
        var survivors: [TerminalBlock] = []
        for block in blocks {
            block.promptRow -= dropped
            block.commandRow -= dropped
            if let e = block.endRow { block.endRow = e - dropped }
            if let s = block.inputStart { block.inputStart = (s.row - dropped, s.col) }
            if block.promptRow >= 0 { survivors.append(block) }
        }
        if survivors.count != blocks.count { blocks = survivors }
        onChange?()
    }

    /// Reflow rewrapped the buffer: remap every anchor through the row map.
    /// Rows mapping to negative are trimmed away and their blocks dropped.
    func remapRows(_ map: (Int) -> Int) {
        var survivors: [TerminalBlock] = []
        for block in blocks {
            block.promptRow = map(block.promptRow)
            block.commandRow = map(block.commandRow)
            if let e = block.endRow { block.endRow = map(e) }
            if let s = block.inputStart { block.inputStart = (map(s.row), s.col) }
            if block.promptRow >= 0 { survivors.append(block) }
        }
        blocks = survivors
        onChange?()
    }

    /// The screen (and its history) was cleared: anchors are meaningless.
    func handleScrollbackCleared() {
        reset()
    }

    public func reset() {
        blocks.removeAll()
        onChange?()
    }
}
