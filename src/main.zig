const std = @import("std");
const builtin = @import("builtin");
const hotkey = @import("hotkey");

const version = "0.1.0";

// C runtime system() — used on Windows for command execution.
// On POSIX we use fork/execve instead for non-blocking fire-and-forget.
const cSystem = if (builtin.os.tag == .windows)
    struct {
        extern "c" fn system(command: [*:0]const u8) c_int;
    }.system
else
    undefined;

const Io = std.Io;
const File = std.Io.File;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip argv[0]

    var all_args: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer all_args.deinit(allocator);
    while (args_iter.next()) |arg| {
        try all_args.append(allocator, arg);
    }

    // Parse flags
    var key_str: ?[]const u8 = null;
    var exec_cmd: ?[:0]const u8 = null;
    var backend_str: ?[]const u8 = null;
    var help_requested = false;
    var list_keys = false;

    var i: usize = 0;
    while (i < all_args.items.len) : (i += 1) {
        const arg = all_args.items[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_requested = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            const stdout_file = File.stdout();
            var buf: [256]u8 = undefined;
            var w = stdout_file.writerStreaming(io, &buf);
            try w.interface.print("fulton " ++ version ++ " (" ++ @tagName(builtin.os.tag) ++ ")\n", .{});
            try w.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "-k")) {
            if (i + 1 < all_args.items.len) {
                i += 1;
                key_str = all_args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "--exec") or std.mem.eql(u8, arg, "-e")) {
            if (i + 1 < all_args.items.len) {
                i += 1;
                exec_cmd = all_args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "--backend") or std.mem.eql(u8, arg, "-b")) {
            if (i + 1 < all_args.items.len) {
                i += 1;
                backend_str = all_args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "--list-keys")) {
            list_keys = true;
        } else if (std.mem.eql(u8, arg, "help")) {
            help_requested = true;
        }
    }

    if (help_requested) {
        const stdout_file = File.stdout();
        var buf: [4096]u8 = undefined;
        var w = stdout_file.writerStreaming(io, &buf);
        try printUsage(&w.interface);
        try w.interface.flush();
        return;
    }

    if (list_keys) {
        const stdout_file = File.stdout();
        var buf: [4096]u8 = undefined;
        var w = stdout_file.writerStreaming(io, &buf);
        try printKeyList(&w.interface);
        try w.interface.flush();
        return;
    }

    if (key_str == null or exec_cmd == null) {
        const stderr_file = File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Error: --key and --exec are required\n\n", .{});
        try printUsage(&w.interface);
        try w.interface.flush();
        std.process.exit(1);
    }

    const parsed = hotkey.parseHotkeyString(key_str.?) orelse {
        const stderr_file = File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Error: invalid hotkey string: {s}\n", .{key_str.?});
        try w.interface.print("Format: modifier+modifier+key (e.g. cmd+shift+v, ctrl+alt+f1)\n", .{});
        try w.interface.print("Run fulton --list-keys for available key names.\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    };

    const backend: hotkey.Backend = if (backend_str) |bs| blk: {
        if (std.mem.eql(u8, bs, "advanced")) break :blk .advanced;
        if (std.mem.eql(u8, bs, "simple")) break :blk .simple;
        const stderr_file = File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Error: unknown backend: {s} (use 'simple' or 'advanced')\n", .{bs});
        try w.interface.flush();
        std.process.exit(1);
    } else .simple;

    const cmd: [:0]const u8 = exec_cmd.?;

    const ExecContext = struct {
        command: [:0]const u8,
        io_handle: Io,

        fn onHotkey(userdata: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(userdata.?));
            const stderr_file = File.stderr();
            var errbuf: [256]u8 = undefined;
            var ew = stderr_file.writerStreaming(ctx.io_handle, &errbuf);

            if (builtin.os.tag == .windows) {
                // Windows: shell out via C runtime system()
                _ = cSystem(ctx.command.ptr);
            } else {
                // POSIX: fork and exec via /bin/sh -c
                const argv = [_]?[*:0]const u8{
                    "/bin/sh",
                    "-c",
                    ctx.command.ptr,
                    null,
                };

                const pid = std.c.fork();
                if (pid == 0) {
                    _ = std.c.execve(
                        "/bin/sh",
                        @ptrCast(&argv),
                        @ptrCast(std.c.environ),
                    );
                    std.process.exit(127);
                } else if (pid < 0) {
                    ew.interface.print("Error: failed to fork\n", .{}) catch {};
                    ew.interface.flush() catch {};
                }
            }
        }
    };

    var ctx = ExecContext{
        .command = cmd,
        .io_handle = io,
    };

    _ = hotkey.register(parsed.modifiers, parsed.key, &ExecContext.onHotkey, @ptrCast(&ctx), backend) catch {
        const stderr_file = File.stderr();
        var buf: [512]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Error: failed to register hotkey\n", .{});
        if (backend == .advanced) {
            try w.interface.print("Advanced mode requires Accessibility permission (macOS) or may be blocked by AV (Windows).\n", .{});
        }
        try w.interface.flush();
        std.process.exit(1);
    };

    {
        const stderr_file = File.stderr();
        var buf: [512]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Listening for {s} (backend: {s}, Ctrl+C to stop)...\n", .{
            key_str.?,
            if (backend == .advanced) "advanced" else "simple",
        });
        try w.interface.flush();
    }

    hotkey.run() catch {
        const stderr_file = File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Error: event loop failed\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    };
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: fulton --key <hotkey> --exec <command> [options]
        \\
        \\Cross-platform global keyboard shortcut daemon and library.
        \\Version {s} ({s})
        \\
        \\Options:
        \\  --key, -k <hotkey>        Hotkey string (e.g. "cmd+shift+v")
        \\  --exec, -e <command>      Command to execute when hotkey fires
        \\  --backend, -b <mode>      Backend: "simple" (default) or "advanced"
        \\  --list-keys               List all available key names
        \\  --version, -V             Show version
        \\  --help, -h                Show this help message
        \\
        \\Backends:
        \\  simple     No permissions needed. Cannot swallow keys.
        \\             macOS: Carbon RegisterEventHotKey
        \\             Windows: RegisterHotKey
        \\             Linux: XGrabKey
        \\
        \\  advanced   Can intercept and swallow keys. May need permissions.
        \\             macOS: CGEventTap (requires Accessibility)
        \\             Windows: SetWindowsHookEx (AV may flag)
        \\             Linux: XGrabKey (same as simple)
        \\
        \\Modifier names: cmd/super/win, ctrl, alt/opt/option, shift
        \\
        \\Examples:
        \\  fulton --key "cmd+shift+v" --exec "open -a Schrodinger"
        \\  fulton --key "ctrl+alt+t" --exec "ghostty"
        \\  fulton --key "super+space" --exec "rofi -show drun" --backend advanced
        \\
        \\Also builds as a C ABI library (libfulton.dylib / .so / .dll) for
        \\embedding in Bun, Rust/Tauri, Python, or any FFI-capable runtime.
        \\
        \\Created by George Mandis <george@mand.is>
        \\https://github.com/georgemandis/fulton
        \\
    , .{ version, @tagName(builtin.os.tag) });
}

fn printKeyList(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Available key names:
        \\
        \\  Letters:    a b c d e f g h i j k l m n o p q r s t u v w x y z
        \\  Numbers:    0 1 2 3 4 5 6 7 8 9
        \\  Function:   f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
        \\  Special:    space return/enter tab escape/esc backspace delete
        \\  Navigation: up down left right home end pageup pagedown
        \\
        \\Modifier names:
        \\  cmd / super / win / meta
        \\  ctrl / control
        \\  alt / opt / option
        \\  shift
        \\
        \\Combine with +: cmd+shift+v, ctrl+alt+f1, super+space
        \\
    , .{});
}
