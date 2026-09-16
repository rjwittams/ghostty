//! Resolve an explicit tracked origin without changing terminal view state.
const lib = @import("../lib.zig");
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const terminal = @import("terminal.zig");
const tracked = @import("grid_ref_tracked.zig");
const Result = @import("result.zig").Result;

pub const Error = error{ InvalidValue, NoValue };

/// A validated full-height capture range on the screen owning an origin.
pub const Resolved = struct {
    screen: *Screen,
    key: terminal.TerminalScreen,
    origin: PageList.Pin,
    offset: usize,
};

/// Validate a tracked origin against `t_` and normalize it to the top of
/// a full terminal-sized range on its owning screen. Never moves the
/// terminal viewport or the tracked anchor.
pub fn resolve(
    t_: terminal.Terminal,
    ref_: tracked.CTrackedGridRef,
) Error!Resolved {
    const ref = ref_ orelse return error.InvalidValue;
    if (ref.terminal == null or ref.terminal != t_) return error.InvalidValue;
    const t = (t_ orelse return error.InvalidValue).terminal;
    const pages = ref.pageList() orelse return error.NoValue;
    if (ref.pin.garbage) return error.NoValue;
    const pt = pages.pointFromPin(.screen, ref.pin.*) orelse return error.NoValue;
    // Keep a full terminal-sized viewport, shifting upwards near the bottom.
    // The tracked cell is preserved; resolving never repositions its anchor.
    const offset = @min(pt.screen.y, pages.total_rows - pages.rows);
    const origin = pages.pin(.{ .screen = .{
        .x = 0,
        .y = @intCast(offset),
    } }) orelse return error.NoValue;
    return .{
        .screen = t.screens.get(ref.screen_key).?,
        .key = ref.screen_key,
        .origin = origin,
        .offset = offset,
    };
}

/// Map a resolution error to its C result.
pub fn result(err: Error) Result {
    return switch (err) {
        error.InvalidValue => .invalid_value,
        error.NoValue => .no_value,
    };
}

/// C: ghostty_terminal_viewport_for_ref. Report the full-height capture
/// range for a tracked origin without moving the viewport or the anchor.
pub fn viewport(
    t: terminal.Terminal,
    ref: tracked.CTrackedGridRef,
    out_: ?*terminal.TerminalScrollbar,
) callconv(lib.calling_conv) Result {
    const out = out_ orelse return .invalid_value;
    const v = resolve(t, ref) catch |err| return result(err);
    out.* = .{
        .total = v.screen.pages.total_rows,
        .offset = v.offset,
        .len = v.screen.pages.rows,
    };
    return .success;
}
