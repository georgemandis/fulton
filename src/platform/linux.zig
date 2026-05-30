const std = @import("std");
const hotkey = @import("../hotkey.zig");

// ---------------------------------------------------------------------------
// X11 extern declarations (libX11)
// ---------------------------------------------------------------------------

const Display = opaque {};
const Window = c_ulong;
const KeyCode = u8;
const KeySym = c_ulong;
const XID = c_ulong;
const Atom = c_ulong;
const Bool = c_int;
const Status = c_int;
const Time = c_ulong;

const XEvent = extern struct {
    type: c_int,
    pad: [23]c_long, // XEvent is a union; 24 longs total covers all variants
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};

// X11 event types
const KeyPress_: c_int = 2;

// X11 modifier masks
const ShiftMask: c_uint = 1 << 0;
const LockMask: c_uint = 1 << 1; // CapsLock
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3; // Alt
const Mod2Mask: c_uint = 1 << 4; // NumLock
const Mod3Mask: c_uint = 1 << 5; // ScrollLock (sometimes)
const Mod4Mask: c_uint = 1 << 6; // Super/Win/Cmd

const GrabModeAsync: c_int = 1;
const AnyModifier: c_uint = 1 << 15;

extern "X11" fn XOpenDisplay(display_name: ?[*:0]const u8) ?*Display;
extern "X11" fn XCloseDisplay(display: *Display) c_int;
extern "X11" fn XDefaultRootWindow(display: *Display) Window;
extern "X11" fn XKeysymToKeycode(display: *Display, keysym: KeySym) KeyCode;
extern "X11" fn XGrabKey(
    display: *Display,
    keycode: c_int,
    modifiers: c_uint,
    grab_window: Window,
    owner_events: Bool,
    pointer_mode: c_int,
    keyboard_mode: c_int,
) c_int;
extern "X11" fn XUngrabKey(
    display: *Display,
    keycode: c_int,
    modifiers: c_uint,
    grab_window: Window,
) c_int;
extern "X11" fn XNextEvent(display: *Display, event_return: *XEvent) c_int;
extern "X11" fn XSync(display: *Display, discard: Bool) c_int;
extern "X11" fn XConnectionNumber(display: *Display) c_int;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const HotkeyError = error{
    RegistrationFailed,
    TooManyHotkeys,
    EventTapDenied,
    RunLoopFailed,
};

pub const Backend = enum {
    /// XGrabKey — the only X11 approach. Already does passive grabs.
    simple,
    /// Same as simple on Linux/X11. Reserved for future Wayland portal support.
    advanced,
};

pub const HotkeyHandle = struct {
    id: u32,
};

pub const HotkeyCallback = *const fn (userdata: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// Registration state
// ---------------------------------------------------------------------------

const MAX_HOTKEYS = 64;

const Registration = struct {
    id: u32,
    modifiers: hotkey.Modifier,
    key: hotkey.Key,
    keycode: KeyCode,
    x11_mods: c_uint,
    callback: HotkeyCallback,
    userdata: ?*anyopaque,
};

var registrations: [MAX_HOTKEYS]?Registration = [_]?Registration{null} ** MAX_HOTKEYS;
var next_id: u32 = 1;
var display: ?*Display = null;
var root_window: Window = 0;
var should_stop: std.atomic.Value(bool) = .init(false);

// ---------------------------------------------------------------------------
// Key code mapping (Fulton Key -> X11 KeySym)
// ---------------------------------------------------------------------------

// X11 KeySym values from X11/keysymdef.h
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
        .a => XK_a + 0,
        .b => XK_a + 1,
        .c => XK_a + 2,
        .d => XK_a + 3,
        .e => XK_a + 4,
        .f => XK_a + 5,
        .g => XK_a + 6,
        .h => XK_a + 7,
        .i => XK_a + 8,
        .j => XK_a + 9,
        .k => XK_a + 10,
        .l => XK_a + 11,
        .m => XK_a + 12,
        .n => XK_a + 13,
        .o => XK_a + 14,
        .p => XK_a + 15,
        .q => XK_a + 16,
        .r => XK_a + 17,
        .s => XK_a + 18,
        .t => XK_a + 19,
        .u => XK_a + 20,
        .v => XK_a + 21,
        .w => XK_a + 22,
        .x => XK_a + 23,
        .y => XK_a + 24,
        .z => XK_a + 25,
        .@"0" => XK_0 + 0,
        .@"1" => XK_0 + 1,
        .@"2" => XK_0 + 2,
        .@"3" => XK_0 + 3,
        .@"4" => XK_0 + 4,
        .@"5" => XK_0 + 5,
        .@"6" => XK_0 + 6,
        .@"7" => XK_0 + 7,
        .@"8" => XK_0 + 8,
        .@"9" => XK_0 + 9,
        .f1 => XK_F1 + 0,
        .f2 => XK_F1 + 1,
        .f3 => XK_F1 + 2,
        .f4 => XK_F1 + 3,
        .f5 => XK_F1 + 4,
        .f6 => XK_F1 + 5,
        .f7 => XK_F1 + 6,
        .f8 => XK_F1 + 7,
        .f9 => XK_F1 + 8,
        .f10 => XK_F1 + 9,
        .f11 => XK_F1 + 10,
        .f12 => XK_F1 + 11,
        .space => XK_space,
        .@"return" => XK_Return,
        .tab => XK_Tab,
        .escape => XK_Escape,
        .backspace => XK_BackSpace,
        .delete => XK_Delete,
        .up => XK_Up,
        .down => XK_Down,
        .left => XK_Left,
        .right => XK_Right,
        .home => XK_Home,
        .end => XK_End,
        .page_up => XK_Page_Up,
        .page_down => XK_Page_Down,
    };
}

