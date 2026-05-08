// Device Monitor — Rust wrapper example.
//
// Drives the same `mylib` shared library that the C, C++, and Python
// examples consume. The generated wrapper crate is included here as a
// module via `#[path]` so a single example crate can target either build
// mode via Cargo features:
//
//     cargo run                 # native FFI build  (nimlib/build/)
//     cargo run --features cbor # CBOR FFI build    (nimlib/build_cbor/)
//
// The wrapper's public surface mirrors the C++ wrapper class:
//   Lib::version()                          static
//   Lib::new() + create_context()           lifecycle
//   <request_method>(args) -> Result<T>     each registered RequestBroker
//   on_<event>(closure) -> u64              each registered EventBroker
//   off_<event>(handle)
//
// v1 limitations on the native side: requests / events whose payloads use
// seq[T] / array[N, T] / nested objects emit a `// TODO(rust-codegen)`
// stub in the generated crate. Those are exercised by the CBOR build.

#[cfg(not(feature = "cbor"))]
#[path = "../../nimlib/build/mylib_rs/src/lib.rs"]
mod mylib;

#[cfg(feature = "cbor")]
#[path = "../../nimlib/build_cbor/mylib_rs/src/lib.rs"]
mod mylib;

use mylib::Mylib;

fn main() {
    println!("=== mylib Rust example ===");
    println!("library version: {}", Mylib::version());

    let mut lib = Mylib::new();
    let r = lib.create_context();
    if !r.is_ok() {
        eprintln!("create_context failed: {}", r.error().unwrap_or("?"));
        std::process::exit(1);
    }
    println!("context created: ctx = {}", lib.ctx());

    // Run mode-specific exercises. The CBOR-mode generator emits the full
    // request/event surface; the native-mode generator covers a useful
    // subset in v1 (primitive args / primitive-field results) and
    // emits TODO stubs for the rest, so the available method set differs
    // slightly between the two builds.
    #[cfg(feature = "cbor")]
    cbor_exercise(&lib);

    #[cfg(not(feature = "cbor"))]
    native_exercise(&lib);

    lib.shutdown();
    println!("OK");
}

#[cfg(not(feature = "cbor"))]
fn native_exercise(lib: &Mylib) {
    // Initialize the library with a config path — primitive String arg,
    // returns Result<InitializeResult>. This is the smoke test that the
    // generated extern "C" + Result<T> path is wired up correctly.
    let init = lib.initialize_request("/etc/mylib.toml".to_string());
    if init.is_ok() {
        let v = init.value().unwrap();
        println!("initialize_request OK: label={:?}", v);
    } else {
        eprintln!("initialize_request failed: {}", init.error().unwrap_or("?"));
    }
    let _ = lib;
}

#[cfg(feature = "cbor")]
fn cbor_exercise(lib: &Mylib) {
    let init = lib.initialize_request("/etc/mylib.toml".to_string());
    if init.is_ok() {
        let v = init.value().unwrap();
        println!("initialize_request OK: {:?}", v);
    } else {
        eprintln!("initialize_request failed: {}", init.error().unwrap_or("?"));
    }

    // CBOR mode supports the full type matrix — exercise a Vec arg path too.
    let spec = mylib::AddDeviceSpec {
        name: "demo".to_string(),
        deviceType: "sensor".to_string(),
        address: "127.0.0.1".to_string(),
    };
    let add = lib.add_device(vec![spec]);
    if add.is_ok() {
        println!("add_device OK: {:?}", add.value().unwrap());
    } else {
        eprintln!("add_device failed: {}", add.error().unwrap_or("?"));
    }
    let _ = lib;
}
