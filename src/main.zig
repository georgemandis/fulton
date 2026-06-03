const std = @import("std");
const builtin = @import("builtin");
const hotkey = @import("hotkey");

const version = "0.2.0";

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
    var setup_requested = false;
    var config_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < all_args.items.len) {
                i += 1;
                config_path = all_args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "--list-keys")) {
            list_keys = true;
        } else if (std.mem.eql(u8, arg, "--setup")) {
            setup_requested = true;
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

    if (setup_requested) {
        const stdout_file = File.stdout();
        var buf: [4096]u8 = undefined;
        var w = stdout_file.writerStreaming(io, &buf);
        try printSetup(&w.interface);
        try w.interface.flush();
        return;
    }

    // Parse backend (applies globally to all bindings)
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

    // Resolve config: either --key/--exec one-off, config file, or both
    var config_contents: ?[]u8 = null;
    defer if (config_contents) |c| allocator.free(c);

    var entries: [MAX_BINDINGS]ConfigEntry = undefined;
    var parse_errors: [MAX_BINDINGS]ParseConfigError = undefined;
    var config_entry_count: usize = 0;

    const use_config = config_path != null or (key_str == null and exec_cmd == null);

    if (use_config) {
        var path_buf: [1024]u8 = undefined;
        const resolved_path: []const u8 = config_path orelse getDefaultConfigPath(&path_buf) orelse {
            const stderr_file = File.stderr();
            var buf: [512]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            try w.interface.print("Error: no config file found\n", .{});
            try w.interface.print("Expected location: ", .{});
            if (builtin.os.tag == .macos) {
                try w.interface.print("~/Library/Application Support/fulton/config\n", .{});
            } else if (builtin.os.tag == .linux) {
                try w.interface.print("~/.config/fulton/config\n", .{});
            } else if (builtin.os.tag == .windows) {
                try w.interface.print("%APPDATA%\\fulton\\config\n", .{});
            }
            try w.interface.print("\nUse --key and --exec for one-off hotkeys, or create a config file.\n", .{});
            try w.interface.print("Run fulton --help for usage.\n", .{});
            try w.interface.flush();
            std.process.exit(1);
        };

        config_contents = std.Io.Dir.cwd().readFileAlloc(io, resolved_path, allocator, .limited(1024 * 1024)) catch {
            const stderr_file = File.stderr();
            var buf: [512]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            if (config_path == null) {
                // Default config path doesn't exist yet — guide the user
                try w.interface.print("Error: no config file found\n", .{});
                try w.interface.print("Expected location: {s}\n", .{resolved_path});
                try w.interface.print("\nCreate a config file with one hotkey per line:\n", .{});
                try w.interface.print("  ctrl+shift+v = open -a Schrodinger\n", .{});
                try w.interface.print("  super+space = rofi -show drun\n", .{});
                try w.interface.print("\nOr use --key and --exec for a one-off hotkey.\n", .{});
            } else {
                try w.interface.print("Error: could not read config file: {s}\n", .{resolved_path});
            }
            try w.interface.flush();
            std.process.exit(1);
        };

        const result = parseConfig(config_contents.?, &entries, &parse_errors);
        config_entry_count = result.entry_count;

        if (result.error_count > 0) {
            const stderr_file = File.stderr();
            var buf: [1024]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            for (0..result.error_count) |ei| {
                try w.interface.print("config:{d}: {s}\n", .{ parse_errors[ei].line_number, parse_errors[ei].message });
            }
            try w.interface.flush();
            std.process.exit(1);
        }

        if (config_entry_count == 0 and key_str == null) {
            const stderr_file = File.stderr();
            var buf: [256]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            try w.interface.print("Error: config file contains no bindings\n", .{});
            try w.interface.flush();
            std.process.exit(1);
        }
    } else if (key_str == null or exec_cmd == null) {
        const stderr_file = File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Error: --key and --exec are required\n\n", .{});
        try printUsage(&w.interface);
        try w.interface.flush();
        std.process.exit(1);
    }

    const ExecContext = struct {
        command: [:0]const u8,
        io_handle: Io,

        fn onHotkey(userdata: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(userdata.?));
            const stderr_file = File.stderr();
            var errbuf: [256]u8 = undefined;
            var ew = stderr_file.writerStreaming(ctx.io_handle, &errbuf);

            if (builtin.os.tag == .windows) {
                _ = cSystem(ctx.command.ptr);
            } else {
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

    var contexts: [MAX_BINDINGS]ExecContext = undefined;
    var context_count: usize = 0;

    // Register bindings from config file
    for (0..config_entry_count) |ci| {
        const entry = entries[ci];
        const parsed = hotkey.parseHotkeyString(entry.hotkey_str) orelse {
            const stderr_file = File.stderr();
            var buf: [256]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            try w.interface.print("config:{d}: invalid hotkey \"{s}\"\n", .{ entry.line_number, entry.hotkey_str });
            try w.interface.flush();
            std.process.exit(1);
        };

        const cmd_z = try allocator.allocSentinel(u8, entry.command.len, 0);
        @memcpy(cmd_z[0..entry.command.len], entry.command);

        contexts[context_count] = .{ .command = cmd_z, .io_handle = io };
        _ = hotkey.register(parsed.modifiers, parsed.key, &ExecContext.onHotkey, @ptrCast(&contexts[context_count]), backend) catch |err| {
            const stderr_file = File.stderr();
            var buf: [512]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            try w.interface.print("config:{d}: failed to register hotkey \"{s}\"\n", .{ entry.line_number, entry.hotkey_str });
            if (builtin.os.tag == .linux and err == hotkey.HotkeyError.WaylandPermissionDenied) {
                try w.interface.print("Run fulton --setup for Wayland permission instructions.\n", .{});
            }
            try w.interface.flush();
            std.process.exit(1);
        };
        context_count += 1;
    }

    // Register CLI --key/--exec binding if provided
    if (key_str != null and exec_cmd != null) {
        const parsed = hotkey.parseHotkeyString(key_str.?) orelse {
            const stderr_file = File.stderr();
            var buf: [256]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            try w.interface.print("Error: invalid hotkey string: {s}\n", .{key_str.?});
            try w.interface.flush();
            std.process.exit(1);
        };

        contexts[context_count] = .{ .command = exec_cmd.?, .io_handle = io };
        _ = hotkey.register(parsed.modifiers, parsed.key, &ExecContext.onHotkey, @ptrCast(&contexts[context_count]), backend) catch |err| {
            const stderr_file = File.stderr();
            var buf: [512]u8 = undefined;
            var w = stderr_file.writerStreaming(io, &buf);
            try w.interface.print("Error: failed to register hotkey\n", .{});
            if (builtin.os.tag == .linux and err == hotkey.HotkeyError.WaylandPermissionDenied) {
                try w.interface.print("Run fulton --setup for Wayland permission instructions.\n", .{});
            }
            try w.interface.flush();
            std.process.exit(1);
        };
        context_count += 1;
    }

    // Print status
    {
        const stderr_file = File.stderr();
        var buf: [512]u8 = undefined;
        var w = stderr_file.writerStreaming(io, &buf);
        try w.interface.print("Listening for {d} hotkey{s} (backend: {s}, Ctrl+C to stop)...\n", .{
            context_count,
            if (context_count != 1) "s" else "",
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
        \\  --config, -c <path>       Config file path (default: platform config dir)
        \\  --list-keys               List all available key names
        \\  --setup                   Show platform setup instructions
        \\  --version, -V             Show version
        \\  --help, -h                Show this help message
        \\
        \\Backends:
        \\  simple     No permissions needed. Cannot swallow keys.
        \\             macOS: Carbon RegisterEventHotKey
        \\             Windows: RegisterHotKey
        \\             Linux/X11: XGrabKey
        \\             Linux/Wayland: evdev (run fulton --setup)
        \\
        \\  advanced   Can intercept and swallow keys. May need permissions.
        \\             macOS: CGEventTap (requires Accessibility)
        \\             Windows: SetWindowsHookEx (AV may flag)
        \\             Linux: same as simple
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

fn printSetup(writer: *std.Io.Writer) !void {
    if (builtin.os.tag == .linux) {
        try writer.print(
            \\fulton — Linux setup
            \\
            \\On X11 sessions, fulton works out of the box using XGrabKey.
            \\
            \\On Wayland, fulton reads keyboard input via evdev, which requires
            \\permission to access /dev/input/event* devices.
            \\
            \\Option 1: Add your user to the input group (recommended)
            \\  sudo usermod -aG input $USER
            \\  Then log out and back in for the change to take effect.
            \\
            \\Option 2: Run fulton with sudo
            \\  sudo fulton --key "ctrl+shift+v" --exec "your-command"
            \\
            \\Option 3: Set a file capability on the fulton binary
            \\  sudo setcap cap_dac_read_search+ep $(which fulton)
            \\  This lets fulton read input devices without full root access.
            \\  Note: must be re-applied after each upgrade.
            \\
        , .{});
    } else if (builtin.os.tag == .macos) {
        try writer.print(
            \\fulton — macOS setup
            \\
            \\Simple mode works out of the box (no permissions needed).
            \\
            \\Advanced mode requires Accessibility permission:
            \\  System Settings > Privacy & Security > Accessibility
            \\  Add your terminal app or fulton to the allowed list.
            \\
        , .{});
    } else if (builtin.os.tag == .windows) {
        try writer.print(
            \\fulton — Windows setup
            \\
            \\Simple mode works out of the box (no permissions needed).
            \\
            \\Advanced mode uses a low-level keyboard hook. Some antivirus
            \\software may flag this as suspicious — you may need to add
            \\an exception for fulton.exe.
            \\
        , .{});
    } else {
        try writer.print("No setup instructions available for this platform.\n", .{});
    }
}

fn getDefaultConfigPath(buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return null, 0);
        return std.fmt.bufPrint(buf, "{s}/Library/Application Support/fulton/config", .{home}) catch null;
    } else if (builtin.os.tag == .linux) {
        if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
            const xdg_s = std.mem.sliceTo(xdg, 0);
            if (xdg_s.len > 0) {
                return std.fmt.bufPrint(buf, "{s}/fulton/config", .{xdg_s}) catch null;
            }
        }
        const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return null, 0);
        return std.fmt.bufPrint(buf, "{s}/.config/fulton/config", .{home}) catch null;
    } else if (builtin.os.tag == .windows) {
        const appdata = std.mem.sliceTo(std.c.getenv("APPDATA") orelse return null, 0);
        return std.fmt.bufPrint(buf, "{s}\\fulton\\config", .{appdata}) catch null;
    }
    return null;
}

const MAX_BINDINGS = 64;

const ConfigEntry = struct {
    hotkey_str: []const u8,
    command: []const u8,
    line_number: usize,
};

const ParseConfigError = struct {
    line_number: usize,
    message: []const u8,
};

fn parseConfig(contents: []const u8, entries: []ConfigEntry, errors: []ParseConfigError) struct { entry_count: usize, error_count: usize } {
    var entry_count: usize = 0;
    var error_count: usize = 0;
    var line_number: usize = 0;

    var line_iter = std.mem.splitScalar(u8, contents, '\n');
    while (line_iter.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse {
            if (error_count < errors.len) {
                errors[error_count] = .{
                    .line_number = line_number,
                    .message = "expected \"hotkey = command\"",
                };
                error_count += 1;
            }
            continue;
        };

        const hotkey_str = std.mem.trim(u8, line[0..eq_pos], " \t");
        const command = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        if (hotkey_str.len == 0) {
            if (error_count < errors.len) {
                errors[error_count] = .{ .line_number = line_number, .message = "missing hotkey before '='" };
                error_count += 1;
            }
            continue;
        }

        if (command.len == 0) {
            if (error_count < errors.len) {
                errors[error_count] = .{ .line_number = line_number, .message = "missing command after '='" };
                error_count += 1;
            }
            continue;
        }

        if (entry_count < entries.len) {
            entries[entry_count] = .{
                .hotkey_str = hotkey_str,
                .command = command,
                .line_number = line_number,
            };
            entry_count += 1;
        }
    }

    return .{ .entry_count = entry_count, .error_count = error_count };
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