fn modsToX11Mask(mods: hotkey.Modifier) c_uint {
    var mask: c_uint = 0;
    if (mods.cmd) mask |= Mod4Mask; // Super
    if (mods.ctrl) mask |= ControlMask;
    if (mods.alt) mask |= Mod1Mask;
    if (mods.shift) mask |= ShiftMask;
    return mask;
}

/// The NumLock/CapsLock/ScrollLock problem: X11 treats lock keys as modifiers.
/// We must grab all 8 combinations of the 3 lock modifiers for each hotkey.
const lock_masks = [_]c_uint{
    0,
    LockMask, // CapsLock
    Mod2Mask, // NumLock
    LockMask | Mod2Mask,
    Mod3Mask, // ScrollLock
    LockMask | Mod3Mask,
    Mod2Mask | Mod3Mask,
    LockMask | Mod2Mask | Mod3Mask,
};

fn ensureDisplay() !void {
    if (display != null) return;
    display = XOpenDisplay(null) orelse return HotkeyError.RunLoopFailed;
    root_window = XDefaultRootWindow(display.?);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn register(
    modifiers: hotkey.Modifier,
    key: hotkey.Key,
    callback: HotkeyCallback,
    userdata: ?*anyopaque,
    backend: Backend,
) !HotkeyHandle {
    _ = backend; // both modes use XGrabKey on X11

    try ensureDisplay();
    const dpy = display.?;

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

    const keysym = keyToKeySym(key);
    const keycode = XKeysymToKeycode(dpy, keysym);
    const x11_mods = modsToX11Mask(modifiers);

    // Grab all 8 lock-modifier variants
    for (lock_masks) |lock| {
        _ = XGrabKey(
            dpy,
            @intCast(keycode),
            x11_mods | lock,
            root_window,
            0, // owner_events = False
            GrabModeAsync,
            GrabModeAsync,
        );
    }
    _ = XSync(dpy, 0);

    registrations[idx] = .{
        .id = id,
        .modifiers = modifiers,
        .key = key,
        .keycode = keycode,
        .x11_mods = x11_mods,
        .callback = callback,
        .userdata = userdata,
    };

    return HotkeyHandle{ .id = id };
}

pub fn unregister(handle: HotkeyHandle) void {
    const dpy = display orelse return;

    for (&registrations) |*slot| {
        if (slot.*) |reg| {
            if (reg.id == handle.id) {
                for (lock_masks) |lock| {
                    _ = XUngrabKey(
                        dpy,
                        @intCast(reg.keycode),
                        reg.x11_mods | lock,
                        root_window,
                    );
                }
                slot.* = null;
                return;
            }
        }
    }
}

pub fn run() !void {
    try ensureDisplay();
    const dpy = display.?;

    should_stop.store(false, .release);

    while (!should_stop.load(.acquire)) {
        var event: XEvent = undefined;
        _ = XNextEvent(dpy, &event);

        if (event.type == KeyPress_) {
            const key_event: *const XKeyEvent = @ptrCast(&event);
            const keycode = key_event.keycode;
            // Strip lock modifiers for comparison
            const clean_state = key_event.state & ~@as(c_uint, LockMask | Mod2Mask | Mod3Mask);

            for (&registrations) |*slot| {
                if (slot.*) |reg| {
                    if (keycode == reg.keycode and clean_state == reg.x11_mods) {
                        reg.callback(reg.userdata);
                        break;
                    }
                }
            }
        }
    }
}

pub fn stop() void {
    should_stop.store(true, .release);
    // Note: XNextEvent blocks. A full implementation would use
    // XConnectionNumber + poll/select, or send a synthetic event
    // to wake the loop. For now, the next real X event will break out.
}
