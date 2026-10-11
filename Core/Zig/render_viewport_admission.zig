//! A single ordinary callback may join its still-active viewport draw.
//! New content, a different frame, completed work and all later callbacks draw normally.
const std = @import("std");
pub const Identity = struct {
    epoch: u64, revision: u64, generation: u64, sequence: u64,
};
pub const OneCallback = struct {
    token: ?Identity = null,
    pub fn clear(self: *OneCallback) void { self.token = null; }
    pub fn arm(self: *OneCallback, value: Identity) void { self.token = value; }
    pub fn consume(self: *OneCallback, current: Identity, pending: u64, in_flight: u64, visible: bool) bool {
        const expected = self.token orelse return false;
        self.token = null;
        return visible and std.meta.eql(expected, current) and
            (pending == expected.sequence or in_flight == expected.sequence);
    }
};
const original = Identity{ .epoch = 4, .revision = 17, .generation = 3, .sequence = 22 };
test "pending capture owns only the first callback" {
    var policy = OneCallback{};policy.arm(original);
    try std.testing.expect(policy.consume(original,22,0,true));
    try std.testing.expect(!policy.consume(original,22,0,true));
}
test "submitted GPU frame owns only the first callback" {
    var policy = OneCallback{};policy.arm(original);
    try std.testing.expect(policy.consume(original,0,22,true));
    try std.testing.expect(!policy.consume(original,0,22,true));
}
test "completion and failed capture preserve ordinary redraw" {
    var policy = OneCallback{};policy.arm(original);
    try std.testing.expect(!policy.consume(original,0,0,true));
    try std.testing.expect(!policy.consume(original,22,0,true));
}
test "source epoch keyboard and frame changes each preserve redraw" {
    inline for (.{"epoch","revision","generation","sequence"}) |field| {
        var policy = OneCallback{};policy.arm(original);
        var newer = original;@field(newer,field) += 1;
        try std.testing.expect(!policy.consume(newer,22,22,true));
        try std.testing.expect(!policy.consume(original,22,22,true));
    }
}
test "hidden detached and missing source cannot consume a draw" {
    var policy = OneCallback{};policy.arm(original);
    try std.testing.expect(!policy.consume(original,22,0,false));
    try std.testing.expect(!policy.consume(original,22,0,true));
}
test "another capture or GPU frame does not suppress callback" {
    var policy = OneCallback{};policy.arm(original);
    try std.testing.expect(!policy.consume(original,23,23,true));
}
test "reset removes callback token" {
    var policy = OneCallback{};policy.arm(original);policy.clear();
    try std.testing.expect(!policy.consume(original,22,0,true));
}
test "a later viewport owns its own callback without retaining the old frame" {
    var policy = OneCallback{};policy.arm(original);
    var next = original;next.revision += 1;next.sequence += 1;
    policy.arm(next);
    try std.testing.expect(policy.consume(next,23,0,true));
    try std.testing.expect(!policy.consume(next,23,0,true));
}
