//! Terminal-owned content, combined with frozen UI state on the render owner.
const std = @import("std");
const frames = @import("render_frame_input.zig");
const geometry = @import("render_geometry.zig");
const Snapshot = @import("buffer_snapshot.zig").Snapshot;
pub const c = @cImport(@cInclude("cmdy_render_session.h"));
pub const Model = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    snapshot: *Snapshot,
    graphics: ?*frames.Graphics,
    view: c.CmdyRenderModelInput,
    pub fn create(a: std.mem.Allocator, source: *const c.CmdyRenderModelInput) frames.CaptureError!*Model {
        const snapshot: *Snapshot = @ptrCast(@alignCast(source.snapshot orelse return error.InvalidInput));
        if (source.generation == 0 or source.rows <= 0 or source.cols <= 0 or source.buffer_line_count < 0 or
            source.cursor_style > 5 or source.cursor_hidden > 1 or source.alternate_buffer > 1) return error.InvalidInput;
        const visible = geometry.VisibleRows.init(source.rows, source.buffer_line_count, source.display_top_row, source.retained_row_origin, 0);
        if (visible.count() != 0 and (visible.first < snapshot.first or @as(i128, visible.end) > @as(i128, snapshot.first) + snapshot.lines.len)) return error.InvalidInput;
        const self = try a.create(Model);
        const graphics: ?*frames.Graphics = @ptrCast(@alignCast(source.graphics));
        self.* = .{ .allocator = a, .snapshot = snapshot.retain(), .graphics = if (graphics) |g| g.retain() else null, .view = source.* };
        return self;
    }
    pub fn retain(self: *Model) *Model {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
        return self;
    }
    pub fn release(self: *Model) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const snapshot = self.snapshot;
        const graphics = self.graphics;
        const a = self.allocator;
        a.destroy(self);
        snapshot.release();
        if (graphics) |g| g.release();
    }
    pub fn apply(self: *const Model, a: std.mem.Allocator, template: *const frames.Frame) frames.CaptureError!*frames.Frame {
        const viewport = template.viewportInput() orelse return error.InvalidInput;
        var metadata = template.metadata;
        const model = self.view;
        if (metadata.parameters.grid_rows != model.rows or metadata.parameters.grid_cols != model.cols) return error.InvalidInput;
        var settings = viewport.settings;
        const delta = @as(i128, model.retained_row_origin) - metadata.retained_row_origin;
        settings.style_row_offset = std.math.cast(isize, @as(i128, settings.style_row_offset) + delta) orelse return error.InvalidInput;
        settings.selection_start_row = @intCast(std.math.clamp(@as(i128, settings.selection_start_row) - delta, std.math.minInt(isize), std.math.maxInt(isize)));
        settings.selection_end_row = @intCast(std.math.clamp(@as(i128, settings.selection_end_row) - delta, std.math.minInt(isize), std.math.maxInt(isize)));
        settings.snapshot = @ptrCast(self.snapshot);
        settings.model_generation = model.generation;
        settings.key.alternate_buffer = model.alternate_buffer;
        settings.key.kitty_images = model.kitty_images;
        settings.key.kitty_placements = model.kitty_placements;
        settings.key.kitty_next_image = model.kitty_next_image;
        settings.key.kitty_next_placement = model.kitty_next_placement;
        metadata.buffer_line_count = model.buffer_line_count;
        metadata.retained_row_origin = model.retained_row_origin;
        metadata.live_top_row = model.live_top_row;
        metadata.alternate_buffer = model.alternate_buffer;
        metadata.parameters.display_top_row = model.display_top_row;
        metadata.parameters.cursor_source_row = model.cursor_row;
        metadata.parameters.cursor_col = model.cursor_col;
        metadata.parameters.cursor_hidden = model.cursor_hidden;
        metadata.parameters.cursor_style = model.cursor_style;
        const display = geometry.displayRow(model.cursor_row, model.display_top_row, model.rows);
        metadata.parameters.cursor_valid = @intFromBool(display != null);
        metadata.parameters.cursor_display_row = display orelse 0;
        return frames.Frame.createViewport(a, &metadata, @ptrCast(&settings), self.graphics);
    }
};
