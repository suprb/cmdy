//! Scheduling hints owned by a render session, never by the UI thread.
//! Surface state comes from host controls. Focus comes from accepted host
//! frame metadata: lightweight controls intentionally omit focus reads.
pub const Class = enum(u8) { utility = 0, user_initiated = 1, user_interactive = 2 };

pub const Policy = struct {
    surface_known: bool = false,
    visible: bool = false,
    key_window: bool = false,
    focused: bool = false,
    attempted: ?Class = null,

    pub fn desired(self: Policy) Class {
        // Metal initialization precedes the first queued host environment.
        // Do not demote an opening foreground window before its state arrives.
        if (!self.surface_known) return .user_interactive;
        if (!self.visible) return .utility;
        if (!self.key_window or !self.focused) return .user_initiated;
        return .user_interactive;
    }

    pub fn change(self: *Policy) ?Class {
        const next = self.desired();
        if (self.attempted == next) return null;
        // QoS is best effort. An OS rejection must not turn every subsequent
        // draw/completion into another syscall; retry on the next class change.
        self.attempted = next;
        return next;
    }
};
