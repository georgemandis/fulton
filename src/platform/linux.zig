const std = @import("std");
const hotkey = @import("../hotkey.zig");

// ---------------------------------------------------------------------------
// Public types (shared by both backends)
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
    // X11-specific (only used when X11 backend is active)
    x11_keycode: u8,
    x11_mods: c_uint,
};

var registrations: [MAX_HOTKEYS]?Registration = [_]?Registration{null} ** MAX_HOTKEYS;
var next_id: u32 = 1;
var active_backend: enum { none, x11, evdev } = .none;
var should_stop: std.atomic.Value(bool) = .init(false);

// ---------------------------------------------------------------------------
// Backend detection
// ---------------------------------------------------------------------------

fn isWayland() bool {
    // Check XDG_SESSION_TYPE first
    if (std.c.getenv("XDG_SESSION_TYPE")) |s| {
        const slice = std.mem.sliceTo(s, 0);
        if (std.mem.eql(u8, slice, "wayland")) return true;
        if (std.mem.eql(u8, slice, "x11")) return false;
    }
    // Check WAYLAND_DISPLAY (set even under sudo -E)
    if (std.c.getenv("WAYLAND_DISPLAY") != null) return true;
    // If DISPLAY is set but not WAYLAND_DISPLAY, assume X11
    if (std.c.getenv("DISPLAY") != null) return false;
    // No display info — default to evdev (works everywhere)
    return true;
}

// ===========================================================================
// evdev backend — works on Wayland, X11, and TTY
// ===========================================================================

// Linux input event structures and constants
const EV_KEY: u16 = 0x01;
const EV_SYN: u16 = 0x00;

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

// ioctl constants for evdev
const EVIOCGBIT = 0x80404520; // EVIOCGBIT(0, sizeof(long))
// For checking EV_KEY capability, we use EVIOCGBIT(EV_KEY, KEY_MAX/8)
// But simpler: just try to read events and check if keyboard-like keys appear.
// Actually, let's use the /sys/class/input approach to find keyboards.

fn keyToEvdev(key: hotkey.Key) u16 {
    return switch (key) {
        .a => KEY_A,
        .b => KEY_B,
        .c => KEY_C,
        .d => KEY_D,
        .e => KEY_E,
        .f => KEY_F,
        .g => KEY_G,
        .h => KEY_H,
        .i => KEY_I,
        .j => KEY_J,
        .k => KEY_K,
        .l => KEY_L,
        .m => KEY_M,
        .n => KEY_N,
        .o => KEY_O,
        .p => KEY_P,
        .q => KEY_Q,
        .r => KEY_R,
        .s => KEY_S,
        .t => KEY_T,
        .u => KEY_U,
        .v => KEY_V,
        .w => KEY_W,
        .x => KEY_X,
        .y => KEY_Y,
        .z => KEY_Z,
        .@"0" => KEY_0,
        .@"1" => KEY_1,
        .@"2" => KEY_2,
        .@"3" => KEY_3,
        .@"4" => KEY_4,
        .@"5" => KEY_5,
        .@"6" => KEY_6,
        .@"7" => KEY_7,
        .@"8" => KEY_8,
        .@"9" => KEY_9,
        .f1 => KEY_F1,
        .f2 => KEY_F2,
        .f3 => KEY_F3,
        .f4 => KEY_F4,
        .f5 => KEY_F5,
        .f6 => KEY_F6,
        .f7 => KEY_F7,
        .f8 => KEY_F8,
        .f9 => KEY_F9,
        .f10 => KEY_F10,
        .f11 => KEY_F11,
        .f12 => KEY_F12,
        .space => KEY_SPACE,
        .@"return" => KEY_ENTER,
        .tab => KEY_TAB,
        .escape => KEY_ESC,
        .backspace => KEY_BACKSPACE,
        .delete => KEY_DELETE,
        .up => KEY_UP,
        .down => KEY_DOWN,
        .left => KEY_LEFT,
        .right => KEY_RIGHT,
        .home => KEY_HOME,
        .end => KEY_END,
        .page_up => KEY_PAGEUP,
        .page_down => KEY_PAGEDOWN,
    };
}

