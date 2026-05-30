/**
 * Bun FFI example: register global hotkeys from JavaScript/TypeScript.
 *
 * Build the library first:
 *   cd ../.. && zig build
 *
 * Run:
 *   bun run hotkey.ts
 *
 * This gives any Bun application native global hotkey support — no Electron,
 * no Tauri, no framework needed. Just FFI into the Fulton library.
 */

import { dlopen, FFIType, ptr, suffix, CString } from "bun:ffi";
import { join } from "path";

// Resolve library path — adjust if your build output is elsewhere
const libPath = join(import.meta.dir, "..", "..", `zig-out/lib/libfulton.${suffix}`);

const { symbols: fulton } = dlopen(libPath, {
  fulton_register_string: {
    args: [FFIType.cstring, FFIType.function, FFIType.ptr, FFIType.i32],
    returns: FFIType.u32, // FultonHandle.id
  },
  fulton_unregister: {
    args: [FFIType.u32],
    returns: FFIType.void,
  },
  fulton_run: {
    args: [],
    returns: FFIType.i32,
  },
  fulton_stop: {
    args: [],
    returns: FFIType.void,
  },
});

// Backend constants
const FULTON_BACKEND_SIMPLE = 0;
const FULTON_BACKEND_ADVANCED = 1;

// --- Example usage ---

// Callback fired when the hotkey is pressed
const onHotkey = new Bun.FFICallback(
  {
    args: [FFIType.ptr],
    returns: FFIType.void,
  },
  (_userdata: number) => {
    console.log("Hotkey pressed! Cmd+Shift+V detected.");
    // Do anything here: open a window, run a command, toggle UI, etc.
  }
);

// Register Cmd+Shift+V (simple mode — no permissions needed)
const handle = fulton.fulton_register_string(
  Buffer.from("cmd+shift+v\0"),
  onHotkey.ptr,
  null,
  FULTON_BACKEND_SIMPLE
);

if (handle === 0) {
  console.error("Failed to register hotkey");
  process.exit(1);
}

console.log(`Registered hotkey cmd+shift+v (handle: ${handle})`);
console.log("Press Cmd+Shift+V anywhere to trigger. Ctrl+C to exit.");

// Handle clean shutdown
process.on("SIGINT", () => {
  console.log("\nShutting down...");
  fulton.fulton_unregister(handle);
  fulton.fulton_stop();
  process.exit(0);
});

// Enter the event loop (blocks — hotkeys fire the callback above)
// In a real app, you'd run this on a worker thread so the main thread
// stays responsive for UI or other I/O.
const result = fulton.fulton_run();
if (result !== 0) {
  console.error("Event loop failed");
  process.exit(1);
}
