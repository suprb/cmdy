//! Constant-size capture; only the renderer owner traverses the frozen rows.
const std = @import("std");
const input = @import("render_input.zig");
const Snapshot = @import("buffer_snapshot.zig").Snapshot;
const geometry = @import("render_geometry.zig");
const Line = @import("line.zig").Line;
pub const c = @cImport(@cInclude("cmdy_render_frame_input.h"));
pub const Error = error{ InvalidInput, OutOfMemory };

pub const Viewport = struct {
    allocator: std.mem.Allocator,
    snapshot: *Snapshot,
    style: *input.FrozenStyle,
    raster: *input.FrozenParameters,
    name: [:0]u8,
    settings: c.CmdyRenderViewportInput,
    visible: geometry.VisibleRows,

    pub fn capture(a: std.mem.Allocator, frame: *const c.CmdyRenderFrameInput, source: *const c.CmdyRenderViewportInput) Error!*Viewport {
        const snapshot: *Snapshot = @ptrCast(@alignCast(source.snapshot orelse return error.InvalidInput));
        const style: *input.FrozenStyle = @ptrCast(@alignCast(source.style orelse return error.InvalidInput));
        const raster: *input.FrozenParameters = @ptrCast(@alignCast(source.raster orelse return error.InvalidInput));
        if (source.has_selection > 1 or source.fringe_rows < 0 or frame.alternate_buffer > 1 or
            source.key.cols != frame.parameters.grid_cols or source.key.alternate_buffer != frame.alternate_buffer or
            source.key.cols != raster.input.cols or source.key.width != raster.input.width or source.key.height != raster.input.height or
            source.font_name_bytes > std.math.maxInt(isize) or
            (source.font_name_bytes != 0 and source.key.font_name == null)) return error.InvalidInput;
        if (source.has_selection != 0 and (source.selection_start_row > source.selection_end_row or
            (source.selection_start_row == source.selection_end_row and source.selection_start_col > source.selection_end_col))) return error.InvalidInput;
        const visible = geometry.VisibleRows.init(frame.parameters.grid_rows, frame.buffer_line_count, frame.parameters.display_top_row, frame.retained_row_origin, source.fringe_rows);
        if (visible.count() != 0 and (visible.first < snapshot.first or
            @as(i128, visible.end) > @as(i128, snapshot.first) + snapshot.lines.len)) return error.InvalidInput;
        const name = try a.dupeZ(u8, if (source.font_name_bytes == 0) "" else source.key.font_name[0..source.font_name_bytes]);
        errdefer a.free(name);
        const self = try a.create(Viewport);
        self.* = .{ .allocator = a, .snapshot = snapshot.retain(), .style = style.retain(), .raster = raster.retain(), .name = name, .settings = source.*, .visible = visible };
        self.settings.key.font_name = name;
        return self;
    }
    pub fn destroy(self: *Viewport) void {
        const a = self.allocator;
        const snapshot = self.snapshot;
        const style = self.style;
        const raster = self.raster;
        a.free(self.name);
        a.destroy(self);
        snapshot.release();
        style.release();
        raster.release();
    }
    pub fn line(self: *const Viewport, source_row: isize) *const Line {
        return self.snapshot.line(@intCast(source_row - self.snapshot.first)).?;
    }
    pub fn key(self: *const Viewport, row: geometry.VisibleRow) c.CmdyGpuRowKey {
        const source = self.line(row.source_row);
        var result = self.settings.key;
        result.absolute_row = row.cache_row;
        result.version = source.version();
        result.line_mode = @intFromEnum(source.render_mode);
        return result;
    }
    pub fn placement(self: *const Viewport, row: geometry.VisibleRow) c.CmdyGpuFrameRow {
        var result = std.mem.zeroes(c.CmdyGpuFrameRow);
        result.display_index = row.display_index;
        result.source_row = row.source_row;
        result.line_mode = @intFromEnum(self.line(row.source_row).render_mode);
        const s = self.settings;
        if (s.has_selection != 0 and s.key.cols > 0 and row.source_row >= s.selection_start_row and row.source_row <= s.selection_end_row) {
            result.has_selection = 1;
            result.selection_lower = if (row.source_row == s.selection_start_row) std.math.clamp(s.selection_start_col, 0, s.key.cols - 1) else 0;
            result.selection_upper = if (row.source_row == s.selection_end_row) std.math.clamp(s.selection_end_col, 0, s.key.cols - 1) else s.key.cols - 1;
        }
        return result;
    }
};
