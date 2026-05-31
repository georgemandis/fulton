const std = @import("std");
const hotkey = @import("../hotkey.zig");

// ---------------------------------------------------------------------------
// Public types (shared by all backends)
// ---------------------------------------------------------------------------

pub const HotkeyError = error{
    RegistrationFailed,
    TooManyHotkeys,
    EventTapDenied,
    RunLoopFailed,
};

pub const Backend = enum {
    simple,
    advanced,
};

pub const HotkeyHandle = struct {
    id: u32,
};

pub const HotkeyCallback = *const fn (userdata: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// Registration state (shared)
// ---------------------------------------------------------------------------

const MAX_HOTKEYS = 64;

const Registration = struct {
    id: u32,
    modifiers: hotkey.Modifier,
    key: hotkey.Key,
    callback: HotkeyCallback,
    userdata: ?*anyopaque,
    x11_keycode: u8,
    x11_mods: c_uint,
};

var registrations: [MAX_HOTKEYS]?Registration = [_]?Registration{null} ** MAX_HOTKEYS;
var next_id: u32 = 1;
var active_backend: enum { none, x11, evdev, portal } = .none;
var should_stop: std.atomic.Value(bool) = .init(false);

// ---------------------------------------------------------------------------
// Backend detection
// ---------------------------------------------------------------------------

fn isWayland() bool {
    if (std.c.getenv("XDG_SESSION_TYPE")) |s| {
        const slice = std.mem.sliceTo(s, 0);
        if (std.mem.eql(u8, slice, "wayland")) return true;
        if (std.mem.eql(u8, slice, "x11")) return false;
    }
    if (std.c.getenv("WAYLAND_DISPLAY") != null) return true;
    // sudo strips env vars — probe for wayland socket in common runtime dirs
    // SUDO_UID gives us the original user's UID
    const uid_str = if (std.c.getenv("SUDO_UID")) |s| std.mem.sliceTo(s, 0) else null;
    if (uid_str) |uid| {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/run/user/{s}/wayland-0\x00", .{uid}) catch null;
        if (path) |p| {
            // F_OK = 0 (check file existence)
            if (std.c.access(@ptrCast(p.ptr), 0) == 0) return true;
        }
    }
    if (std.c.getenv("DISPLAY") != null) return false;
    return true;
}

// ===========================================================================
// evdev backend — works on Wayland, X11, and TTY
// ===========================================================================

const EV_KEY: u16 = 0x01;

const InputEvent = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

// Linux evdev key codes (from input-event-codes.h)
const KEY_ESC: u16 = 1;
const KEY_1: u16 = 2;
const KEY_2: u16 = 3;
const KEY_3: u16 = 4;
const KEY_4: u16 = 5;
const KEY_5: u16 = 6;
const KEY_6: u16 = 7;
const KEY_7: u16 = 8;
const KEY_8: u16 = 9;
const KEY_9: u16 = 10;
const KEY_0: u16 = 11;
const KEY_TAB: u16 = 15;
const KEY_Q: u16 = 16;
const KEY_W: u16 = 17;
const KEY_E: u16 = 18;
const KEY_R: u16 = 19;
const KEY_T: u16 = 20;
const KEY_Y: u16 = 21;
const KEY_U: u16 = 22;
const KEY_I: u16 = 23;
const KEY_O: u16 = 24;
const KEY_P: u16 = 25;
const KEY_ENTER: u16 = 28;
const KEY_LEFTCTRL: u16 = 29;
const KEY_A: u16 = 30;
const KEY_S: u16 = 31;
const KEY_D: u16 = 32;
const KEY_F: u16 = 33;
const KEY_G: u16 = 34;
const KEY_H: u16 = 35;
const KEY_J: u16 = 36;
const KEY_K: u16 = 37;
const KEY_L: u16 = 38;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_Z: u16 = 44;
const KEY_X: u16 = 45;
const KEY_C: u16 = 46;
const KEY_V: u16 = 47;
const KEY_B: u16 = 48;
const KEY_N: u16 = 49;
const KEY_M: u16 = 50;
const KEY_SPACE: u16 = 57;
const KEY_F1: u16 = 59;
const KEY_F2: u16 = 60;
const KEY_F3: u16 = 61;
const KEY_F4: u16 = 62;
const KEY_F5: u16 = 63;
const KEY_F6: u16 = 64;
const KEY_F7: u16 = 65;
const KEY_F8: u16 = 66;
const KEY_F9: u16 = 67;
const KEY_F10: u16 = 68;
const KEY_F11: u16 = 87;
const KEY_F12: u16 = 88;
const KEY_RIGHTCTRL: u16 = 97;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_LEFTALT: u16 = 56;
const KEY_RIGHTALT: u16 = 100;
const KEY_LEFTMETA: u16 = 125;
const KEY_RIGHTMETA: u16 = 126;
const KEY_BACKSPACE: u16 = 14;
const KEY_DELETE: u16 = 111;
const KEY_UP: u16 = 103;
const KEY_DOWN: u16 = 108;
const KEY_LEFT: u16 = 105;
const KEY_RIGHT: u16 = 106;
const KEY_HOME: u16 = 102;
const KEY_END: u16 = 107;
const KEY_PAGEUP: u16 = 104;
const KEY_PAGEDOWN: u16 = 109;

fn keyToEvdev(key: hotkey.Key) u16 {
    return switch (key) {
        .a => KEY_A, .b => KEY_B, .c => KEY_C, .d => KEY_D,
        .e => KEY_E, .f => KEY_F, .g => KEY_G, .h => KEY_H,
        .i => KEY_I, .j => KEY_J, .k => KEY_K, .l => KEY_L,
        .m => KEY_M, .n => KEY_N, .o => KEY_O, .p => KEY_P,
        .q => KEY_Q, .r => KEY_R, .s => KEY_S, .t => KEY_T,
        .u => KEY_U, .v => KEY_V, .w => KEY_W, .x => KEY_X,
        .y => KEY_Y, .z => KEY_Z,
        .@"0" => KEY_0, .@"1" => KEY_1, .@"2" => KEY_2,
        .@"3" => KEY_3, .@"4" => KEY_4, .@"5" => KEY_5,
        .@"6" => KEY_6, .@"7" => KEY_7, .@"8" => KEY_8, .@"9" => KEY_9,
        .f1 => KEY_F1, .f2 => KEY_F2, .f3 => KEY_F3, .f4 => KEY_F4,
        .f5 => KEY_F5, .f6 => KEY_F6, .f7 => KEY_F7, .f8 => KEY_F8,
        .f9 => KEY_F9, .f10 => KEY_F10, .f11 => KEY_F11, .f12 => KEY_F12,
        .space => KEY_SPACE, .@"return" => KEY_ENTER, .tab => KEY_TAB,
        .escape => KEY_ESC, .backspace => KEY_BACKSPACE, .delete => KEY_DELETE,
        .up => KEY_UP, .down => KEY_DOWN, .left => KEY_LEFT, .right => KEY_RIGHT,
        .home => KEY_HOME, .end => KEY_END, .page_up => KEY_PAGEUP, .page_down => KEY_PAGEDOWN,
    };
}

fn isModifierKey(code: u16) bool {
    return code == KEY_LEFTCTRL or code == KEY_RIGHTCTRL or
        code == KEY_LEFTSHIFT or code == KEY_RIGHTSHIFT or
        code == KEY_LEFTALT or code == KEY_RIGHTALT or
        code == KEY_LEFTMETA or code == KEY_RIGHTMETA;
}

var mod_ctrl: bool = false;
var mod_shift: bool = false;
var mod_alt: bool = false;
var mod_super: bool = false;

fn updateModState(code: u16, pressed: bool) void {
    switch (code) {
        KEY_LEFTCTRL, KEY_RIGHTCTRL => mod_ctrl = pressed,
        KEY_LEFTSHIFT, KEY_RIGHTSHIFT => mod_shift = pressed,
        KEY_LEFTALT, KEY_RIGHTALT => mod_alt = pressed,
        KEY_LEFTMETA, KEY_RIGHTMETA => mod_super = pressed,
        else => {},
    }
}

const MAX_EVDEV_FDS = 32;
var evdev_fds: [MAX_EVDEV_FDS]std.posix.fd_t = [_]std.posix.fd_t{-1} ** MAX_EVDEV_FDS;
var evdev_count: usize = 0;

fn openInputDevices() !void {
    var path_buf: [32]u8 = undefined;
    for (0..32) |i| {
        const path = std.fmt.bufPrint(&path_buf, "/dev/input/event{}\x00", .{i}) catch continue;
        const path_z: [*:0]const u8 = @ptrCast(path.ptr);
        const fd = std.c.open(path_z, @bitCast(std.c.O{ .ACCMODE = .RDONLY, .NONBLOCK = true }), @as(c_uint, 0));
        if (fd >= 0) {
            if (evdev_count < MAX_EVDEV_FDS) {
                evdev_fds[evdev_count] = fd;
                evdev_count += 1;
                std.debug.print("evdev: opened /dev/input/event{} (fd={})\n", .{ i, fd });
            } else {
                _ = std.c.close(fd);
            }
        }
    }

    std.debug.print("evdev: opened {} devices total\n", .{evdev_count});

    if (evdev_count == 0) {
        return HotkeyError.RunLoopFailed;
    }
}

fn evdevRun() !void {
    std.debug.print("evdevRun: entering event loop\n", .{});
    try openInputDevices();

    should_stop.store(false, .release);

    var pollfds: [MAX_EVDEV_FDS]std.c.pollfd = undefined;
    for (0..evdev_count) |i| {
        pollfds[i] = .{
            .fd = evdev_fds[i],
            .events = std.c.POLL.IN,
            .revents = 0,
        };
    }

    while (!should_stop.load(.acquire)) {
        const poll_ret = std.c.poll(&pollfds, @intCast(evdev_count), 500);
        if (poll_ret <= 0) continue;

        for (0..evdev_count) |i| {
            if ((pollfds[i].revents & std.c.POLL.IN) == 0) continue;

            while (true) {
                var ev: InputEvent = undefined;
                const bytes_read = std.c.read(evdev_fds[i], @ptrCast(&ev), @sizeOf(InputEvent));
                if (bytes_read != @sizeOf(InputEvent)) break;

                if (ev.type != EV_KEY) continue;

                const pressed = ev.value == 1;

                if (isModifierKey(ev.code)) {
                    updateModState(ev.code, pressed or ev.value == 2);
                    continue;
                }

                if (!pressed) continue;

                std.debug.print("evdev: key={d} mods: ctrl={} shift={} alt={} super={}\n", .{
                    ev.code, mod_ctrl, mod_shift, mod_alt, mod_super,
                });

                for (&registrations) |*slot| {
                    if (slot.*) |reg| {
                        const expected_evdev = keyToEvdev(reg.key);
                        std.debug.print("  checking reg: expected_key={d} want ctrl={} shift={} alt={} cmd={}\n", .{
                            expected_evdev, reg.modifiers.ctrl, reg.modifiers.shift, reg.modifiers.alt, reg.modifiers.cmd,
                        });
                        if (ev.code != expected_evdev) continue;
                        if (reg.modifiers.ctrl != mod_ctrl) continue;
                        if (reg.modifiers.shift != mod_shift) continue;
                        if (reg.modifiers.alt != mod_alt) continue;
                        if (reg.modifiers.cmd != mod_super) continue;
                        std.debug.print("  MATCH! firing callback\n", .{});
                        reg.callback(reg.userdata);
                        break;
                    }
                }
            }
        }
    }

    for (0..evdev_count) |i| {
        _ = std.c.close(evdev_fds[i]);
        evdev_fds[i] = -1;
    }
    evdev_count = 0;
}

// ===========================================================================
// D-Bus GlobalShortcuts portal backend — works on modern Wayland desktops
// (GNOME 48+, KDE 5.27+) without elevated permissions.
// Uses gdbus CLI tool to avoid linking libdbus.
// ===========================================================================

var portal_session_handle: [256]u8 = undefined;
var portal_session_handle_len: usize = 0;
var portal_monitor_pid: std.c.pid_t = 0;
var portal_monitor_fd: std.posix.fd_t = -1;

fn buildTriggerString(mods: hotkey.Modifier, key: hotkey.Key, buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    const parts = [_]struct { flag: bool, str: []const u8 }{
        .{ .flag = mods.ctrl, .str = "<Control>" },
        .{ .flag = mods.shift, .str = "<Shift>" },
        .{ .flag = mods.alt, .str = "<Alt>" },
        .{ .flag = mods.cmd, .str = "<Super>" },
    };
    for (parts) |part| {
        if (part.flag) {
            if (pos + part.str.len > buf.len) return null;
            @memcpy(buf[pos..][0..part.str.len], part.str);
            pos += part.str.len;
        }
    }
    const key_name: []const u8 = switch (key) {
        .a => "a", .b => "b", .c => "c", .d => "d", .e => "e",
        .f => "f", .g => "g", .h => "h", .i => "i", .j => "j",
        .k => "k", .l => "l", .m => "m", .n => "n", .o => "o",
        .p => "p", .q => "q", .r => "r", .s => "s", .t => "t",
        .u => "u", .v => "v", .w => "w", .x => "x", .y => "y", .z => "z",
        .@"0" => "0", .@"1" => "1", .@"2" => "2", .@"3" => "3",
        .@"4" => "4", .@"5" => "5", .@"6" => "6", .@"7" => "7",
        .@"8" => "8", .@"9" => "9",
        .f1 => "F1", .f2 => "F2", .f3 => "F3", .f4 => "F4",
        .f5 => "F5", .f6 => "F6", .f7 => "F7", .f8 => "F8",
        .f9 => "F9", .f10 => "F10", .f11 => "F11", .f12 => "F12",
        .space => "space", .@"return" => "Return", .tab => "Tab",
        .escape => "Escape", .backspace => "BackSpace", .delete => "Delete",
        .up => "Up", .down => "Down", .left => "Left", .right => "Right",
        .home => "Home", .end => "End", .page_up => "Page_Up", .page_down => "Page_Down",
    };
    if (pos + key_name.len > buf.len) return null;
    @memcpy(buf[pos..][0..key_name.len], key_name);
    pos += key_name.len;
    return buf[0..pos];
}

fn runGdbus(argv: []const ?[*:0]const u8, out_buf: []u8) ?[]const u8 {
    var pipe_fds: [2]c_int = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return null;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        return null;
    }

    if (pid == 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], 1);
        _ = std.c.close(pipe_fds[1]);
        const dev_null = std.c.open("/dev/null", @bitCast(std.c.O{ .ACCMODE = .WRONLY }), @as(c_uint, 0));
        if (dev_null >= 0) {
            _ = std.c.dup2(dev_null, 2);
            _ = std.c.close(dev_null);
        }
        _ = std.c.execve(
            argv[0].?,
            @ptrCast(argv.ptr),
            @ptrCast(std.c.environ),
        );
        std.process.exit(127);
    }

    _ = std.c.close(pipe_fds[1]);
    var total: usize = 0;
    while (total < out_buf.len) {
        const n = std.c.read(pipe_fds[0], @ptrCast(out_buf[total..].ptr), out_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = std.c.close(pipe_fds[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    if (total == 0) return null;
    return out_buf[0..total];
}

fn extractObjectPath(output: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, output, prefix)) |start| {
        if (std.mem.indexOfPos(u8, output, start, "'")) |q_start| {
            if (std.mem.indexOfPos(u8, output, q_start + 1, "'")) |q_end| {
                return output[q_start + 1 .. q_end];
            }
        }
        var end = start;
        while (end < output.len and output[end] != ')' and output[end] != ',' and output[end] != '\'' and output[end] != ' ' and output[end] != '\n') : (end += 1) {}
        if (end > start) return output[start..end];
    }
    return null;
}

fn portalCheckAvailable() bool {
    var out_buf: [4096]u8 = undefined;
    const argv = [_]?[*:0]const u8{
        "/usr/bin/gdbus",
        "introspect",
        "--session",
        "--dest", "org.freedesktop.portal.Desktop",
        "--object-path", "/org/freedesktop/portal/desktop",
        null,
    };
    const output = runGdbus(@constCast(&argv), &out_buf) orelse return false;
    return std.mem.indexOf(u8, output, "GlobalShortcuts") != null;
}

fn portalCreateSession() !void {
    var out_buf: [4096]u8 = undefined;
    const argv = [_]?[*:0]const u8{
        "/usr/bin/gdbus",
        "call",
        "--session",
        "--dest", "org.freedesktop.portal.Desktop",
        "--object-path", "/org/freedesktop/portal/desktop",
        "--method", "org.freedesktop.portal.GlobalShortcuts.CreateSession",
        "{'handle_token': <'fulton1'>, 'session_handle_token': <'fulton1'>}",
        null,
    };
    const output = runGdbus(@constCast(&argv), &out_buf) orelse {
        return HotkeyError.RegistrationFailed;
    };

    if (extractObjectPath(output, "/org/freedesktop/portal/desktop")) |path| {
        const len = @min(path.len, portal_session_handle.len);
        @memcpy(portal_session_handle[0..len], path[0..len]);
        portal_session_handle_len = len;
    } else {
        return HotkeyError.RegistrationFailed;
    }
}

fn portalBindShortcuts() !void {
    var shortcuts_arg_buf: [2048]u8 = undefined;
    var pos: usize = 0;

    shortcuts_arg_buf[0] = '[';
    pos = 1;

    var first = true;
    for (&registrations) |*slot| {
        if (slot.*) |reg| {
            if (!first) {
                if (pos + 2 > shortcuts_arg_buf.len) return HotkeyError.RegistrationFailed;
                @memcpy(shortcuts_arg_buf[pos..][0..2], ", ");
                pos += 2;
            }
            first = false;

            var trigger_buf: [128]u8 = undefined;
            const trigger = buildTriggerString(reg.modifiers, reg.key, &trigger_buf) orelse
                return HotkeyError.RegistrationFailed;

            const entry = std.fmt.bufPrint(shortcuts_arg_buf[pos..], "('fulton-{d}', {{'description': <'Fulton hotkey {d}'>, 'preferred_trigger': <'{s}'>}})", .{
                reg.id, reg.id, trigger,
            }) catch return HotkeyError.RegistrationFailed;
            pos += entry.len;
        }
    }

    if (pos + 1 >= shortcuts_arg_buf.len) return HotkeyError.RegistrationFailed;
    shortcuts_arg_buf[pos] = ']';
    pos += 1;
    shortcuts_arg_buf[pos] = 0;

    const session_path_z = blk: {
        if (portal_session_handle_len >= portal_session_handle.len) return HotkeyError.RegistrationFailed;
        portal_session_handle[portal_session_handle_len] = 0;
        break :blk @as([*:0]const u8, @ptrCast(&portal_session_handle));
    };

    var out_buf: [4096]u8 = undefined;
    const argv = [_]?[*:0]const u8{
        "/usr/bin/gdbus",
        "call",
        "--session",
        "--dest", "org.freedesktop.portal.Desktop",
        "--object-path", "/org/freedesktop/portal/desktop",
        "--method", "org.freedesktop.portal.GlobalShortcuts.BindShortcuts",
        session_path_z,
        @ptrCast(&shortcuts_arg_buf),
        "",
        "{}",
        null,
    };
    _ = runGdbus(@constCast(&argv), &out_buf) orelse {
        return HotkeyError.RegistrationFailed;
    };
}

fn portalRun() !void {
    var pipe_fds: [2]c_int = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return HotkeyError.RunLoopFailed;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        return HotkeyError.RunLoopFailed;
    }

    if (pid == 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], 1);
        _ = std.c.close(pipe_fds[1]);
        const argv = [_]?[*:0]const u8{
            "/usr/bin/gdbus",
            "monitor",
            "--session",
            "--dest", "org.freedesktop.portal.Desktop",
            "--object-path", "/org/freedesktop/portal/desktop",
            null,
        };
        _ = std.c.execve(
            "/usr/bin/gdbus",
            @ptrCast(&argv),
            @ptrCast(std.c.environ),
        );
        std.process.exit(127);
    }

    _ = std.c.close(pipe_fds[1]);
    portal_monitor_pid = pid;
    portal_monitor_fd = pipe_fds[0];

    should_stop.store(false, .release);

    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    while (!should_stop.load(.acquire)) {
        var pfd = [_]std.c.pollfd{.{
            .fd = portal_monitor_fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        const poll_ret = std.c.poll(&pfd, 1, 500);
        if (poll_ret <= 0) continue;

        const n = std.c.read(portal_monitor_fd, @ptrCast(line_buf[line_len..].ptr), line_buf.len - line_len);
        if (n <= 0) break;
        line_len += @intCast(n);

        while (std.mem.indexOf(u8, line_buf[0..line_len], "\n")) |newline_pos| {
            const line = line_buf[0..newline_pos];

            if (std.mem.indexOf(u8, line, "GlobalShortcuts.Activated") != null) {
                for (&registrations) |*slot| {
                    if (slot.*) |reg| {
                        var id_buf: [32]u8 = undefined;
                        const id_str = std.fmt.bufPrint(&id_buf, "fulton-{d}", .{reg.id}) catch continue;
                        if (std.mem.indexOf(u8, line, id_str) != null) {
                            reg.callback(reg.userdata);
                            break;
                        }
                    }
                }
            }

            const remaining = line_len - newline_pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, &line_buf, line_buf[newline_pos + 1 .. line_len]);
            }
            line_len = remaining;
        }
    }

    _ = std.c.kill(portal_monitor_pid, .TERM);
    _ = std.c.close(portal_monitor_fd);
    var status: c_int = 0;
    _ = std.c.waitpid(portal_monitor_pid, &status, 0);
    portal_monitor_pid = 0;
    portal_monitor_fd = -1;
}

