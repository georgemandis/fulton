const std = @import("std");
const hotkey = @import("../hotkey.zig");

// ---------------------------------------------------------------------------
// Carbon / CoreGraphics / CoreFoundation extern declarations
// ---------------------------------------------------------------------------

// Carbon event types
const EventTargetRef = *opaque {};
const EventHandlerRef = *opaque {};
const EventRef = *opaque {};
const EventHotKeyRef = *opaque {};

const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

const EventTypeSpec = extern struct {
    eventClass: u32,
    eventKind: u32,
};

const OSStatus = i32;

// Carbon constants
const kEventClassKeyboard: u32 = 0x6B657962; // 'keyb'
const kEventHotKeyPressed: u32 = 5;
const noErr: OSStatus = 0;

// Carbon modifier flags (different from CGEvent modifier flags)
const cmdKey: u32 = 0x0100;
const shiftKey: u32 = 0x0200;
const optionKey: u32 = 0x0800;
const controlKey: u32 = 0x1000;

// Carbon event handler callback
const EventHandlerProcPtr = *const fn (
    next_handler: EventHandlerRef,
    event: EventRef,
    user_data: ?*anyopaque,
) callconv(.c) OSStatus;

extern "c" fn GetApplicationEventTarget() EventTargetRef;
extern "c" fn InstallEventHandler(
    target: EventTargetRef,
    handler: EventHandlerProcPtr,
    num_types: u32,
    list: [*]const EventTypeSpec,
    user_data: ?*anyopaque,
    out_ref: ?*EventHandlerRef,
) OSStatus;
extern "c" fn RegisterEventHotKey(
    hot_key_code: u32,
    hot_key_modifiers: u32,
    hot_key_id: EventHotKeyID,
    target: EventTargetRef,
    options: u32,
    out_ref: *EventHotKeyRef,
) OSStatus;
extern "c" fn UnregisterEventHotKey(ref: EventHotKeyRef) OSStatus;
extern "c" fn GetEventParameter(
    event: EventRef,
    name: u32,
    desired_type: u32,
    actual_type: ?*u32,
    buf_size: u32,
    actual_size: ?*u32,
    data: *anyopaque,
) OSStatus;

// CGEvent tap types
const CGEventTapProxy = *opaque {};
const CGEventRef = *opaque {};
const CGEventType = u32;
const CGEventMask = u64;
const CGEventFlags = u64;

const kCGEventKeyDown: u32 = 10;
const kCGEventFlagsChanged: u32 = 12;
const kCGEventTapDisabledByTimeout: u32 = 0xFFFFFFFE;
const kCGEventTapDisabledByUserInput: u32 = 0xFFFFFFFF;

// CGEvent modifier flags
const kCGEventFlagMaskCommand: u64 = 0x00100000;
const kCGEventFlagMaskShift: u64 = 0x00020000;
const kCGEventFlagMaskAlternate: u64 = 0x00080000;
const kCGEventFlagMaskControl: u64 = 0x00040000;

const CGEventTapCallBack = *const fn (
    proxy: CGEventTapProxy,
    event_type: CGEventType,
    event: CGEventRef,
    user_info: ?*anyopaque,
) callconv(.c) ?CGEventRef;

const CFMachPortRef = *opaque {};
const CFRunLoopSourceRef = *opaque {};
const CFRunLoopRef = *opaque {};
const CFStringRef = *const opaque {};
const CFAllocatorRef = ?*opaque {};
const CFIndex = isize;

extern "c" fn CGEventTapCreate(
    tap: u32,
    place: u32,
    options: u32,
    events_of_interest: CGEventMask,
    callback: CGEventTapCallBack,
    user_info: ?*anyopaque,
) ?CFMachPortRef;
extern "c" fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;
extern "c" fn CGEventGetFlags(event: CGEventRef) CGEventFlags;
extern "c" fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) i64;
extern "c" fn CFMachPortCreateRunLoopSource(
    allocator: CFAllocatorRef,
    port: CFMachPortRef,
    order: CFIndex,
) ?CFRunLoopSourceRef;
extern "c" fn CFRunLoopGetMain() CFRunLoopRef;
extern "c" fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRunLoopStop(rl: CFRunLoopRef) void;

// kCGSessionEventTap = 1, kCGHeadInsertEventTap = 0
// kCGEventTapOptionDefault = 0 (active, can swallow), kCGEventTapOptionListenOnly = 1

// Accessibility check
extern "c" fn AXIsProcessTrustedWithOptions(options: ?*const anyopaque) bool;

