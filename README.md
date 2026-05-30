# fulton

Cross-platform global keyboard shortcut daemon and library written in Zig. Register system-wide hotkeys that fire regardless of which application has focus — from a CLI, or embedded via FFI in Bun, Rust/Tauri, Python, or anything else that can load a shared library.

Ships as both a CLI executable and a C ABI library (`libfulton`).

## Install

### Homebrew (macOS / Linux)

```bash
brew install georgemandis/tap/fulton
```

### Scoop (Windows)

```powershell
scoop bucket add georgemandis https://github.com/georgemandis/scoop-bucket
scoop install georgemandis/fulton
```

### Pre-built binaries

Download the latest release from [GitHub Releases](https://github.com/georgemandis/fulton/releases). Archives are available for macOS (aarch64, x86_64), Linux (aarch64, x86_64), and Windows (x86_64).

## Status

| Platform | Simple mode | Advanced mode |
|----------|-------------|---------------|
| macOS    | ✅ Carbon `RegisterEventHotKey` (no permissions) | ✅ `CGEventTap` (Accessibility permission) |
| Windows  | ✅ `RegisterHotKey` (no permissions) | ✅ `SetWindowsHookEx` WH_KEYBOARD_LL |
| Linux    | ✅ `XGrabKey` on root window (X11) | ⬜ Wayland portal (planned) |

Built and tested against **Zig 0.16.0**.

## Why

Most frameworks that offer global hotkeys (Electron, Tauri, Qt) bundle the feature inside a massive runtime. Native approaches exist on every platform, but they're platform-specific C APIs that require different event loops, different permission models, and different registration patterns.

Fulton wraps all of them behind a single API — as a library you can call from any language, or as a CLI daemon that binds keys to shell commands (like [skhd](https://github.com/koekeishiya/skhd), but cross-platform and not in maintenance mode).

### Simple vs Advanced mode

Each platform offers two backend modes:

- **Simple** — registers specific key combinations. The OS handles matching. No special permissions needed. Cannot swallow (consume) the keystroke — the focused app may also see it.
- **Advanced** — intercepts the full keyboard event stream and can swallow matching keystrokes so they never reach the focused app. Requires elevated permissions on some platforms (Accessibility on macOS, may trigger AV warnings on Windows).

## Building from source

Zig 0.16.0 required.

```sh
zig build
```

This produces three artifacts:

- `zig-out/bin/fulton` — the CLI executable
- `zig-out/lib/libfulton.dylib` (macOS) / `.so` (Linux) / `.dll` (Windows) — the C ABI shared library
- `zig-out/lib/libfulton.a` — static library for embedding (e.g. Tauri/Rust)

## CLI Usage

```bash
# Register a hotkey that runs a command
fulton --key "cmd+shift+v" --exec "open -a Schrodinger"

# Use advanced mode (can swallow the keystroke)
fulton --key "ctrl+alt+t" --exec "ghostty" --backend advanced

# List available key names
fulton --list-keys
```

### Options

| Flag | Description |
|------|-------------|
| `--key, -k <hotkey>` | Hotkey string (e.g. `"cmd+shift+v"`) |
| `--exec, -e <command>` | Command to execute when hotkey fires |
| `--backend, -b <mode>` | `simple` (default) or `advanced` |
| `--list-keys` | List all available key and modifier names |
| `--version, -V` | Show version |
| `--help, -h` | Show usage |

### Hotkey string format

Combine modifiers and a key with `+`:

```
cmd+shift+v
ctrl+alt+f1
super+space
shift+escape
```

**Modifier names:** `cmd` / `super` / `win` / `meta`, `ctrl` / `control`, `alt` / `opt` / `option`, `shift`

**Key names:** `a`-`z`, `0`-`9`, `f1`-`f12`, `space`, `return` / `enter`, `tab`, `escape` / `esc`, `backspace`, `delete`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`

## C ABI

The shared library exposes a small C ABI. All errors are reported through return values.

```c
typedef struct { uint32_t id; } FultonHandle;
typedef void (*FultonCallback)(void* userdata);

// Register by modifier flags + key code
FultonHandle fulton_register(
    uint8_t modifiers,   // bitmask: CMD=0x01, CTRL=0x02, ALT=0x04, SHIFT=0x08
    uint16_t key,        // key enum value (a=0, b=1, ..., space=70, etc.)
    FultonCallback cb,
    void* userdata,
    int backend          // 0=simple, 1=advanced
);

// Register by string (e.g. "cmd+shift+v")
FultonHandle fulton_register_string(
    const char* hotkey_str,
    FultonCallback cb,
    void* userdata,
    int backend
);

void fulton_unregister(FultonHandle handle);
int  fulton_run(void);   // enter event loop (blocks), returns 0 on success
void fulton_stop(void);  // signal event loop to exit
```

A handle with `id == 0` indicates failure.

**Note for apps with an existing run loop:** If your app already runs an event loop (Tauri, Electron, native Cocoa/GTK/Win32 apps), call `fulton_register()` only — skip `fulton_run()`. Your existing run loop will dispatch the hotkey events. `fulton_run()` blocks and is meant for standalone tools that need fulton to provide the event loop.

### Bun FFI example

```ts
import { dlopen, FFIType, suffix } from "bun:ffi";

const { symbols: fulton } = dlopen(`./zig-out/lib/libfulton.${suffix}`, {
  fulton_register_string: {
    args: [FFIType.cstring, FFIType.function, FFIType.ptr, FFIType.i32],
    returns: FFIType.u32,
  },
  fulton_unregister: { args: [FFIType.u32], returns: FFIType.void },
  fulton_run:        { args: [], returns: FFIType.i32 },
  fulton_stop:       { args: [], returns: FFIType.void },
});

const onHotkey = new Bun.FFICallback(
  { args: [FFIType.ptr], returns: FFIType.void },
  () => console.log("Hotkey pressed!")
);

const handle = fulton.fulton_register_string(
  Buffer.from("cmd+shift+v\0"), onHotkey.ptr, null, 0
);

fulton.fulton_run();
```

See [`examples/bun/hotkey.ts`](examples/bun/hotkey.ts) for the full example.

### Rust FFI example

```rust
extern "C" {
    fn fulton_register_string(
        hotkey_str: *const i8,
        callback: extern "C" fn(*mut c_void),
        userdata: *mut c_void,
        backend: c_int,
    ) -> FultonHandle;
    fn fulton_run() -> c_int;
}

extern "C" fn on_hotkey(_: *mut c_void) {
    println!("Hotkey pressed!");
    // In Tauri: app_handle.emit_all("hotkey-pressed", payload).unwrap();
}

let handle = fulton_register_string(
    c"cmd+shift+v".as_ptr(), on_hotkey, std::ptr::null_mut(), 0
);
fulton_run();
```

See [`examples/rust/`](examples/rust/) for the full example with build.rs linking.

## Project Structure

```
src/
├── hotkey.zig             # Public Zig API; Key/Modifier types, parser, dispatch
├── lib.zig                # C ABI exports for the shared library
├── main.zig               # CLI entry point
└── platform/
    ├── macos.zig           # Carbon RegisterEventHotKey + CGEventTap
    ├── windows.zig         # RegisterHotKey + SetWindowsHookEx
    └── linux.zig           # XGrabKey on root window
examples/
├── bun/hotkey.ts           # Bun FFI example
└── rust/                   # Rust FFI example with Cargo project
build.zig                   # Builds CLI, dynamic library, and static library
```

### Architecture

```
   CLI (main.zig) ─┐
                    ├─► hotkey.zig ──► platform/<os>.zig ──► system hotkey API
   FFI (lib.zig) ──┘
```

Both the CLI and the FFI shim depend only on the public `hotkey.zig` API. Neither knows which platform backend is in use.

## Platform notes

### macOS

- **Simple mode** uses Carbon `RegisterEventHotKey`. Deprecated since macOS 10.8 but still functional — Apple has provided no replacement. Does not require any permissions.
- **Advanced mode** uses `CGEventTapCreate`. Requires Accessibility permission (System Preferences > Privacy & Security > Accessibility). Can intercept and swallow keystrokes. Handles `kCGEventTapDisabledByTimeout` automatically.
- On macOS 15 (Sequoia), hotkeys using only Option or Option+Shift as modifiers may fail. Use Cmd or Ctrl combinations.

### Windows

- **Simple mode** uses `RegisterHotKey` with `MOD_NOREPEAT` to prevent auto-repeat spam. No elevation or special permissions needed.
- **Advanced mode** uses `SetWindowsHookEx` with `WH_KEYBOARD_LL`. No DLL injection needed. Anti-virus software may flag it since it sees all keystrokes.

### Linux

- Both modes use `XGrabKey` on the X11 root window. Automatically registers all 8 NumLock/CapsLock/ScrollLock modifier combinations for each hotkey.
- Wayland does not have a protocol-level equivalent. The XDG Desktop Portal `GlobalShortcuts` interface exists but compositor support is inconsistent (KDE works, GNOME is catching up, Sway has nothing). Wayland portal support is planned.

## Roadmap

- [x] macOS backend (Carbon + CGEventTap)
- [x] Windows backend (RegisterHotKey + SetWindowsHookEx)
- [x] Linux/X11 backend (XGrabKey)
- [x] CLI with `--key` / `--exec`
- [x] C ABI shared library
- [x] Bun and Rust FFI examples
- [ ] Multiple hotkeys from a config file
- [ ] Wayland support via XDG Desktop Portal GlobalShortcuts
- [ ] Shell completions