// ===========================================================================
// X11 backend — works on native X11 sessions
// ===========================================================================

const Display = opaque {};
const Window_ = c_ulong;
const KeyCode_ = u8;
const KeySym = c_ulong;

const XEvent = extern struct {
    type: c_int,
    pad: [23]c_long,
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window_,
    root: Window_,
    subwindow: Window_,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

const KeyPress_: c_int = 2;
const ShiftMask: c_uint = 1 << 0;
const LockMask: c_uint = 1 << 1;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3;
const Mod2Mask: c_uint = 1 << 4;
const Mod3Mask: c_uint = 1 << 5;
const Mod4Mask: c_uint = 1 << 6;
const GrabModeAsync: c_int = 1;

// X11 function pointers loaded at runtime via dlopen
const X11Fns = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) Window_,
    XKeysymToKeycode: *const fn (*Display, KeySym) callconv(.c) KeyCode_,
    XGrabKey: *const fn (*Display, c_int, c_uint, Window_, c_int, c_int, c_int) callconv(.c) c_int,
    XUngrabKey: *const fn (*Display, c_int, c_uint, Window_) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int,
    XSync: *const fn (*Display, c_int) callconv(.c) c_int,
};

var x11_fns: ?X11Fns = null;
var x11_lib: ?*anyopaque = null;

