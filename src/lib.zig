const std = @import("std");
const hotkey = @import("hotkey");

/// Opaque handle returned by fulton_register. Pass to fulton_unregister to remove.
pub const FultonHandle = extern struct {
    id: u32,
};

/// Callback type for hotkey events. Fires when a registered hotkey is pressed.
pub const FultonCallback = *const fn (userdata: ?*anyopaque) callconv(.c) void;

/// Backend mode.
/// 0 = simple (no permissions needed, cannot swallow keys)
/// 1 = advanced (may require permissions, can swallow keys)
pub const FULTON_BACKEND_SIMPLE: c_int = 0;
pub const FULTON_BACKEND_ADVANCED: c_int = 1;

/// Modifier flags (bitmask).
pub const FULTON_MOD_CMD: u8 = 0x01; // Cmd/Win/Super
pub const FULTON_MOD_CTRL: u8 = 0x02;
pub const FULTON_MOD_ALT: u8 = 0x04; // Alt/Option
pub const FULTON_MOD_SHIFT: u8 = 0x08;

/// Register a global hotkey.
///
/// Parameters:
///   modifiers: bitmask of FULTON_MOD_* flags
///   key:       key code from the Key enum (a=0, b=1, ..., space=70, etc.)
///   callback:  function called when the hotkey fires (runs on event loop thread)
///   userdata:  opaque pointer passed through to callback
///   backend:   FULTON_BACKEND_SIMPLE or FULTON_BACKEND_ADVANCED
///
/// Returns a handle with id > 0 on success, or id == 0 on failure.
export fn fulton_register(
    modifiers: u8,
    key: u16,
    callback: FultonCallback,
    userdata: ?*anyopaque,
    backend: c_int,
) FultonHandle {
    const mods = hotkey.Modifier.fromInt(modifiers);
    const k: hotkey.Key = @enumFromInt(key);
    const be: hotkey.Backend = if (backend == FULTON_BACKEND_ADVANCED) .advanced else .simple;

    // Wrap the C callback to match the Zig callback signature
    const wrapper = struct {
        fn call(ud: ?*anyopaque) void {
            // ud encodes both the C callback and the user's userdata
            const ctx: *CallbackContext = @ptrCast(@alignCast(ud.?));
            ctx.c_callback(ctx.c_userdata);
        }
    };

    // Allocate a context struct so we can bridge the calling conventions.
    // Leaked intentionally — freed on unregister.
    const ctx = std.heap.c_allocator.create(CallbackContext) catch return .{ .id = 0 };
    ctx.* = .{
        .c_callback = callback,
        .c_userdata = userdata,
    };

    const handle = hotkey.register(mods, k, &wrapper.call, @ptrCast(ctx), be) catch
        return .{ .id = 0 };

    // Store context for cleanup
    for (&contexts) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .id = handle.id, .ctx = ctx };
            break;
        }
    }

    return .{ .id = handle.id };
}

/// Register a global hotkey from a string like "cmd+shift+v".
///
/// Modifier names: cmd/super/win, ctrl, alt/opt/option, shift
/// Key names: a-z, 0-9, f1-f12, space, return/enter, tab, escape/esc, etc.
///
/// Returns a handle with id > 0 on success, or id == 0 on failure.
export fn fulton_register_string(
    hotkey_str: [*:0]const u8,
    callback: FultonCallback,
    userdata: ?*anyopaque,
    backend: c_int,
) FultonHandle {
    const slice = std.mem.sliceTo(hotkey_str, 0);
    const parsed = hotkey.parseHotkeyString(slice) orelse return .{ .id = 0 };
    return fulton_register(
        parsed.modifiers.toInt(),
        @intFromEnum(parsed.key),
        callback,
        userdata,
        backend,
    );
}

/// Unregister a previously registered hotkey.
export fn fulton_unregister(handle: FultonHandle) void {
    hotkey.unregister(.{ .id = handle.id });

    // Free the bridging context
    for (&contexts) |*slot| {
        if (slot.*) |entry| {
            if (entry.id == handle.id) {
                std.heap.c_allocator.destroy(entry.ctx);
                slot.* = null;
                break;
            }
        }
    }
}

/// Enter the platform event loop. Blocks until fulton_stop() is called.
/// Must be called from the main thread on macOS.
export fn fulton_run() c_int {
    hotkey.run() catch return -1;
    return 0;
}

/// Signal the event loop to exit.
export fn fulton_stop() void {
    hotkey.stop();
}

// ---------------------------------------------------------------------------
// Internal: bridging between C calling convention and Zig callbacks
// ---------------------------------------------------------------------------

const CallbackContext = struct {
    c_callback: FultonCallback,
    c_userdata: ?*anyopaque,
};

const ContextEntry = struct {
    id: u32,
    ctx: *CallbackContext,
};

var contexts: [64]?ContextEntry = [_]?ContextEntry{null} ** 64;