// CoreFoundation run loop mode
extern "c" var kCFRunLoopCommonModes: CFStringRef;

// kEventParamDirectObject / typeEventHotKeyID
const kEventParamDirectObject: u32 = 0x2D2D2D2D; // '----'
const typeEventHotKeyID: u32 = 0x686B6964; // 'hkid'

// CGEvent field for virtual keycode
const kCGKeyboardEventKeycode: u32 = 9;

// NSApplicationLoad — lightweight init for Carbon event delivery from CLI
extern "c" fn NSApplicationLoad() bool;

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
    /// Carbon RegisterEventHotKey — no permissions needed.
    /// Cannot swallow keys or do modal/contextual hotkeys.
    simple,
    /// CGEventTap — requires Accessibility permission.
    /// Can intercept and swallow keystrokes.
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
    callback: HotkeyCallback,
    userdata: ?*anyopaque,
    backend: Backend,
    // Carbon-specific
    carbon_ref: ?EventHotKeyRef,
};

var registrations: [MAX_HOTKEYS]?Registration = [_]?Registration{null} ** MAX_HOTKEYS;
var next_id: u32 = 1;
var carbon_handler_installed = false;
var event_tap_handle: ?CFMachPortRef = null;

// ---------------------------------------------------------------------------
// Key code mapping (Fulton Key -> macOS virtual keycode)
// ---------------------------------------------------------------------------

fn keyToMacKeycode(key: hotkey.Key) u32 {
    return switch (key) {
        .a => 0x00,
        .s => 0x01,
        .d => 0x02,
        .f => 0x03,
        .h => 0x04,
        .g => 0x05,
        .z => 0x06,
        .x => 0x07,
        .c => 0x08,
        .v => 0x09,
        .b => 0x0B,
        .q => 0x0C,
        .w => 0x0D,
        .e => 0x0E,
        .r => 0x0F,
        .y => 0x10,
        .t => 0x11,
        .@"1" => 0x12,
        .@"2" => 0x13,
        .@"3" => 0x14,
        .@"4" => 0x15,
        .@"6" => 0x16,
        .@"5" => 0x17,
        .@"9" => 0x19,
        .@"7" => 0x1A,
        .@"8" => 0x1C,
        .@"0" => 0x1D,
        .o => 0x1F,
        .u => 0x20,
        .i => 0x22,
        .p => 0x23,
        .l => 0x25,
        .j => 0x26,
        .k => 0x28,
        .n => 0x2D,
        .m => 0x2E,
        .@"return" => 0x24,
        .tab => 0x30,
        .space => 0x31,
        .backspace => 0x33,
        .escape => 0x35,
        .delete => 0x75,
        .f1 => 0x7A,
        .f2 => 0x78,
        .f3 => 0x63,
        .f4 => 0x76,
        .f5 => 0x60,
        .f6 => 0x61,
        .f7 => 0x62,
        .f8 => 0x64,
        .f9 => 0x65,
        .f10 => 0x6D,
        .f11 => 0x67,
        .f12 => 0x6F,
        .up => 0x7E,
        .down => 0x7D,
        .left => 0x7B,
        .right => 0x7C,
        .home => 0x73,
        .end => 0x77,
        .page_up => 0x74,
        .page_down => 0x79,
    };
}

fn modsToCarbonFlags(mods: hotkey.Modifier) u32 {
    var flags: u32 = 0;
    if (mods.cmd) flags |= cmdKey;
    if (mods.shift) flags |= shiftKey;
    if (mods.alt) flags |= optionKey;
    if (mods.ctrl) flags |= controlKey;
    return flags;
}

fn modsToCGEventMask(mods: hotkey.Modifier) CGEventFlags {
    var flags: CGEventFlags = 0;
    if (mods.cmd) flags |= kCGEventFlagMaskCommand;
    if (mods.shift) flags |= kCGEventFlagMaskShift;
    if (mods.alt) flags |= kCGEventFlagMaskAlternate;
    if (mods.ctrl) flags |= kCGEventFlagMaskControl;
    return flags;
}

// ---------------------------------------------------------------------------
// Carbon event handler callback
// ---------------------------------------------------------------------------

fn carbonEventHandler(
    _: EventHandlerRef,
    event: EventRef,
    _: ?*anyopaque,
) callconv(.c) OSStatus {
    var hk_id: EventHotKeyID = undefined;
    const status = GetEventParameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        null,
        @sizeOf(EventHotKeyID),
        null,
        @ptrCast(&hk_id),
    );
    if (status != noErr) return status;

    // Find matching registration and fire callback
    for (&registrations) |*slot| {
        if (slot.*) |reg| {
            if (reg.id == hk_id.id) {
                reg.callback(reg.userdata);
                break;
            }
        }
    }

    return noErr;
}