fn loadX11() bool {
    if (x11_fns != null) return true;

    const handle = std.c.dlopen("libX11.so.6", .{ .LAZY = true }) orelse
        std.c.dlopen("libX11.so", .{ .LAZY = true }) orelse
        return false;

    x11_fns = .{
        .XOpenDisplay = @ptrCast(@alignCast(std.c.dlsym(handle, "XOpenDisplay") orelse return false)),
        .XCloseDisplay = @ptrCast(@alignCast(std.c.dlsym(handle, "XCloseDisplay") orelse return false)),
        .XDefaultRootWindow = @ptrCast(@alignCast(std.c.dlsym(handle, "XDefaultRootWindow") orelse return false)),
        .XKeysymToKeycode = @ptrCast(@alignCast(std.c.dlsym(handle, "XKeysymToKeycode") orelse return false)),
        .XGrabKey = @ptrCast(@alignCast(std.c.dlsym(handle, "XGrabKey") orelse return false)),
        .XUngrabKey = @ptrCast(@alignCast(std.c.dlsym(handle, "XUngrabKey") orelse return false)),
        .XNextEvent = @ptrCast(@alignCast(std.c.dlsym(handle, "XNextEvent") orelse return false)),
        .XSync = @ptrCast(@alignCast(std.c.dlsym(handle, "XSync") orelse return false)),
    };
    x11_lib = handle;
    return true;
}

