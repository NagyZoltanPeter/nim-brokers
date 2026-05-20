// build.rs — wires the Rust example to the libmylib shared library
// produced by the Nim CBOR build in nimlib/build_cbor/.

fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let lib_dir = format!("{}/../nimlib/build_cbor", manifest);

    println!("cargo:rustc-link-search=native={}", lib_dir);
    println!("cargo:rustc-link-lib=dylib=mylib");

    // POSIX: bake the build directory into the binary's rpath so the
    // example runs without DYLD_LIBRARY_PATH / LD_LIBRARY_PATH gymnastics.
    if cfg!(target_os = "linux") || cfg!(target_os = "macos") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir);
    }

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}/libmylib.so", lib_dir);
    println!("cargo:rerun-if-changed={}/libmylib.dylib", lib_dir);
    println!("cargo:rerun-if-changed={}/mylib.dll", lib_dir);
}
