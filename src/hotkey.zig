const std = @import("std");
const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig"),
    .linux => @import("platform/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("Unsupported platform. Supported: macOS, Linux, Windows."),
};

pub const HotkeyError = platform.HotkeyError;
pub const HotkeyHandle = platform.HotkeyHandle;
pub const HotkeyCallback = platform.HotkeyCallback;
pub const Backend = platform.Backend;

/// Modifier flags — consistent across platforms.
pub const Modifier = packed struct(u8) {
    cmd: bool = false, // Cmd on macOS, Win on Windows, Super on Linux
    ctrl: bool = false,
    alt: bool = false, // Alt on Windows/Linux, Option on macOS
    shift: bool = false,
    _padding: u4 = 0,

    pub fn toInt(self: Modifier) u8 {
        return @bitCast(self);
    }

    pub fn fromInt(val: u8) Modifier {
        return @bitCast(val);
    }
};

/// Virtual key codes — platform-independent identifiers.
/// Mapped to platform-specific codes internally.
pub const Key = enum(u16) {
    a = 0,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    @"0" = 30,
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    f1 = 50,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    space = 70,
    @"return",
    tab,
    escape,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,

    /// Parse a key name string (case-insensitive).
    pub fn fromString(s: []const u8) ?Key {
        // Lowercase into stack buffer for comparison
        var buf: [16]u8 = undefined;
        if (s.len > buf.len) return null;
        for (s, 0..) |c, idx| {
            buf[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower = buf[0..s.len];

        const map = .{
            .{ "a", Key.a },
            .{ "b", Key.b },
            .{ "c", Key.c },
            .{ "d", Key.d },
            .{ "e", Key.e },
            .{ "f", Key.f },
            .{ "g", Key.g },
            .{ "h", Key.h },
            .{ "i", Key.i },
            .{ "j", Key.j },
            .{ "k", Key.k },
            .{ "l", Key.l },
            .{ "m", Key.m },
            .{ "n", Key.n },
            .{ "o", Key.o },
            .{ "p", Key.p },
            .{ "q", Key.q },
            .{ "r", Key.r },
            .{ "s", Key.s },
            .{ "t", Key.t },
            .{ "u", Key.u },
            .{ "v", Key.v },
            .{ "w", Key.w },
            .{ "x", Key.x },
            .{ "y", Key.y },
            .{ "z", Key.z },
            .{ "0", Key.@"0" },
            .{ "1", Key.@"1" },
            .{ "2", Key.@"2" },
            .{ "3", Key.@"3" },
            .{ "4", Key.@"4" },
            .{ "5", Key.@"5" },
            .{ "6", Key.@"6" },
            .{ "7", Key.@"7" },
            .{ "8", Key.@"8" },
            .{ "9", Key.@"9" },
            .{ "f1", Key.f1 },
            .{ "f2", Key.f2 },
            .{ "f3", Key.f3 },
            .{ "f4", Key.f4 },
            .{ "f5", Key.f5 },
            .{ "f6", Key.f6 },
            .{ "f7", Key.f7 },
            .{ "f8", Key.f8 },
            .{ "f9", Key.f9 },
            .{ "f10", Key.f10 },
            .{ "f11", Key.f11 },
            .{ "f12", Key.f12 },
            .{ "space", Key.space },
            .{ "return", Key.@"return" },
            .{ "enter", Key.@"return" },
            .{ "tab", Key.tab },
            .{ "escape", Key.escape },
            .{ "esc", Key.escape },
            .{ "backspace", Key.backspace },
            .{ "delete", Key.delete },
            .{ "up", Key.up },
            .{ "down", Key.down },
            .{ "left", Key.left },
            .{ "right", Key.right },
            .{ "home", Key.home },
            .{ "end", Key.end },
            .{ "pageup", Key.page_up },
            .{ "page_up", Key.page_up },
            .{ "pagedown", Key.page_down },
            .{ "page_down", Key.page_down },
        };

        inline for (map) |entry| {
            if (std.mem.eql(u8, lower, entry[0])) return entry[1];
        }
        return null;
    }
};

/// Parse a hotkey string like "cmd+shift+v" or "ctrl+alt+f1".
/// Modifier names: cmd/super/win, ctrl, alt/opt/option, shift
/// Returns modifier flags and key, or null if parse fails.
pub fn parseHotkeyString(s: []const u8) ?struct { modifiers: Modifier, key: Key } {
    var mods = Modifier{};
    var key: ?Key = null;

    var iter = std.mem.splitScalar(u8, s, '+');
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " ");
        if (part.len == 0) continue;

        // Lowercase for comparison
        var buf: [16]u8 = undefined;
        if (part.len > buf.len) return null;
        for (part, 0..) |c, idx| {
            buf[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower = buf[0..part.len];

        if (std.mem.eql(u8, lower, "cmd") or
            std.mem.eql(u8, lower, "super") or
            std.mem.eql(u8, lower, "win") or
            std.mem.eql(u8, lower, "meta"))
        {
            mods.cmd = true;
        } else if (std.mem.eql(u8, lower, "ctrl") or std.mem.eql(u8, lower, "control")) {
            mods.ctrl = true;
        } else if (std.mem.eql(u8, lower, "alt") or
            std.mem.eql(u8, lower, "opt") or
            std.mem.eql(u8, lower, "option"))
        {
            mods.alt = true;
        } else if (std.mem.eql(u8, lower, "shift")) {
            mods.shift = true;
        } else {
            // Must be the key
            if (key != null) return null; // multiple keys
            key = Key.fromString(part);
            if (key == null) return null;
        }
    }

    if (key) |k| {
        return .{ .modifiers = mods, .key = k };
    }
    return null;
}

/// Register a global hotkey. The callback fires on the platform event loop
/// thread when the key combination is pressed.
pub fn register(
    modifiers: Modifier,
    key: Key,
    callback: HotkeyCallback,
    userdata: ?*anyopaque,
    backend: Backend,
) !HotkeyHandle {
    return platform.register(modifiers, key, callback, userdata, backend);
}

/// Unregister a previously registered hotkey.
pub fn unregister(handle: HotkeyHandle) void {
    platform.unregister(handle);
}

/// Enter the platform event loop. Blocks until stop() is called.
/// Must be called from the main thread on macOS.
pub fn run() !void {
    return platform.run();
}

/// Signal the event loop to exit.
pub fn stop() void {
    platform.stop();
}
