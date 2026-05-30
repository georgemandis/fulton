const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // Shared module for hotkey core logic
    const hotkey_mod = b.createModule(.{
        .root_source_file = b.path("src/hotkey.zig"),
        .target = target,
        .optimize = optimize,
    });

    // When cross-compiling for macOS, pass -Dmacos-sdk=/path/to/sdk
    const is_native = target.query.isNativeOs() and target.query.isNativeCpu();
    if (!is_native and target_os == .macos) {
        const macos_sdk = b.option([]const u8, "macos-sdk", "Path to macOS SDK for cross-compilation");
        if (macos_sdk) |sdk| {
            hotkey_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            hotkey_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    switch (target_os) {
        .macos => {
            hotkey_mod.linkFramework("Carbon", .{});
            hotkey_mod.linkFramework("CoreGraphics", .{});
            hotkey_mod.linkFramework("CoreFoundation", .{});
            hotkey_mod.linkFramework("AppKit", .{});
        },
        .linux => {
            hotkey_mod.link_libc = true;
        },
        .windows => {
            hotkey_mod.link_libc = true;
            hotkey_mod.linkSystemLibrary("user32", .{});
            hotkey_mod.linkSystemLibrary("kernel32", .{});
        },
        else => {},
    }

    // Shared library (C ABI for Bun FFI, Rust, etc.)
    const lib = b.addLibrary(.{
        .name = "fulton",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hotkey", .module = hotkey_mod },
            },
        }),
    });
    b.installArtifact(lib);

    // Static library for embedding (e.g. Tauri/Rust)
    const lib_static = b.addLibrary(.{
        .name = "fulton",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hotkey", .module = hotkey_mod },
            },
        }),
    });
    b.installArtifact(lib_static);

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "fulton",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hotkey", .module = hotkey_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step for CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the fulton CLI");
    run_step.dependOn(&run_cmd.step);
}
