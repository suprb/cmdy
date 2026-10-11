//! Terminal block and box geometry. CoreGraphics supplies drawing primitives only.
const std = @import("std");
const font = @import("render_font.zig");
const c = font.c;
const a = font.a;
const Span = c.CmdyRenderSpan;
fn fl(v: isize) f64 {
    return @floatFromInt(v);
}
fn range(lo: isize, hi: isize) Span {
    return .{ .lower = lo, .upper = hi };
}
fn length(r: Span) isize {
    return r.upper - r.lower;
}
pub fn centeredBand(len: isize, thickness: isize, upper: bool) Span {
    const t = @min(@max(1, thickness), @max(1, len));
    const lower = @max(0, @divTrunc(len - t + @as(isize, @intFromBool(upper)), 2));
    return range(lower, @min(len, lower + t));
}
const Canvas = struct {
    context: c.CGContextRef,
    x: f64,
    y: f64,
    width: isize,
    height: isize,
    minimum: isize,
    fn box(self: Canvas, x: isize, y: isize, w: isize, h: isize) void {
        if (w <= 0 or h <= 0) return;
        const x0 = @min(self.width, @max(0, x));
        const y0 = @min(self.height, @max(0, y));
        const x1 = @min(self.width, @max(x0, x + w));
        const y1 = @min(self.height, @max(y0, y + h));
        if (x1 > x0 and y1 > y0) c.CGContextFillRect(self.context, font.rect(self.x + fl(x0), self.y + fl(y0), fl(x1 - x0), fl(y1 - y0)));
    }
    fn fill(self: Canvas, x: Span, y: Span) void {
        self.box(x.lower, y.lower, length(x), length(y));
    }
    fn horizontal(self: Canvas, y: Span, x0: isize, x1: isize) void {
        self.fill(range(@max(0, x0), @min(self.width, x1)), y);
    }
    fn vertical(self: Canvas, x: Span, y0: isize, y1: isize) void {
        self.fill(x, range(@max(0, y0), @min(self.height, y1)));
    }
    fn line(self: Canvas, x0: f64, y0: f64, x1: f64, y1: f64, thickness: isize) void {
        c.CGContextSetLineWidth(self.context, fl(@max(self.minimum, thickness)));
        c.CGContextSetLineCap(self.context, c.kCGLineCapButt);
        const sx = @round(x0);
        const sy = @round(y0);
        const ex = @round(x1);
        const ey = @round(y1);
        const dx = std.math.sign(ex - sx);
        const dy = std.math.sign(ey - sy);
        const xe = @min(1, fl(self.width) / fl(self.height)) / 2;
        const ye = @min(1, fl(self.height) / fl(self.width)) / 2;
        c.CGContextMoveToPoint(self.context, sx - dx * xe, sy - dy * ye);
        c.CGContextAddLineToPoint(self.context, ex + dx * xe, ey + dy * ye);
        c.CGContextStrokePath(self.context);
    }
    fn orthogonal(self: Canvas, arms: [4]u8) void {
        const cx = centeredBand(self.width, self.minimum, false);
        const cy = centeredBand(self.height, self.minimum, false);
        var sizes: [4]isize = undefined;
        for (arms, 0..) |side, i| sizes[i] = if (side == 0) 0 else self.minimum * (if (side == 2) @as(isize, 2) else @as(isize, 1));
        for (sizes, 0..) |t, i| {
            if (t <= 0) continue;
            if (i == 0 or i == 2) {
                const band = centeredBand(self.width, t, false);
                if (i == 0) self.box(band.lower, 0, length(band), cy.upper) else self.box(band.lower, cy.lower, length(band), self.height - cy.lower);
            } else {
                const band = centeredBand(self.height, t, false);
                if (i == 3) self.box(0, band.lower, cx.upper, length(band)) else self.box(cx.lower, band.lower, self.width - cx.lower, length(band));
            }
        }
        const vt = @max(sizes[0], sizes[2]);
        const ht = @max(sizes[1], sizes[3]);
        if (vt > 0 and ht > 0) self.fill(centeredBand(self.width, vt, false), centeredBand(self.height, ht, false));
    }
};
pub fn diagonalThickness(base: isize) isize {
    return @max(1, base + @max(0, @divTrunc(base, 2)));
}
pub fn arcAxis(len: isize, thickness: isize) f64 {
    return fl(len) / 2 - (if (@mod(thickness, 2) == 0) @as(f64, 0) else @as(f64, 0.5));
}
fn arc(cp: u32, canvas: Canvas, thickness: isize) void {
    const right = cp == 0x256d or cp == 0x2570;
    const down = cp == 0x256d or cp == 0x256e;
    const stroke = @max(1, thickness);
    const minimum = fl(@min(canvas.width, canvas.height));
    const half = fl(stroke) / 2;
    const radius = @min(minimum * 0.30, @max(0, minimum / 2 - half));
    if (radius <= 0) return;
    const cx = arcAxis(canvas.width, stroke);
    const cy = arcAxis(canvas.height, stroke);
    const bx = @max(0, @divTrunc(canvas.width - stroke, 2));
    const by = @max(0, @divTrunc(canvas.height - stroke, 2));
    const xl = @max(0, @min(canvas.width, @as(isize, @intFromFloat(@ceil(cx - radius)))));
    const xh = @max(0, @min(canvas.width, @as(isize, @intFromFloat(@floor(cx + radius)))));
    const yl = @max(0, @min(canvas.height, @as(isize, @intFromFloat(@ceil(cy - radius)))));
    const yh = @max(0, @min(canvas.height, @as(isize, @intFromFloat(@floor(cy + radius)))));
    if (!down) canvas.box(bx, 0, stroke, yl);
    if (down) canvas.box(bx, yh, stroke, canvas.height - yh);
    if (!right) canvas.box(0, by, xl, stroke);
    if (right) canvas.box(xh, by, canvas.width - xh, stroke);
    const circle_x = cx + (if (right) radius else -radius);
    const circle_y = cy + (if (down) radius else -radius);
    const outer = radius + half;
    const inner = @max(0, radius - half);
    c.CGContextSaveGState(canvas.context);
    defer c.CGContextRestoreGState(canvas.context);
    c.CGContextSetAllowsAntialiasing(canvas.context, true);
    c.CGContextSetShouldAntialias(canvas.context, true);
    c.CGContextClipToRect(canvas.context, font.rect(if (right) canvas.x else canvas.x + circle_x, if (down) canvas.y else canvas.y + circle_y, if (right) circle_x else fl(canvas.width) - circle_x, if (down) circle_y else fl(canvas.height) - circle_y));
    const path = c.CGPathCreateMutable() orelse return;
    defer c.CGPathRelease(path);
    c.CGPathAddEllipseInRect(path, null, font.rect(canvas.x + circle_x - outer, canvas.y + circle_y - outer, outer * 2, outer * 2));
    if (inner > 0) c.CGPathAddEllipseInRect(path, null, font.rect(canvas.x + circle_x - inner, canvas.y + circle_y - inner, inner * 2, inner * 2));
    c.CGContextAddPath(canvas.context, path);
    c.CGContextDrawPath(canvas.context, if (inner > 0) c.kCGPathEOFill else c.kCGPathFill);
}
pub fn dashSpans(len: isize, count: isize, horizontal: bool, heavy: bool, minimum: isize, out: *std.ArrayList(Span)) !void {
    if (len <= 0 or count <= 0) return;
    const thickness = @max(1, minimum);
    if (thickness == 2) {
        const stroke = if (heavy) thickness * 2 else thickness;
        const gap = @max(2, thickness * 2);
        if (count == 2) {
            if (horizontal) {
                const lead = @max(0, @divTrunc(stroke, 2));
                const segment = @max(1, @divTrunc(len - stroke - lead * 2, 2));
                try out.append(a, range(lead, lead + segment));
                try out.append(a, range(len - lead - segment, len - lead));
            } else {
                const segment = @max(1, @divTrunc(len - gap * 2, 2));
                try out.append(a, range(0, segment));
                try out.append(a, range(segment + gap, segment * 2 + gap));
            }
            return;
        }
        const leading = if (horizontal) @max(1, @divTrunc(gap, 2)) else 0;
        const trailing = if (horizontal) leading else gap;
        const available = @max(count, len - leading - trailing - gap * (count - 1));
        const base = @divTrunc(available, count);
        const remainder = @rem(available, count);
        var cursor: isize = leading;
        var i: isize = 0;
        while (i < count) : (i += 1) {
            const segment = base + @as(isize, @intFromBool(i < remainder));
            try out.append(a, range(cursor, cursor + segment));
            cursor += segment + gap;
        }
        return;
    }
    const unit = @max(1, @divTrunc(thickness + 1, 2));
    var leading: isize = undefined;
    var gap: isize = undefined;
    var trailing: isize = undefined;
    if (horizontal) {
        if (count == 2 and heavy) {
            leading = thickness;
            gap = thickness * 2;
            trailing = thickness;
        } else if (count == 3) {
            leading = unit;
            gap = unit * 2;
            trailing = unit;
        } else {
            leading = @max(0, unit - 1);
            gap = @max(1, unit * 2 - 1);
            trailing = unit;
        }
    } else {
        leading = 0;
        gap = if (count == 2) thickness * 2 else if (count == 3) 4 else unit + 2;
        trailing = gap;
    }
    const available = @max(count, len - leading - trailing - gap * (count - 1));
    const base = @max(1, @divTrunc(available, count));
    const remainder = @max(0, @rem(available, count));
    var cursor: isize = @min(len, leading);
    var i: isize = 0;
    while (i < count and cursor < len) : (i += 1) {
        const segment = base + @as(isize, @intFromBool(i < remainder));
        const upper = @min(len, cursor + segment);
        if (upper > cursor) try out.append(a, range(cursor, upper));
        cursor = upper + gap;
    }
}
fn dashed(cp: u32, canvas: Canvas) void {
    const count: isize = if (cp >= 0x2508 and cp <= 0x250b) 4 else if (cp >= 0x2504 and cp <= 0x2507) 3 else 2;
    const heavy = @mod(cp, 2) == 1;
    const horizontal = cp == 0x2504 or cp == 0x2505 or cp == 0x2508 or cp == 0x2509 or cp == 0x254c or cp == 0x254d;
    const thickness = canvas.minimum * (if (heavy) @as(isize, 2) else @as(isize, 1));
    const cross = centeredBand(if (horizontal) canvas.height else canvas.width, thickness, false);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(a);
    dashSpans(if (horizontal) canvas.width else canvas.height, count, horizontal, heavy, canvas.minimum, &spans) catch return;
    for (spans.items) |span| {
        if (horizontal) canvas.fill(span, cross) else canvas.fill(cross, span);
    }
}
pub fn draw(cp: u32, context: c.CGContextRef, x: f64, y: f64, width: f64, height: f64, scale: f64, color: font.Object, thickness: isize) void {
    if (cp < 0x2500 or cp > 0x257f or width <= 0 or height <= 0 or !std.math.isFinite(scale) or scale <= 0) return;
    const wd = @round(width * scale);
    const hd = @round(height * scale);
    if (!std.math.isFinite(wd) or !std.math.isFinite(hd) or wd > 2147483647 or hd > 2147483647) return;
    const canvas = Canvas{ .context = context, .x = x, .y = y, .width = @max(1, @as(isize, @intFromFloat(wd))), .height = @max(1, @as(isize, @intFromFloat(hd))), .minimum = @max(1, thickness) };
    c.CGContextSaveGState(context);
    defer c.CGContextRestoreGState(context);
    const cg = c.cmdy_platform_text_color_cg(color);
    c.CGContextSetStrokeColorWithColor(context, cg);
    c.CGContextSetFillColorWithColor(context, cg);
    if (cp >= 0x2571 and cp <= 0x2573) {
        const t = diagonalThickness(thickness);
        if (cp == 0x2571 or cp == 0x2573) canvas.line(x + fl(canvas.width), y, x, y + fl(canvas.height), t);
        if (cp == 0x2572 or cp == 0x2573) canvas.line(x, y, x + fl(canvas.width), y + fl(canvas.height), t);
    } else if (cp >= 0x256d and cp <= 0x2570) arc(cp, canvas, thickness) else if ((cp >= 0x2504 and cp <= 0x250b) or (cp >= 0x254c and cp <= 0x254f)) dashed(cp, canvas) else if (cp >= 0x2550 and cp <= 0x256c) singleDouble(cp, canvas) else canvas.orthogonal(sides[cp - 0x2500]);
}
pub fn blockRects(cp: u32, out: *[3]c.CmdyRenderBlockRect) usize {
    if (cp < 0x2580 or cp > 0x259f) return 0;
    const r = struct {
        fn make(x0: u8, x1: u8, y0: u8, y1: u8, alpha: f64) c.CmdyRenderBlockRect {
            return .{ .x0 = x0, .x1 = x1, .y0 = y0, .y1 = y1, .alpha = alpha };
        }
    }.make;
    if (cp == 0x2580) {
        out[0] = r(0, 8, 0, 4, 1);
        return 1;
    }
    if (cp <= 0x2588) {
        out[0] = r(0, 8, @intCast(8 - (cp - 0x2580)), 8, 1);
        return 1;
    }
    if (cp <= 0x258f) {
        out[0] = r(0, @intCast(0x2590 - cp), 0, 8, 1);
        return 1;
    }
    switch (cp) {
        0x2590 => out[0] = r(4, 8, 0, 8, 1),
        0x2591 => out[0] = r(0, 8, 0, 8, 0.25),
        0x2592 => out[0] = r(0, 8, 0, 8, 0.5),
        0x2593 => out[0] = r(0, 8, 0, 8, 0.75),
        0x2594 => out[0] = r(0, 8, 0, 1, 1),
        0x2595 => out[0] = r(7, 8, 0, 8, 1),
        0x2596 => out[0] = r(0, 4, 4, 8, 1),
        0x2597 => out[0] = r(4, 8, 4, 8, 1),
        0x2598 => out[0] = r(0, 4, 0, 4, 1),
        0x259d => out[0] = r(4, 8, 0, 4, 1),
        0x2599 => {
            out.* = .{ r(0, 4, 0, 4, 1), r(0, 4, 4, 8, 1), r(4, 8, 4, 8, 1) };
            return 3;
        },
        0x259a => {
            out[0] = r(0, 4, 0, 4, 1);
            out[1] = r(4, 8, 4, 8, 1);
            return 2;
        },
        0x259b => {
            out.* = .{ r(0, 4, 0, 4, 1), r(4, 8, 0, 4, 1), r(0, 4, 4, 8, 1) };
            return 3;
        },
        0x259c => {
            out.* = .{ r(0, 4, 0, 4, 1), r(4, 8, 0, 4, 1), r(4, 8, 4, 8, 1) };
            return 3;
        },
        0x259e => {
            out[0] = r(4, 8, 0, 4, 1);
            out[1] = r(0, 4, 4, 8, 1);
            return 2;
        },
        0x259f => {
            out.* = .{ r(4, 8, 0, 4, 1), r(0, 4, 4, 8, 1), r(4, 8, 4, 8, 1) };
            return 3;
        },
        else => return 0,
    }
    return 1;
}
export fn cmdy_render_block_rects(cp: u32, out: [*c]c.CmdyRenderBlockRect, capacity: usize) usize {
    var result: [3]c.CmdyRenderBlockRect = undefined;
    const count = blockRects(cp, &result);
    if (out != null) @memcpy(out[0..@min(capacity, count)], result[0..@min(capacity, count)]);
    return count;
}
export fn cmdy_render_box_draw(cp: u32, context: ?*anyopaque, x: f64, y: f64, width: f64, height: f64, scale: f64, color: font.Object, thickness: isize) void {
    draw(cp, @ptrCast(context), x, y, width, height, scale, color, thickness);
}
export fn cmdy_render_diagonal_thickness(base: isize) isize {
    return diagonalThickness(base);
}
export fn cmdy_render_arc_axis(len: isize, thickness: isize) f64 {
    return arcAxis(len, thickness);
}
export fn cmdy_render_dash_spans(len: isize, count: isize, horizontal: u8, heavy: u8, thickness: isize, out: [*c]Span, capacity: usize) usize {
    var result: std.ArrayList(Span) = .empty;
    defer result.deinit(a);
    dashSpans(len, count, horizontal != 0, heavy != 0, thickness, &result) catch return 0;
    if (out != null) @memcpy(out[0..@min(capacity, result.items.len)], result.items[0..@min(capacity, result.items.len)]);
    return result.items.len;
}
export fn cmdy_render_centered_band(len: isize, thickness: isize, upper: u8) Span {
    return centeredBand(len, thickness, upper != 0);
}
export fn cmdy_render_canvas_line(context: ?*anyopaque, x: f64, y: f64, width: isize, height: isize, minimum: isize, x0: f64, y0: f64, x1: f64, y1: f64, thickness: isize) void {
    (Canvas{ .context = @ptrCast(context), .x = x, .y = y, .width = width, .height = height, .minimum = minimum }).line(x0, y0, x1, y1, thickness);
}
export fn cmdy_render_canvas_box(context: ?*anyopaque, x: f64, y: f64, width: isize, height: isize, bx: isize, by: isize, bw: isize, bh: isize) void {
    (Canvas{ .context = @ptrCast(context), .x = x, .y = y, .width = width, .height = height, .minimum = 1 }).box(bx, by, bw, bh);
}