fn isModifierKey(code: u16) bool {
    return code == KEY_LEFTCTRL or code == KEY_RIGHTCTRL or
        code == KEY_LEFTSHIFT or code == KEY_RIGHTSHIFT or
        code == KEY_LEFTALT or code == KEY_RIGHTALT or
        code == KEY_LEFTMETA or code == KEY_RIGHTMETA;
}

// Track current modifier state
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
    // Open all /dev/input/event* devices we have permission to read.
    // We don't filter by capability — the event loop just ignores
    // non-keyboard events (mice, touchpads, etc). This avoids fragile
    // ioctl calls that vary across kernel/libc/Zig versions.
    var path_buf: [32]u8 = undefined;
    for (0..32) |i| {
        const path = std.fmt.bufPrint(&path_buf, "/dev/input/event{}\x00", .{i}) catch continue;
        const path_z: [*:0]const u8 = @ptrCast(path.ptr);
        const fd = std.c.open(path_z, @bitCast(std.c.O{ .ACCMODE = .RDONLY, .NONBLOCK = true }), @as(c_uint, 0));
        if (fd >= 0) {
            if (evdev_count < MAX_EVDEV_FDS) {
                std.debug.print("fulton: opened input device: /dev/input/event{}\n", .{i});
                evdev_fds[evdev_count] = fd;
                evdev_count += 1;
            } else {
                _ = std.c.close(fd);
            }
        }
    }

    if (evdev_count == 0) {
        std.debug.print("fulton: no input devices found in /dev/input/\n", .{});
        std.debug.print("fulton: ensure user is in 'input' group: sudo usermod -aG input $USER\n", .{});
        return HotkeyError.RunLoopFailed;
    }
}

fn evdevRun() !void {
    try openInputDevices();

    should_stop.store(false, .release);
    std.debug.print("fulton: entering evdev event loop ({} device(s))\n", .{evdev_count});

    // Build pollfd array
    var pollfds: [MAX_EVDEV_FDS]std.c.pollfd = undefined;
    for (0..evdev_count) |i| {
        pollfds[i] = .{
            .fd = evdev_fds[i],
            .events = std.c.POLL.IN,
            .revents = 0,
        };
    }

    while (!should_stop.load(.acquire)) {
        const poll_ret = std.c.poll(&pollfds, @intCast(evdev_count), 500); // 500ms timeout
        if (poll_ret <= 0) continue;

        for (0..evdev_count) |i| {
            if (pollfds[i].revents & std.c.POLL.IN == 0) continue;

            var ev: InputEvent = undefined;
            const bytes_read = std.c.read(evdev_fds[i], @ptrCast(&ev), @sizeOf(InputEvent));
            if (bytes_read != @sizeOf(InputEvent)) continue;

            if (ev.type != EV_KEY) continue;

            const pressed = ev.value == 1; // 1 = press, 0 = release, 2 = repeat

            // Update modifier state
            if (isModifierKey(ev.code)) {
                updateModState(ev.code, pressed);
                continue;
            }

            // Only fire on key press (not repeat or release)
            if (!pressed) continue;

            // Check against registrations
            for (&registrations) |*slot| {
                if (slot.*) |reg| {
                    const expected_evdev = keyToEvdev(reg.key);
                    if (ev.code != expected_evdev) continue;

                    // Check modifiers
                    if (reg.modifiers.ctrl != mod_ctrl) continue;
                    if (reg.modifiers.shift != mod_shift) continue;
                    if (reg.modifiers.alt != mod_alt) continue;
                    if (reg.modifiers.cmd != mod_super) continue;

                    std.debug.print("fulton: evdev match! firing callback\n", .{});
                    reg.callback(reg.userdata);
                    break;
                }
            }
        }
    }

    // Close all fds
    for (0..evdev_count) |i| {
        _ = std.c.close(evdev_fds[i]);
        evdev_fds[i] = -1;
    }
    evdev_count = 0;
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

extern "X11" fn XOpenDisplay(display_name: ?[*:0]const u8) ?*Display;
extern "X11" fn XCloseDisplay(display: *Display) c_int;
extern "X11" fn XDefaultRootWindow(display: *Display) Window_;
extern "X11" fn XKeysymToKeycode(display: *Display, keysym: KeySym) KeyCode_;
extern "X11" fn XGrabKey(display: *Display, keycode: c_int, modifiers: c_uint, grab_window: Window_, owner_events: c_int, pointer_mode: c_int, keyboard_mode: c_int) c_int;
extern "X11" fn XUngrabKey(display: *Display, keycode: c_int, modifiers: c_uint, grab_window: Window_) c_int;
extern "X11" fn XNextEvent(display: *Display, event_return: *XEvent) c_int;
extern "X11" fn XSync(display: *Display, discard: c_int) c_int;

var x11_display: ?*Display = null;
var x11_root: Window_ = 0;

// X11 KeySym values
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
    0,
    LockMask,
    Mod2Mask,
    LockMask | Mod2Mask,
    Mod3Mask,
    LockMask | Mod3Mask,
    Mod2Mask | Mod3Mask,
    LockMask | Mod2Mask | Mod3Mask,
};

