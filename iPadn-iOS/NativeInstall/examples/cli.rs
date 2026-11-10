//! Runs the library from a computer on the same network as the device, for
//! checking a pairing file and the install path without building the app.
//!
//!   cargo run --example cli -- lookup  <pairing> <host> <port> <bundle-id>
//!   cargo run --example cli -- install <pairing> <host> <port> <bundle-id> <ipa>

use std::ffi::{CStr, CString, c_void};

extern "C" fn progress(_: *mut c_void, phase: i32, done: u64, total: u64) {
    eprintln!("phase {phase}: {done}/{total}");
}

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.len() < 5 {
        eprintln!("usage: cli lookup|install <pairing> <host> <port> <bundle-id> [ipa]");
        std::process::exit(2);
    }
    let request = serde_json::json!({
        "pairing_file": arguments[1],
        "host": arguments[2],
        "port": arguments[3].parse::<u16>().expect("port"),
        "bundle_id": arguments[4],
        "ipa": arguments.get(5),
    });
    let request = CString::new(request.to_string()).unwrap();
    let reply = unsafe {
        match arguments[0].as_str() {
            "install" => ipadn_native::iPadnNativeInstall(request.as_ptr(), Some(progress), std::ptr::null_mut()),
            _ => ipadn_native::iPadnNativeLookup(request.as_ptr()),
        }
    };
    println!("{}", unsafe { CStr::from_ptr(reply) }.to_string_lossy());
    unsafe { ipadn_native::iPadnNativeFree(reply) };
}
