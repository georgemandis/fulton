use std::env;

fn main() {
    // Point cargo at the Fulton static library.
    // Set FULTON_LIB_DIR to the directory containing libfulton.a
    let lib_dir = env::var("FULTON_LIB_DIR")
        .unwrap_or_else(|_| "../../zig-out/lib".to_string());

    println!("cargo:rustc-link-search=native={}", lib_dir);
    println!("cargo:rustc-link-lib=static=fulton");

    // Platform frameworks needed by Fulton
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=framework=Carbon");
        println!("cargo:rustc-link-lib=framework=CoreGraphics");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=AppKit");
    }

    #[cfg(target_os = "linux")]
    {
        println!("cargo:rustc-link-lib=X11");
    }

    #[cfg(target_os = "windows")]
    {
        println!("cargo:rustc-link-lib=user32");
        println!("cargo:rustc-link-lib=kernel32");
    }
}