fn x11Register(modifiers: hotkey.Modifier, key: hotkey.Key, idx: usize, id: u32, callback: HotkeyCallback, userdata: ?*anyopaque) !void {
    if (x11_display == null) {
        x11_display = XOpenDisplay(null) orelse {
            std.debug.print("fulton: failed to open X11 display\n", .{});
            return HotkeyError.RunLoopFailed;
        };
        x11_root = XDefaultRootWindow(x11_display.?);
    }
    const dpy = x11_display.?;

    const keysym = keyToKeySym(key);
    const keycode = XKeysymToKeycode(dpy, keysym);
    const x11_mods = modsToX11Mask(modifiers);

    if (keycode == 0) return HotkeyError.RegistrationFailed;

    for (lock_masks) |lock| {
        _ = XGrabKey(dpy, @intCast(keycode), x11_mods | lock, x11_root, 0, GrabModeAsync, GrabModeAsync);
    }
    _ = XSync(dpy, 0);

    registrations[idx] = .{
        .id = id,
        .modifiers = modifiers,
        .key = key,
        .callback = callback,
        .userdata = userdata,
        .x11_keycode = keycode,
        .x11_mods = x11_mods,
    };
}

fn x11Run() !void {
    if (x11_display == null) return HotkeyError.RunLoopFailed;
    const dpy = x11_display.?;

    should_stop.store(false, .release);

    while (!should_stop.load(.acquire)) {
        var event: XEvent = undefined;
        _ = XNextEvent(dpy, &event);

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
    // Strategy: try evdev first (works on Wayland, X11, and TTY).
    // Fall back to X11 XGrabKey if /dev/input is not accessible.
    if (active_backend == .none) {
        // Quick check: can we open any /dev/input/event* device?
        var can_evdev = false;
        const test_fd = std.c.open("/dev/input/event0", @bitCast(std.c.O{ .ACCMODE = .RDONLY }), @as(c_uint, 0));
        if (test_fd >= 0) {
            _ = std.c.close(test_fd);
            can_evdev = true;
        }

        if (can_evdev) {
            std.debug.print("fulton: using evdev backend (/dev/input accessible)\n", .{});
            active_backend = .evdev;
        } else if (!isWayland()) {
            std.debug.print("fulton: using X11 backend (no /dev/input access, X11 session)\n", .{});
            active_backend = .x11;
        } else {
            std.debug.print("fulton: error: Wayland session but /dev/input not accessible\n", .{});
            std.debug.print("fulton: add user to 'input' group: sudo usermod -aG input $USER\n", .{});
            std.debug.print("fulton: (log out and back in for group change to take effect)\n", .{});
            return HotkeyError.RunLoopFailed;
        }
    }

    switch (active_backend) {
        .x11 => try x11Register(modifiers, key, idx, id, callback, userdata),
        .evdev => {
            // evdev doesn't need per-key registration — just store the registration
            registrations[idx] = .{
                .id = id,
                .modifiers = modifiers,
                .key = key,
                .callback = callback,
                .userdata = userdata,
                .x11_keycode = 0,
                .x11_mods = 0,
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
                    if (x11_display) |dpy| {
                        for (lock_masks) |lock| {
                            _ = XUngrabKey(dpy, @intCast(reg.x11_keycode), reg.x11_mods | lock, x11_root);
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
    switch (active_backend) {
        .x11 => try x11Run(),
        .evdev => try evdevRun(),
        .none => return HotkeyError.RunLoopFailed,
    }
}

pub fn stop() void {
    should_stop.store(true, .release);
}
