import Foundation

/// One command "block" — the semantic unit behind the blocks/AI vision. Built
/// from OSC 133 shell-integration markers (A=prompt, B=input, C=exec, D=done).
public struct Block {
    /// Stable for this pane session and independent of scrollback row reflow.
    public let id: String
    public let index: Int
    public var cwd: String?
    public var exitCode: Int32?
    public let startedAt: Date
    public var finishedAt: Date?
    public var commandRow: Int       // absolute row where the command executes (OSC 133;C)
    public var endRow: Int?          // absolute row when it finished (OSC 133;D)
    public var promptRow: Int        // absolute row of this block's prompt (scroll target)
    public var commandText: String   // the typed command (prompt stripped)
    public var running: Bool { finishedAt == nil }
}

/// Records command boundaries reported by the shell. This is the substrate the
/// later pillars (block UI, AI context, collab) build on; v1 surfaces it as a
/// live status indicator in the window subtitle.
public final class BlockStore {
    public init() {}

    public private(set) var blocks: [Block] = []
    /// Absolute scrollback rows where each prompt began (OSC 133;A) — used for
    /// jump-to-prompt navigation.
    public private(set) var promptRows: [Int] = []
    public var onChange: (() -> Void)?
    private var nextIndex = 1

    /// Forget all blocks/prompts (after a screen+scrollback clear, the absolute
    /// row coordinates are no longer valid).
    public func reset() {
        blocks.removeAll()
        promptRows.removeAll()
        onChange?()
    }

    /// OSC 133;A — a new prompt began at the given absolute scrollback row.
    public func promptStarted(row: Int) {
        if promptRows.last != row {
            promptRows.append(row)
            if promptRows.count > Self.maxBlocks {
                promptRows.removeFirst(promptRows.count - Self.maxBlocks)
            }
            onChange?()
        }
    }

    /// Retention cap — beyond this the oldest blocks are dropped (the overlay
    /// iterates blocks every repaint; unbounded growth is both RAM and CPU).
    public static let maxBlocks = 400

    /// OSC 133;C — a command started executing at the given absolute row.
    public func commandStarted(row: Int, promptRow: Int, command: String, cwd: String?) {
        let b = Block(id: UUID().uuidString, index: nextIndex,
                      cwd: cwd, exitCode: nil, startedAt: Date(),
                      finishedAt: nil, commandRow: row, endRow: nil,
                      promptRow: promptRow, commandText: command)
        nextIndex += 1
        blocks.append(b)
        if blocks.count > Self.maxBlocks { blocks.removeFirst(blocks.count - Self.maxBlocks) }
        if promptRows.count > Self.maxBlocks { promptRows.removeFirst(promptRows.count - Self.maxBlocks) }
        onChange?()
    }

    /// Scrollback trimmed `delta` lines off the top: every stored absolute row
    /// shifts down, and blocks that scrolled out of retention are dropped.
    public func rebase(droppedLines delta: Int) {
        guard delta > 0 else { return }
        blocks = blocks.compactMap { b in
            var b = b
            b.promptRow -= delta
            b.commandRow -= delta
            b.endRow = b.endRow.map { $0 - delta }
            return b.promptRow < 0 ? nil : b
        }
        promptRows = promptRows.compactMap { r in r - delta >= 0 ? r - delta : nil }
        onChange?()
    }

    /// Reflow support: rewrite every stored absolute row in one shot (the
    /// buffer rewrapped — font zoom or pane resize — so all rows moved).
    /// A transform result < 0 means the row was trimmed away — drop the block.
    public func remapRows(_ transform: (Int) -> Int) {
        blocks = blocks.compactMap { b in
            var b = b
            b.promptRow = transform(b.promptRow)
            b.commandRow = transform(b.commandRow)
            b.endRow = b.endRow.map { max(0, transform($0)) }
            return b.promptRow < 0 ? nil : b
        }
        promptRows = promptRows.compactMap { r in
            let t = transform(r)
            return t < 0 ? nil : t
        }
        onChange?()
    }

    /// OSC 133;D;<exit> — the running command finished at the given absolute row.
    @discardableResult
    public func commandFinished(row: Int, exitCode: Int32?) -> Bool {
        guard let i = blocks.indices.last, blocks[i].running else { return false }
        blocks[i].finishedAt = Date()
        blocks[i].exitCode = exitCode
        blocks[i].endRow = row
        onChange?()
        return true
    }

    public var commandCount: Int { blocks.count }
    public var isRunning: Bool { blocks.last?.running ?? false }
    public var lastExit: Int32? { blocks.last(where: { !$0.running })?.exitCode }
    public var lastCompletedBlock: Block? { blocks.last(where: { !$0.running }) }

    /// Parse a raw OSC 133 payload (the text after "133;"), returning the kind
    /// and, for D, the exit code. Kept pure so it is unit-testable headlessly.
    public static func parse(_ payload: String) -> (kind: Character, exit: Int32?)? {
        guard let kind = payload.first else { return nil }
        if kind == "D" {
            // Forms: "D", "D;0", "D;0;..." — take the first numeric field.
            let fields = payload.dropFirst().split(separator: ";")
            let exit = fields.first.flatMap { Int32($0) }
            return ("D", exit)
        }
        return (kind, nil)
    }
}
