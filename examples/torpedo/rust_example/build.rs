// build.rs — wires the Rust example to the libtorpedolib shared library
// produced by the Nim FFI build in nimlib/build/.

fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let lib_dir = format!("{}/../nimlib/build", manifest);

    println!("cargo:rustc-link-search=native={}", lib_dir);
    println!("cargo:rustc-link-lib=dylib=torpedolib");

    if cfg!(target_os = "linux") || cfg!(target_os = "macos") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir);
    }

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}/libtorpedolib.so", lib_dir);
    println!("cargo:rerun-if-changed={}/libtorpedolib.dylib", lib_dir);
    println!("cargo:rerun-if-changed={}/torpedolib.dll", lib_dir);
}
