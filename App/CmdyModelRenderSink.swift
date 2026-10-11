@_spi(CmdyApp) import CmdyCore
@_spi(CmdyApp) import CmdyGPU
import CmdyNative

/// Holds only a thread-safe native publisher. No surface or AppKit value can
/// be reached from the terminal model's publication callback.
final class CmdyModelRenderSink: Sendable {
    let publisher: ModelRenderPublisher
    init(publisher: ModelRenderPublisher) { self.publisher = publisher }

    func publish(_ snapshot: CoreTerminalSnapshot, generation: UInt64) -> Bool {
        guard generation < UInt64.max else { return false }
        let grid = snapshot.grid
        var input = CmdyRenderModelInput()
        input.generation = generation + 1
        input.rows = grid.rows; input.cols = grid.cols
        input.buffer_line_count = grid.bufferLineCount; input.retained_row_origin = grid.retainedRowOrigin
        input.display_top_row = grid.displayTopRow; input.live_top_row = grid.liveTopRow
        input.cursor_row = grid.cursorRow; input.cursor_col = grid.cursorCol
        input.cursor_hidden = grid.cursorHidden ? 1 : 0; input.alternate_buffer = grid.isAlternateBuffer ? 1 : 0
        switch grid.cursorStyle {
        case .blinkBlock: input.cursor_style = 0
        case .steadyBlock: input.cursor_style = 1
        case .blinkUnderline: input.cursor_style = 2
        case .steadyUnderline: input.cursor_style = 3
        case .blinkBar: input.cursor_style = 4
        case .steadyBar: input.cursor_style = 5
        }
        input.kitty_images = snapshot.kittyImages.count; input.kitty_placements = snapshot.kittyPlacements.count
        input.kitty_next_image = snapshot.kittyNextImageId; input.kitty_next_placement = snapshot.kittyNextPlacementId
        return snapshot.withNativeRows { rows in
            snapshot.withNativeGraphics { graphics in
                input.snapshot = rows; input.graphics = graphics
                return publisher.publish(&input)
            }
        }
    }
}
