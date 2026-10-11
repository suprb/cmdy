//! Exercise the real C entry points as well as generic ownership tests.
test {
    _ = @import("render_delivery_policy.zig");
    _ = @import("render_input.zig");
    _ = @import("render_frame_input.zig");
    _ = @import("render_viewport_tests.zig");
    _ = @import("render_worker.zig");
}