var x11_display: ?*Display = null;
var x11_root: Window_ = 0;

const XK_a: KeySym = 0x0061;
const XK_0: KeySym = 0x0030;
const XK_F1: KeySym = 0xFFBE;
const XK_space: KeySym = 0x0020;
const XK_Return: KeySym = 0xFF0D;
const XK_Tab: KeySym = 0xFF09;
const XK_Escape: KeySym = 0xFF1B;
const XK_BackSpace: KeySym = 0xFF08;
const XK_Delete: KeySym = 0xFFFF;
const XK_Up: KeySym = 0xFF52;
const XK_Down: KeySym = 0xFF54;
const XK_Left: KeySym = 0xFF51;
const XK_Right: KeySym = 0xFF53;
const XK_Home: KeySym = 0xFF50;
const XK_End: KeySym = 0xFF57;
const XK_Page_Up: KeySym = 0xFF55;
const XK_Page_Down: KeySym = 0xFF56;

fn keyToKeySym(key: hotkey.Key) KeySym {
    return switch (key) {
        .a => XK_a + 0, .b => XK_a + 1, .c => XK_a + 2, .d => XK_a + 3,
        .e => XK_a + 4, .f => XK_a + 5, .g => XK_a + 6, .h => XK_a + 7,
        .i => XK_a + 8, .j => XK_a + 9, .k => XK_a + 10, .l => XK_a + 11,
        .m => XK_a + 12, .n => XK_a + 13, .o => XK_a + 14, .p => XK_a + 15,
        .q => XK_a + 16, .r => XK_a + 17, .s => XK_a + 18, .t => XK_a + 19,
        .u => XK_a + 20, .v => XK_a + 21, .w => XK_a + 22, .x => XK_a + 23,
        .y => XK_a + 24, .z => XK_a + 25,
        .@"0" => XK_0 + 0, .@"1" => XK_0 + 1, .@"2" => XK_0 + 2,
        .@"3" => XK_0 + 3, .@"4" => XK_0 + 4, .@"5" => XK_0 + 5,
        .@"6" => XK_0 + 6, .@"7" => XK_0 + 7, .@"8" => XK_0 + 8,
        .@"9" => XK_0 + 9,
        .f1 => XK_F1, .f2 => XK_F1 + 1, .f3 => XK_F1 + 2, .f4 => XK_F1 + 3,
        .f5 => XK_F1 + 4, .f6 => XK_F1 + 5, .f7 => XK_F1 + 6, .f8 => XK_F1 + 7,
        .f9 => XK_F1 + 8, .f10 => XK_F1 + 9, .f11 => XK_F1 + 10, .f12 => XK_F1 + 11,
        .space => XK_space, .@"return" => XK_Return, .tab => XK_Tab,
        .escape => XK_Escape, .backspace => XK_BackSpace, .delete => XK_Delete,
        .up => XK_Up, .down => XK_Down, .left => XK_Left, .right => XK_Right,
        .home => XK_Home, .end => XK_End, .page_up => XK_Page_Up, .page_down => XK_Page_Down,
    };
}

