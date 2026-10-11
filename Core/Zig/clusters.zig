// Settled-row cluster rules. Swift supplies immutable runtime Unicode facts;
// this module owns eligibility and the next selector/width state. No callbacks.
const std = @import("std");

pub const Input = extern struct {
    owner_column: usize,
    cursor_x: usize,
    expected_scalar: u32,
    scalar: u32,
    role: u8,
    selector_authority: u8,
    lead_is_emoji: u8,
    lead_is_vs16_base: u8,
    scalar_is_emoji_component: u8,
    scalar_is_vs16_base: u8,
    reserved: [2]u8 = .{ 0, 0 },
};
pub const Result = extern struct {
    lead_column: usize = 0,
    cursor_x: usize = 0,
    generation: u64 = 0,
    selector_authority: u8 = 0,
    handled: u8 = 0,
    mutated: u8 = 0,
    wrap_pending: u8 = 0,
};
pub const Decision = struct {
    handled: bool = false,
    append: bool = false,
    width: i8,
    authority: u8,
};
const ordinary = 0;
const zero_width = 1;
const joiner = 2;
const text_variation = 3;
const emoji_variation = 4;
const variation = 5;
const regional_indicator = 6;
const available = 1;
const suspended = 2;
const blocked = 3;

pub fn valid(input: Input) bool {
    return input.role <= regional_indicator and input.selector_authority <= blocked and
        input.lead_is_emoji <= 1 and input.lead_is_vs16_base <= 1 and
        input.scalar_is_emoji_component <= 1 and input.scalar_is_vs16_base <= 1 and
        input.reserved[0] == 0 and input.reserved[1] == 0;
}
fn regional(scalar: u32) bool {
    return scalar >= 0x1f1e6 and scalar <= 0x1f1ff;
}
fn emojiComponent(scalar: u32, is_emoji: bool) bool {
    return is_emoji and scalar != 0x23 and scalar != 0x2a and !(scalar >= 0x30 and scalar <= 0x39);
}

pub fn decide(input: Input, lead: u32, width: i8, extras: []const u32) Decision {
    var result = Decision{ .width = width, .authority = input.selector_authority };
    const last = if (extras.len == 0) 0 else extras[extras.len - 1];
    switch (input.role) {
        ordinary => {
            if (input.scalar_is_emoji_component == 0 or last != 0x200d or
                (extras.len > 1 and extras[extras.len - 2] == 0x200d) or regional(lead) or
                std.mem.indexOfScalar(u32, extras, 0x20e3) != null or
                !emojiComponent(lead, input.lead_is_emoji == 1)) return result;
            if (result.authority != available and input.scalar_is_vs16_base == 1)
                result.authority = available;
        },
        regional_indicator => {
            if (!regional(lead) or std.mem.indexOfScalar(u32, extras, 0x200d) != null) return result;
            for (extras) |scalar| if (regional(scalar)) return result;
            result.width = 2;
        },
        emoji_variation, text_variation => {
            if (result.authority != available) {
                result.handled = true;
                return result;
            }
            if (input.lead_is_emoji == 0) return result;
            if (last == 0xfe0e or last == 0xfe0f) {
                result.authority = blocked;
                result.handled = true;
                return result;
            }
            const completed_join = if (std.mem.lastIndexOfScalar(u32, extras, 0x200d)) |index|
                index + 1 < extras.len else false;
            const expandable = input.lead_is_vs16_base == 1;
            if (input.role == emoji_variation and !expandable and width != 2) return result;
            if (width == 2 and !expandable and !completed_join) {
                result.authority = blocked;
                result.handled = true;
                return result;
            }
            result.width = if (input.role == text_variation) 1 else if (expandable) 2 else width;
            result.authority = blocked;
        },
        joiner, variation, zero_width => {
            if (result.authority == available) result.authority = suspended;
        },
        else => unreachable,
    }
    result.handled = true;
    result.append = true;
    return result;
}
