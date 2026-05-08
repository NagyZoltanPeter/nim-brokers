// build.rs — wires the Rust example to the libtorpedolib shared library
// produced by the Nim build (in nimlib/build/ for native mode or
// nimlib/build_cbor/ for CBOR mode).

fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let cbor = std::env::var("CARGO_FEATURE_CBOR").is_ok();
    let dir_name = if cbor { "build_cbor" } else { "build" };
    let lib_dir = format!("{}/../nimlib/{}", manifest, dir_name);

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
