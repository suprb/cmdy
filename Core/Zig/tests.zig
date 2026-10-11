//! All native engine and ABI regressions, including actual storage ownership.
comptime {
    _ = @import("render_coverage_storage.zig");
    _ = @import("render_delivery_policy.zig");
    _ = @import("abi.zig");
    _ = @import("parser_tests.zig");
    _ = @import("buffer_tests.zig");
    _ = @import("protocols_tests.zig");
    _ = @import("cluster_append_tests.zig");
    _ = @import("cell_text_tests.zig");
    _ = @import("ascii_batch_tests.zig");
    _ = @import("render_session_deadlines.zig");
    _ = @import("render_text_cache_tests.zig");
}
