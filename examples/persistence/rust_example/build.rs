// build.rs — wires the Rust example to the libpersistence shared library
// produced by the Nim FFI build in nimlib/build/.

fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let lib_dir = format!("{}/../nimlib/build", manifest);

    println!("cargo:rustc-link-search=native={}", lib_dir);
    println!("cargo:rustc-link-lib=dylib=persistence");

    // POSIX: bake the build directory into the binary's rpath so the
    // example runs without DYLD_LIBRARY_PATH / LD_LIBRARY_PATH gymnastics.
    if cfg!(target_os = "linux") || cfg!(target_os = "macos") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir);
    }

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}/libpersistence.so", lib_dir);
    println!("cargo:rerun-if-changed={}/libpersistence.dylib", lib_dir);
    println!("cargo:rerun-if-changed={}/persistence.dll", lib_dir);
}