// ---------------------------------------------------------------------------
// CGEventTap callback
// ---------------------------------------------------------------------------

fn eventTapCallback(
    _: CGEventTapProxy,
    event_type: CGEventType,
    event: CGEventRef,
    _: ?*anyopaque,
) callconv(.c) ?CGEventRef {
    // Re-enable if the tap was disabled by timeout or user
    if (event_type == kCGEventTapDisabledByTimeout or
        event_type == kCGEventTapDisabledByUserInput)
    {
        if (event_tap_handle) |tap| {
            CGEventTapEnable(tap, true);
        }
        return event;
    }

    if (event_type != kCGEventKeyDown) return event;

    const keycode: u32 = @intCast(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
    const flags = CGEventGetFlags(event);

    // Check against all advanced-mode registrations
    for (&registrations) |*slot| {
        if (slot.*) |reg| {
            if (reg.backend != .advanced) continue;

            const expected_keycode = keyToMacKeycode(reg.key);
            if (keycode != expected_keycode) continue;

            const expected_flags = modsToCGEventMask(reg.modifiers);
            // Mask to only the modifier bits we care about
            const relevant_mask = kCGEventFlagMaskCommand | kCGEventFlagMaskShift |
                kCGEventFlagMaskAlternate | kCGEventFlagMaskControl;
            if ((flags & relevant_mask) == expected_flags) {
                reg.callback(reg.userdata);
                return null; // swallow the event
            }
        }
    }

    return event;
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
    // Find a free slot
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

    switch (backend) {
        .simple => {
            // Install Carbon event handler once
            if (!carbon_handler_installed) {
                _ = NSApplicationLoad();

                var event_types = [_]EventTypeSpec{.{
                    .eventClass = kEventClassKeyboard,
                    .eventKind = kEventHotKeyPressed,
                }};
                const status = InstallEventHandler(
                    GetApplicationEventTarget(),
                    &carbonEventHandler,
                    1,
                    &event_types,
                    null,
                    null,
                );
                if (status != noErr) return HotkeyError.RegistrationFailed;
                carbon_handler_installed = true;
            }

            var hot_key_ref: EventHotKeyRef = undefined;
            const status = RegisterEventHotKey(
                keyToMacKeycode(key),
                modsToCarbonFlags(modifiers),
                .{ .signature = 0x464C544E, .id = id }, // 'FLTN'
                GetApplicationEventTarget(),
                0,
                &hot_key_ref,
            );
            if (status != noErr) return HotkeyError.RegistrationFailed;

            registrations[idx] = .{
                .id = id,
                .modifiers = modifiers,
                .key = key,
                .callback = callback,
                .userdata = userdata,
                .backend = .simple,
                .carbon_ref = hot_key_ref,
            };
        },
        .advanced => {
            // Create event tap if not already created
            if (event_tap_handle == null) {
                const mask: CGEventMask = (@as(CGEventMask, 1) << kCGEventKeyDown) |
                    (@as(CGEventMask, 1) << kCGEventFlagsChanged);

                const tap = CGEventTapCreate(
                    1, // kCGSessionEventTap
                    0, // kCGHeadInsertEventTap
                    0, // kCGEventTapOptionDefault (active)
                    mask,
                    &eventTapCallback,
                    null,
                ) orelse return HotkeyError.EventTapDenied;

                const source = CFMachPortCreateRunLoopSource(null, tap, 0) orelse
                    return HotkeyError.RunLoopFailed;

                CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
                CGEventTapEnable(tap, true);
                event_tap_handle = tap;
            }

            registrations[idx] = .{
                .id = id,
                .modifiers = modifiers,
                .key = key,
                .callback = callback,
                .userdata = userdata,
                .backend = .advanced,
                .carbon_ref = null,
            };
        },
    }

    return HotkeyHandle{ .id = id };
}

pub fn unregister(handle: HotkeyHandle) void {
    for (&registrations) |*slot| {
        if (slot.*) |reg| {
            if (reg.id == handle.id) {
                if (reg.carbon_ref) |ref| {
                    _ = UnregisterEventHotKey(ref);
                }
                slot.* = null;
                return;
            }
        }
    }
}

pub fn run() !void {
    CFRunLoopRun();
}

pub fn stop() void {
    CFRunLoopStop(CFRunLoopGetMain());
}
