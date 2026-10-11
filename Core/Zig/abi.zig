//! One native archive backs both the Swift facade and the existing C interface.
comptime {
    _ = @import("terminal_abi.zig");
    _ = @import("terminal_operations_abi.zig");
    _ = @import("terminal_protocols_abi.zig");
    _ = @import("parser_abi.zig");
    _ = @import("ordinary_printing_abi.zig");
    _ = @import("buffer_abi.zig");
    _ = @import("image_abi.zig");
    _ = @import("blocks_abi.zig");
    _ = @import("legacy_abi.zig");
    _ = @import("render_text.zig");
    _ = @import("render_text_storage.zig");
    _ = @import("render_gpu.zig");
    _ = @import("render_cursor_cache.zig");
    _ = @import("render_worker.zig");
    _ = @import("render_session.zig");
    _ = @import("render_input.zig");
    _ = @import("render_frame_input.zig");
    _ = @import("render_schedule_abi.zig");
    _ = @import("render_shaper.zig");
    _ = @import("render_image_bridge.zig");
    _ = @import("render_contract.zig");
    _ = @import("render_trace.zig");
}