fn modsToX11Mask(mods: hotkey.Modifier) c_uint {
    var mask: c_uint = 0;
    if (mods.cmd) mask |= Mod4Mask;
    if (mods.ctrl) mask |= ControlMask;
    if (mods.alt) mask |= Mod1Mask;
    if (mods.shift) mask |= ShiftMask;
    return mask;
}

const lock_masks = [_]c_uint{
    0, LockMask, Mod2Mask, LockMask | Mod2Mask,
    Mod3Mask, LockMask | Mod3Mask, Mod2Mask | Mod3Mask,
    LockMask | Mod2Mask | Mod3Mask,
};

fn x11Register(modifiers: hotkey.Modifier, key: hotkey.Key, idx: usize, id: u32, callback: HotkeyCallback, userdata: ?*anyopaque) !void {
    const fns = x11_fns orelse return HotkeyError.RunLoopFailed;

    if (x11_display == null) {
        x11_display = fns.XOpenDisplay(null) orelse return HotkeyError.RunLoopFailed;
        x11_root = fns.XDefaultRootWindow(x11_display.?);
    }
    const dpy = x11_display.?;

    const keysym = keyToKeySym(key);
    const keycode = fns.XKeysymToKeycode(dpy, keysym);
    const x11_mods = modsToX11Mask(modifiers);

    if (keycode == 0) return HotkeyError.RegistrationFailed;

    for (lock_masks) |lock| {
        _ = fns.XGrabKey(dpy, @intCast(keycode), x11_mods | lock, x11_root, 0, GrabModeAsync, GrabModeAsync);
    }
    _ = fns.XSync(dpy, 0);

    registrations[idx] = .{
        .id = id, .modifiers = modifiers, .key = key,
        .callback = callback, .userdata = userdata,
        .x11_keycode = keycode, .x11_mods = x11_mods,
    };
}

