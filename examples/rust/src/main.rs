//! Rust FFI example: register global hotkeys via Fulton.
//!
//! Build the Zig static library first:
//!   cd ../../.. && zig build
//!
//! Then run:
//!   FULTON_LIB_DIR=../../../zig-out/lib cargo run
//!
//! This shows how a Tauri app (or any Rust application) can replace
//! tauri_plugin_global_shortcut with Fulton's static library — the same
//! pattern as Schrodinger using libcopycat.a for clipboard access.

use std::ffi::CString;
use std::os::raw::{c_int, c_void};
use std::process;

// Fulton C ABI declarations — matches src/lib.zig exports
#[repr(C)]
struct FultonHandle {
    id: u32,
}

const FULTON_BACKEND_SIMPLE: c_int = 0;
#[allow(dead_code)]
const FULTON_BACKEND_ADVANCED: c_int = 1;

type FultonCallback = extern "C" fn(userdata: *mut c_void);

extern "C" {
    fn fulton_register_string(
        hotkey_str: *const i8,
        callback: FultonCallback,
        userdata: *mut c_void,
        backend: c_int,
    ) -> FultonHandle;

    fn fulton_unregister(handle: FultonHandle);
    fn fulton_run() -> c_int;
    fn fulton_stop();
}

// Callback fired when the hotkey is pressed
extern "C" fn on_hotkey(_userdata: *mut c_void) {
    println!("Hotkey pressed! Cmd+Shift+V detected.");
    // In a Tauri app, you'd emit an event to the frontend here:
    //   app_handle.emit_all("hotkey-pressed", payload).unwrap();
}

fn main() {
    let hotkey_str = CString::new("cmd+shift+v").unwrap();

    let handle = unsafe {
        fulton_register_string(
            hotkey_str.as_ptr(),
            on_hotkey,
            std::ptr::null_mut(),
            FULTON_BACKEND_SIMPLE,
        )
    };

    if handle.id == 0 {
        eprintln!("Failed to register hotkey");
        process::exit(1);
    }

    println!("Registered hotkey cmd+shift+v (handle: {})", handle.id);
    println!("Press Cmd+Shift+V anywhere to trigger. Ctrl+C to exit.");

    // Set up Ctrl+C handler
    ctrlc_handler();

    // Enter the event loop (blocks)
    let result = unsafe { fulton_run() };
    if result != 0 {
        eprintln!("Event loop failed");
        process::exit(1);
    }
}

fn ctrlc_handler() {
    // Simple signal handler — in a Tauri app you'd use the app lifecycle instead
    unsafe {
        libc_signal(2 /* SIGINT */, handle_sigint);
    }
}

extern "C" fn handle_sigint(_sig: c_int) {
    println!("\nShutting down...");
    unsafe { fulton_stop() };
    process::exit(0);
}

extern "C" {
    #[link_name = "signal"]
    fn libc_signal(sig: c_int, handler: extern "C" fn(c_int));
}
