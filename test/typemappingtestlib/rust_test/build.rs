// build.rs — wires the Rust parity test to the libtypemappingtestlib
// shared library produced by the Nim build.

fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let lib_dir = format!("{}/../build", manifest);

    println!("cargo:rustc-link-search=native={}", lib_dir);
    println!("cargo:rustc-link-lib=dylib=typemappingtestlib");

    if cfg!(target_os = "linux") || cfg!(target_os = "macos") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir);
    }

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}/libtypemappingtestlib.so", lib_dir);
    println!("cargo:rerun-if-changed={}/libtypemappingtestlib.dylib", lib_dir);
    println!("cargo:rerun-if-changed={}/typemappingtestlib.dll", lib_dir);
}