fn x11Run() !void {
    const fns = x11_fns orelse return HotkeyError.RunLoopFailed;
    if (x11_display == null) return HotkeyError.RunLoopFailed;
    const dpy = x11_display.?;

    should_stop.store(false, .release);

    while (!should_stop.load(.acquire)) {
        var event: XEvent = undefined;
        _ = fns.XNextEvent(dpy, &event);

        if (event.type == KeyPress_) {
            const key_event: *const XKeyEvent = @ptrCast(&event);
            const keycode = key_event.keycode;
            const clean_state = key_event.state & ~@as(c_uint, LockMask | Mod2Mask | Mod3Mask);

            for (&registrations) |*slot| {
                if (slot.*) |reg| {
                    if (keycode == reg.x11_keycode and clean_state == reg.x11_mods) {
                        reg.callback(reg.userdata);
                        break;
                    }
                }
            }
        }
    }
}

// ===========================================================================
// Public API — dispatches to appropriate backend
// ===========================================================================

pub fn register(
    modifiers: hotkey.Modifier,
    key: hotkey.Key,
    callback: HotkeyCallback,
    userdata: ?*anyopaque,
    backend: Backend,
) !HotkeyHandle {
    _ = backend;

    var slot_idx: ?usize = null;
    for (&registrations, 0..) |*slot, idx| {
        if (slot.* == null) {
            slot_idx = idx;
            break;
        }
    }
    const idx = slot_idx orelse return HotkeyError.TooManyHotkeys;

    const id = next_id;
    next_id += 1;

    // Decide backend on first registration.
    // Priority: 1) D-Bus portal (no perms, modern desktops)
    //           2) X11 XGrabKey (no perms, X11 sessions)
    //           3) evdev (needs input group, works everywhere)
    if (active_backend == .none) {
        const wayland = isWayland();
        std.debug.print("backend: isWayland={}\n", .{wayland});

        // 1) Try D-Bus portal (modern Wayland desktops, no perms needed)
        if (wayland and portalCheckAvailable()) {
            std.debug.print("backend: portal available, creating session\n", .{});
            active_backend = .portal;
            portalCreateSession() catch {
                std.debug.print("backend: portal session failed, falling back\n", .{});
                active_backend = .none;
            };
        }

        // 2) Try evdev (needs root or input group, but works everywhere
        //    including Wayland where XGrabKey is useless)
        if (active_backend == .none) {
            const test_fd = std.c.open("/dev/input/event0", @bitCast(std.c.O{ .ACCMODE = .RDONLY }), @as(c_uint, 0));
            if (test_fd >= 0) {
                _ = std.c.close(test_fd);
                std.debug.print("backend: using evdev\n", .{});
                active_backend = .evdev;
            }
        }

        // 3) Try X11 (only on confirmed X11 sessions — XGrabKey on XWayland
        //    can't intercept global keys)
        if (active_backend == .none and !wayland and loadX11()) {
            std.debug.print("backend: using X11\n", .{});
            active_backend = .x11;
        }

        if (active_backend == .none) {
            std.debug.print("backend: no backend available\n", .{});
            return HotkeyError.RunLoopFailed;
        }

        std.debug.print("backend: selected {s}\n", .{@tagName(active_backend)});
    }

    switch (active_backend) {
        .x11 => try x11Register(modifiers, key, idx, id, callback, userdata),
        .evdev, .portal => {
            registrations[idx] = .{
                .id = id, .modifiers = modifiers, .key = key,
                .callback = callback, .userdata = userdata,
                .x11_keycode = 0, .x11_mods = 0,
            };
        },
        .none => unreachable,
    }

    return HotkeyHandle{ .id = id };
}

pub fn unregister(handle: HotkeyHandle) void {
    for (&registrations) |*slot| {
        if (slot.*) |reg| {
            if (reg.id == handle.id) {
                if (active_backend == .x11) {
                    if (x11_fns) |fns| {
                        if (x11_display) |dpy| {
                            for (lock_masks) |lock| {
                                _ = fns.XUngrabKey(dpy, @intCast(reg.x11_keycode), reg.x11_mods | lock, x11_root);
                            }
                        }
                    }
                }
                slot.* = null;
                return;
            }
        }
    }
}

pub fn run() !void {
    if (active_backend == .portal) {
        try portalBindShortcuts();
    }

    switch (active_backend) {
        .x11 => try x11Run(),
        .evdev => try evdevRun(),
        .portal => try portalRun(),
        .none => return HotkeyError.RunLoopFailed,
    }
}

pub fn stop() void {
    should_stop.store(true, .release);
}