// Unicode box names reduced to [up, right, down, left] stroke data.
const sides = [128][4]u8{
    .{ 0, 1, 0, 1 }, // 0x2500 BOX DRAWINGS LIGHT HORIZONTAL
    .{ 0, 2, 0, 2 }, // 0x2501 BOX DRAWINGS HEAVY HORIZONTAL
    .{ 1, 0, 1, 0 }, // 0x2502 BOX DRAWINGS LIGHT VERTICAL
    .{ 2, 0, 2, 0 }, // 0x2503 BOX DRAWINGS HEAVY VERTICAL
    .{ 0, 1, 0, 1 }, // 0x2504 BOX DRAWINGS LIGHT TRIPLE DASH HORIZONTAL
    .{ 0, 2, 0, 2 }, // 0x2505 BOX DRAWINGS HEAVY TRIPLE DASH HORIZONTAL
    .{ 1, 0, 1, 0 }, // 0x2506 BOX DRAWINGS LIGHT TRIPLE DASH VERTICAL
    .{ 2, 0, 2, 0 }, // 0x2507 BOX DRAWINGS HEAVY TRIPLE DASH VERTICAL
    .{ 0, 1, 0, 1 }, // 0x2508 BOX DRAWINGS LIGHT QUADRUPLE DASH HORIZONTAL
    .{ 0, 2, 0, 2 }, // 0x2509 BOX DRAWINGS HEAVY QUADRUPLE DASH HORIZONTAL
    .{ 1, 0, 1, 0 }, // 0x250a BOX DRAWINGS LIGHT QUADRUPLE DASH VERTICAL
    .{ 2, 0, 2, 0 }, // 0x250b BOX DRAWINGS HEAVY QUADRUPLE DASH VERTICAL
    .{ 0, 1, 1, 0 }, // 0x250c BOX DRAWINGS LIGHT DOWN AND RIGHT
    .{ 0, 2, 1, 0 }, // 0x250d BOX DRAWINGS DOWN LIGHT AND RIGHT HEAVY
    .{ 0, 1, 2, 0 }, // 0x250e BOX DRAWINGS DOWN HEAVY AND RIGHT LIGHT
    .{ 0, 2, 2, 0 }, // 0x250f BOX DRAWINGS HEAVY DOWN AND RIGHT
    .{ 0, 0, 1, 1 }, // 0x2510 BOX DRAWINGS LIGHT DOWN AND LEFT
    .{ 0, 0, 1, 2 }, // 0x2511 BOX DRAWINGS DOWN LIGHT AND LEFT HEAVY
    .{ 0, 0, 2, 1 }, // 0x2512 BOX DRAWINGS DOWN HEAVY AND LEFT LIGHT
    .{ 0, 0, 2, 2 }, // 0x2513 BOX DRAWINGS HEAVY DOWN AND LEFT
    .{ 1, 1, 0, 0 }, // 0x2514 BOX DRAWINGS LIGHT UP AND RIGHT
    .{ 1, 2, 0, 0 }, // 0x2515 BOX DRAWINGS UP LIGHT AND RIGHT HEAVY
    .{ 2, 1, 0, 0 }, // 0x2516 BOX DRAWINGS UP HEAVY AND RIGHT LIGHT
    .{ 2, 2, 0, 0 }, // 0x2517 BOX DRAWINGS HEAVY UP AND RIGHT
    .{ 1, 0, 0, 1 }, // 0x2518 BOX DRAWINGS LIGHT UP AND LEFT
    .{ 1, 0, 0, 2 }, // 0x2519 BOX DRAWINGS UP LIGHT AND LEFT HEAVY
    .{ 2, 0, 0, 1 }, // 0x251a BOX DRAWINGS UP HEAVY AND LEFT LIGHT
    .{ 2, 0, 0, 2 }, // 0x251b BOX DRAWINGS HEAVY UP AND LEFT
    .{ 1, 1, 1, 0 }, // 0x251c BOX DRAWINGS LIGHT VERTICAL AND RIGHT
    .{ 1, 2, 1, 0 }, // 0x251d BOX DRAWINGS VERTICAL LIGHT AND RIGHT HEAVY
    .{ 2, 1, 1, 0 }, // 0x251e BOX DRAWINGS UP HEAVY AND RIGHT DOWN LIGHT
    .{ 1, 1, 2, 0 }, // 0x251f BOX DRAWINGS DOWN HEAVY AND RIGHT UP LIGHT
    .{ 2, 1, 2, 0 }, // 0x2520 BOX DRAWINGS VERTICAL HEAVY AND RIGHT LIGHT
    .{ 2, 2, 1, 0 }, // 0x2521 BOX DRAWINGS DOWN LIGHT AND RIGHT UP HEAVY
    .{ 1, 2, 2, 0 }, // 0x2522 BOX DRAWINGS UP LIGHT AND RIGHT DOWN HEAVY
    .{ 2, 2, 2, 0 }, // 0x2523 BOX DRAWINGS HEAVY VERTICAL AND RIGHT
    .{ 1, 0, 1, 1 }, // 0x2524 BOX DRAWINGS LIGHT VERTICAL AND LEFT
    .{ 1, 0, 1, 2 }, // 0x2525 BOX DRAWINGS VERTICAL LIGHT AND LEFT HEAVY
    .{ 2, 0, 1, 1 }, // 0x2526 BOX DRAWINGS UP HEAVY AND LEFT DOWN LIGHT
    .{ 1, 0, 2, 1 }, // 0x2527 BOX DRAWINGS DOWN HEAVY AND LEFT UP LIGHT
    .{ 2, 0, 2, 1 }, // 0x2528 BOX DRAWINGS VERTICAL HEAVY AND LEFT LIGHT
    .{ 2, 0, 1, 2 }, // 0x2529 BOX DRAWINGS DOWN LIGHT AND LEFT UP HEAVY
    .{ 1, 0, 2, 2 }, // 0x252a BOX DRAWINGS UP LIGHT AND LEFT DOWN HEAVY
    .{ 2, 0, 2, 2 }, // 0x252b BOX DRAWINGS HEAVY VERTICAL AND LEFT
    .{ 0, 1, 1, 1 }, // 0x252c BOX DRAWINGS LIGHT DOWN AND HORIZONTAL
    .{ 0, 1, 1, 2 }, // 0x252d BOX DRAWINGS LEFT HEAVY AND RIGHT DOWN LIGHT
    .{ 0, 2, 1, 1 }, // 0x252e BOX DRAWINGS RIGHT HEAVY AND LEFT DOWN LIGHT
    .{ 0, 2, 1, 2 }, // 0x252f BOX DRAWINGS DOWN LIGHT AND HORIZONTAL HEAVY
    .{ 0, 1, 2, 1 }, // 0x2530 BOX DRAWINGS DOWN HEAVY AND HORIZONTAL LIGHT
    .{ 0, 1, 2, 2 }, // 0x2531 BOX DRAWINGS RIGHT LIGHT AND LEFT DOWN HEAVY
    .{ 0, 2, 2, 1 }, // 0x2532 BOX DRAWINGS LEFT LIGHT AND RIGHT DOWN HEAVY
    .{ 0, 2, 2, 2 }, // 0x2533 BOX DRAWINGS HEAVY DOWN AND HORIZONTAL
    .{ 1, 1, 0, 1 }, // 0x2534 BOX DRAWINGS LIGHT UP AND HORIZONTAL
    .{ 1, 1, 0, 2 }, // 0x2535 BOX DRAWINGS LEFT HEAVY AND RIGHT UP LIGHT
    .{ 1, 2, 0, 1 }, // 0x2536 BOX DRAWINGS RIGHT HEAVY AND LEFT UP LIGHT
    .{ 1, 2, 0, 2 }, // 0x2537 BOX DRAWINGS UP LIGHT AND HORIZONTAL HEAVY
    .{ 2, 1, 0, 1 }, // 0x2538 BOX DRAWINGS UP HEAVY AND HORIZONTAL LIGHT
    .{ 2, 1, 0, 2 }, // 0x2539 BOX DRAWINGS RIGHT LIGHT AND LEFT UP HEAVY
    .{ 2, 2, 0, 1 }, // 0x253a BOX DRAWINGS LEFT LIGHT AND RIGHT UP HEAVY
    .{ 2, 2, 0, 2 }, // 0x253b BOX DRAWINGS HEAVY UP AND HORIZONTAL
    .{ 1, 1, 1, 1 }, // 0x253c BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL
    .{ 1, 1, 1, 2 }, // 0x253d BOX DRAWINGS LEFT HEAVY AND RIGHT VERTICAL LIGHT
    .{ 1, 2, 1, 1 }, // 0x253e BOX DRAWINGS RIGHT HEAVY AND LEFT VERTICAL LIGHT
    .{ 1, 2, 1, 2 }, // 0x253f BOX DRAWINGS VERTICAL LIGHT AND HORIZONTAL HEAVY
    .{ 2, 1, 1, 1 }, // 0x2540 BOX DRAWINGS UP HEAVY AND DOWN HORIZONTAL LIGHT
    .{ 1, 1, 2, 1 }, // 0x2541 BOX DRAWINGS DOWN HEAVY AND UP HORIZONTAL LIGHT
    .{ 2, 1, 2, 1 }, // 0x2542 BOX DRAWINGS VERTICAL HEAVY AND HORIZONTAL LIGHT
    .{ 2, 1, 1, 2 }, // 0x2543 BOX DRAWINGS LEFT UP HEAVY AND RIGHT DOWN LIGHT
    .{ 2, 2, 1, 1 }, // 0x2544 BOX DRAWINGS RIGHT UP HEAVY AND LEFT DOWN LIGHT
    .{ 1, 1, 2, 2 }, // 0x2545 BOX DRAWINGS LEFT DOWN HEAVY AND RIGHT UP LIGHT
    .{ 1, 2, 2, 1 }, // 0x2546 BOX DRAWINGS RIGHT DOWN HEAVY AND LEFT UP LIGHT
    .{ 2, 2, 1, 2 }, // 0x2547 BOX DRAWINGS DOWN LIGHT AND UP HORIZONTAL HEAVY
    .{ 1, 2, 2, 2 }, // 0x2548 BOX DRAWINGS UP LIGHT AND DOWN HORIZONTAL HEAVY
    .{ 2, 1, 2, 2 }, // 0x2549 BOX DRAWINGS RIGHT LIGHT AND LEFT VERTICAL HEAVY
    .{ 2, 2, 2, 1 }, // 0x254a BOX DRAWINGS LEFT LIGHT AND RIGHT VERTICAL HEAVY
    .{ 2, 2, 2, 2 }, // 0x254b BOX DRAWINGS HEAVY VERTICAL AND HORIZONTAL
    .{ 0, 4, 0, 4 }, // 0x254c BOX DRAWINGS LIGHT DOUBLE DASH HORIZONTAL
    .{ 0, 4, 0, 4 }, // 0x254d BOX DRAWINGS HEAVY DOUBLE DASH HORIZONTAL
    .{ 4, 0, 4, 0 }, // 0x254e BOX DRAWINGS LIGHT DOUBLE DASH VERTICAL
    .{ 4, 0, 4, 0 }, // 0x254f BOX DRAWINGS HEAVY DOUBLE DASH VERTICAL
    .{ 0, 4, 0, 4 }, // 0x2550 BOX DRAWINGS DOUBLE HORIZONTAL
    .{ 4, 0, 4, 0 }, // 0x2551 BOX DRAWINGS DOUBLE VERTICAL
    .{ 0, 4, 3, 0 }, // 0x2552 BOX DRAWINGS DOWN SINGLE AND RIGHT DOUBLE
    .{ 0, 3, 4, 0 }, // 0x2553 BOX DRAWINGS DOWN DOUBLE AND RIGHT SINGLE
    .{ 0, 4, 4, 0 }, // 0x2554 BOX DRAWINGS DOUBLE DOWN AND RIGHT
    .{ 0, 0, 3, 4 }, // 0x2555 BOX DRAWINGS DOWN SINGLE AND LEFT DOUBLE
    .{ 0, 0, 4, 3 }, // 0x2556 BOX DRAWINGS DOWN DOUBLE AND LEFT SINGLE
    .{ 0, 0, 4, 4 }, // 0x2557 BOX DRAWINGS DOUBLE DOWN AND LEFT
    .{ 3, 4, 0, 0 }, // 0x2558 BOX DRAWINGS UP SINGLE AND RIGHT DOUBLE
    .{ 4, 3, 0, 0 }, // 0x2559 BOX DRAWINGS UP DOUBLE AND RIGHT SINGLE
    .{ 4, 4, 0, 0 }, // 0x255a BOX DRAWINGS DOUBLE UP AND RIGHT
    .{ 3, 0, 0, 4 }, // 0x255b BOX DRAWINGS UP SINGLE AND LEFT DOUBLE
    .{ 4, 0, 0, 3 }, // 0x255c BOX DRAWINGS UP DOUBLE AND LEFT SINGLE
    .{ 4, 0, 0, 4 }, // 0x255d BOX DRAWINGS DOUBLE UP AND LEFT
    .{ 3, 4, 3, 0 }, // 0x255e BOX DRAWINGS VERTICAL SINGLE AND RIGHT DOUBLE
    .{ 4, 3, 4, 0 }, // 0x255f BOX DRAWINGS VERTICAL DOUBLE AND RIGHT SINGLE
    .{ 4, 4, 4, 0 }, // 0x2560 BOX DRAWINGS DOUBLE VERTICAL AND RIGHT
    .{ 3, 0, 3, 4 }, // 0x2561 BOX DRAWINGS VERTICAL SINGLE AND LEFT DOUBLE
    .{ 4, 0, 4, 3 }, // 0x2562 BOX DRAWINGS VERTICAL DOUBLE AND LEFT SINGLE
    .{ 4, 0, 4, 4 }, // 0x2563 BOX DRAWINGS DOUBLE VERTICAL AND LEFT
    .{ 0, 4, 3, 4 }, // 0x2564 BOX DRAWINGS DOWN SINGLE AND HORIZONTAL DOUBLE
    .{ 0, 3, 4, 3 }, // 0x2565 BOX DRAWINGS DOWN DOUBLE AND HORIZONTAL SINGLE
    .{ 0, 4, 4, 4 }, // 0x2566 BOX DRAWINGS DOUBLE DOWN AND HORIZONTAL
    .{ 3, 4, 0, 4 }, // 0x2567 BOX DRAWINGS UP SINGLE AND HORIZONTAL DOUBLE
    .{ 4, 3, 0, 3 }, // 0x2568 BOX DRAWINGS UP DOUBLE AND HORIZONTAL SINGLE
    .{ 4, 4, 0, 4 }, // 0x2569 BOX DRAWINGS DOUBLE UP AND HORIZONTAL
    .{ 3, 4, 3, 4 }, // 0x256a BOX DRAWINGS VERTICAL SINGLE AND HORIZONTAL DOUBLE
    .{ 4, 3, 4, 3 }, // 0x256b BOX DRAWINGS VERTICAL DOUBLE AND HORIZONTAL SINGLE
    .{ 4, 4, 4, 4 }, // 0x256c BOX DRAWINGS DOUBLE VERTICAL AND HORIZONTAL
    .{ 0, 1, 1, 0 }, // 0x256d BOX DRAWINGS LIGHT ARC DOWN AND RIGHT
    .{ 0, 0, 1, 1 }, // 0x256e BOX DRAWINGS LIGHT ARC DOWN AND LEFT
    .{ 1, 0, 0, 1 }, // 0x256f BOX DRAWINGS LIGHT ARC UP AND LEFT
    .{ 1, 1, 0, 0 }, // 0x2570 BOX DRAWINGS LIGHT ARC UP AND RIGHT
    .{ 0, 1, 0, 1 }, // 0x2571 BOX DRAWINGS LIGHT DIAGONAL UPPER RIGHT TO LOWER LEFT
    .{ 0, 1, 0, 1 }, // 0x2572 BOX DRAWINGS LIGHT DIAGONAL UPPER LEFT TO LOWER RIGHT
    .{ 0, 0, 0, 0 }, // 0x2573 BOX DRAWINGS LIGHT DIAGONAL CROSS
    .{ 0, 0, 0, 1 }, // 0x2574 BOX DRAWINGS LIGHT LEFT
    .{ 1, 0, 0, 0 }, // 0x2575 BOX DRAWINGS LIGHT UP
    .{ 0, 1, 0, 0 }, // 0x2576 BOX DRAWINGS LIGHT RIGHT
    .{ 0, 0, 1, 0 }, // 0x2577 BOX DRAWINGS LIGHT DOWN
    .{ 0, 0, 0, 2 }, // 0x2578 BOX DRAWINGS HEAVY LEFT
    .{ 2, 0, 0, 0 }, // 0x2579 BOX DRAWINGS HEAVY UP
    .{ 0, 2, 0, 0 }, // 0x257a BOX DRAWINGS HEAVY RIGHT
    .{ 0, 0, 2, 0 }, // 0x257b BOX DRAWINGS HEAVY DOWN
    .{ 0, 2, 0, 1 }, // 0x257c BOX DRAWINGS LIGHT LEFT AND HEAVY RIGHT
    .{ 1, 0, 2, 0 }, // 0x257d BOX DRAWINGS LIGHT UP AND HEAVY DOWN
    .{ 0, 1, 0, 2 }, // 0x257e BOX DRAWINGS HEAVY LEFT AND LIGHT RIGHT
    .{ 2, 0, 1, 0 }, // 0x257f BOX DRAWINGS HEAVY UP AND LIGHT DOWN
};
fn singleDouble(cp: u32, canvas: Canvas) void {
    const thickness = canvas.minimum;
    const xCenter = centeredBand(canvas.width, thickness, false);
    const yCenter = centeredBand(canvas.height, thickness, false);
    const xBefore = range(@max(0, xCenter.lower - thickness), xCenter.lower);
    const xAfter = range(xCenter.upper, @min(canvas.width, xCenter.upper + thickness));
    const yBefore = range(@max(0, yCenter.lower - thickness), yCenter.lower);
    const yAfter = range(yCenter.upper, @min(canvas.height, yCenter.upper + thickness));
    const fullX = range(0, canvas.width);
    const fullY = range(0, canvas.height);
    switch (cp) {
        0x2550 => {
            canvas.fill(fullX, yBefore);
            canvas.fill(fullX, yAfter);
        },
        0x2551 => {
            canvas.fill(xBefore, fullY);
            canvas.fill(xAfter, fullY);
        },
        0x2552 => {
            canvas.horizontal(yBefore, xCenter.lower, fullX.upper);
            canvas.horizontal(yAfter, xCenter.lower, fullX.upper);
            canvas.vertical(xCenter, yCenter.lower, fullY.upper);
        },
        0x2553 => {
            canvas.horizontal(yCenter, xBefore.lower, fullX.upper);
            canvas.vertical(xBefore, yCenter.lower, fullY.upper);
            canvas.vertical(xAfter, yCenter.lower, fullY.upper);
        },
        0x2554 => {
            canvas.horizontal(yBefore, xBefore.lower, fullX.upper);
            canvas.vertical(xBefore, yBefore.lower, fullY.upper);
            canvas.horizontal(yAfter, xAfter.lower, fullX.upper);
            canvas.vertical(xAfter, yAfter.lower, fullY.upper);
        },
        0x2555 => {
            canvas.horizontal(yBefore, 0, xCenter.upper);
            canvas.horizontal(yAfter, 0, xCenter.upper);
            canvas.vertical(xCenter, yCenter.lower, fullY.upper);
        },
        0x2556 => {
            canvas.horizontal(yCenter, 0, xAfter.upper);
            canvas.vertical(xBefore, yCenter.lower, fullY.upper);
            canvas.vertical(xAfter, yCenter.lower, fullY.upper);
        },
        0x2557 => {
            canvas.horizontal(yBefore, 0, xAfter.upper);
            canvas.vertical(xAfter, yBefore.lower, fullY.upper);
            canvas.horizontal(yAfter, 0, xBefore.upper);
            canvas.vertical(xBefore, yAfter.lower, fullY.upper);
        },
        0x2558 => {
            canvas.horizontal(yBefore, xCenter.lower, fullX.upper);
            canvas.horizontal(yAfter, xCenter.lower, fullX.upper);
            canvas.vertical(xCenter, 0, yCenter.upper);
        },
        0x2559 => {
            canvas.horizontal(yCenter, xBefore.lower, fullX.upper);
            canvas.vertical(xBefore, 0, yCenter.upper);
            canvas.vertical(xAfter, 0, yCenter.upper);
        },
        0x255a => {
            canvas.vertical(xBefore, 0, yAfter.upper);
            canvas.vertical(xAfter, 0, yBefore.upper);
            canvas.horizontal(yBefore, xAfter.lower, fullX.upper);
            canvas.horizontal(yAfter, xBefore.lower, fullX.upper);
        },
        0x255b => {
            canvas.horizontal(yBefore, 0, xCenter.upper);
            canvas.horizontal(yAfter, 0, xCenter.upper);
            canvas.vertical(xCenter, 0, yCenter.upper);
        },
        0x255c => {
            canvas.horizontal(yCenter, 0, xAfter.upper);
            canvas.vertical(xBefore, 0, yCenter.upper);
            canvas.vertical(xAfter, 0, yCenter.upper);
        },
        0x255d => {
            canvas.vertical(xAfter, 0, yAfter.upper);
            canvas.vertical(xBefore, 0, yBefore.upper);
            canvas.horizontal(yBefore, 0, xBefore.upper);
            canvas.horizontal(yAfter, 0, xAfter.upper);
        },
        0x255e => {
            canvas.fill(xCenter, fullY);
            canvas.horizontal(yBefore, xCenter.lower, fullX.upper);
            canvas.horizontal(yAfter, xCenter.lower, fullX.upper);
        },
        0x255f => {
            canvas.fill(xBefore, fullY);
            canvas.fill(xAfter, fullY);
            canvas.horizontal(yCenter, xAfter.lower, fullX.upper);
        },
        0x2560 => {
            canvas.fill(xBefore, fullY);
            canvas.vertical(xAfter, 0, yBefore.upper);
            canvas.vertical(xAfter, yAfter.lower, fullY.upper);
            canvas.horizontal(yBefore, xAfter.lower, fullX.upper);
            canvas.horizontal(yAfter, xAfter.lower, fullX.upper);
        },
        0x2561 => {
            canvas.fill(xCenter, fullY);
            canvas.horizontal(yBefore, 0, xCenter.upper);
            canvas.horizontal(yAfter, 0, xCenter.upper);
        },
        0x2562 => {
            canvas.fill(xBefore, fullY);
            canvas.fill(xAfter, fullY);
            canvas.horizontal(yCenter, 0, xBefore.upper);
        },
        0x2563 => {
            canvas.fill(xAfter, fullY);
            canvas.vertical(xBefore, 0, yBefore.upper);
            canvas.vertical(xBefore, yAfter.lower, fullY.upper);
            canvas.horizontal(yBefore, 0, xBefore.upper);
            canvas.horizontal(yAfter, 0, xBefore.upper);
        },
        0x2564 => {
            canvas.fill(fullX, yBefore);
            canvas.fill(fullX, yAfter);
            canvas.vertical(xCenter, yAfter.lower, fullY.upper);
        },
        0x2565 => {
            canvas.fill(fullX, yCenter);
            canvas.vertical(xBefore, yCenter.lower, fullY.upper);
            canvas.vertical(xAfter, yCenter.lower, fullY.upper);
        },
        0x2566 => {
            canvas.fill(fullX, yBefore);
            canvas.horizontal(yAfter, 0, xBefore.upper);
            canvas.horizontal(yAfter, xAfter.lower, fullX.upper);
            canvas.vertical(xBefore, yAfter.lower, fullY.upper);
            canvas.vertical(xAfter, yAfter.lower, fullY.upper);
        },
        0x2567 => {
            canvas.fill(fullX, yBefore);
            canvas.fill(fullX, yAfter);
            canvas.vertical(xCenter, 0, yBefore.upper);
        },
        0x2568 => {
            canvas.fill(fullX, yCenter);
            canvas.vertical(xBefore, 0, yCenter.upper);
            canvas.vertical(xAfter, 0, yCenter.upper);
        },
        0x2569 => {
            canvas.horizontal(yBefore, 0, xBefore.upper);
            canvas.horizontal(yBefore, xAfter.lower, fullX.upper);
            canvas.fill(fullX, yAfter);
            canvas.vertical(xBefore, 0, yBefore.upper);
            canvas.vertical(xAfter, 0, yBefore.upper);
        },
        0x256a => {
            canvas.fill(xCenter, fullY);
            canvas.fill(fullX, yBefore);
            canvas.fill(fullX, yAfter);
        },
        0x256b => {
            canvas.fill(xBefore, fullY);
            canvas.fill(xAfter, fullY);
            canvas.fill(fullX, yCenter);
        },
        0x256c => {
            canvas.vertical(xBefore, 0, yBefore.upper);
            canvas.vertical(xAfter, 0, yBefore.upper);
            canvas.vertical(xBefore, yAfter.lower, fullY.upper);
            canvas.vertical(xAfter, yAfter.lower, fullY.upper);
            canvas.horizontal(yBefore, 0, xBefore.upper);
            canvas.horizontal(yBefore, xAfter.lower, fullX.upper);
            canvas.horizontal(yAfter, 0, xBefore.upper);
            canvas.horizontal(yAfter, xAfter.lower, fullX.upper);
        },
        else => {},
    }
}
export fn cmdy_render_block_rect(x0: u8, x1: u8, y0: u8, y1: u8, alpha: f64) c.CmdyRenderBlockRect {
    return .{ .x0 = @min(8, x0), .x1 = @min(8, @max(x0, x1)), .y0 = @min(8, y0), .y1 = @min(8, @max(y0, y1)), .alpha = alpha };
}
export fn cmdy_render_block_geometry(r: c.CmdyRenderBlockRect, x: f64, y: f64, xe: f64, ye: f64, height: f64) c.CmdyRenderRect {
    return .{ .x = x + @as(f64, @floatFromInt(r.x0)) * xe, .y = y + height - @as(f64, @floatFromInt(r.y1)) * ye, .width = @as(f64, @floatFromInt(r.x1 - r.x0)) * xe, .height = @as(f64, @floatFromInt(r.y1 - r.y0)) * ye };
}
export fn cmdy_render_canvas_point(x: f64, y: f64, width: isize, height: isize, ux: f64, uy: f64) c.CmdyRenderPoint {
    return .{ .x = x + ux * fl(width), .y = y + uy * fl(height) };
}
