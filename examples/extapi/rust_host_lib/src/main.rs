//! EXTAPI example — scenario 1b: lib mode in Rust. This application hosts the
//! Nim library `storagelib` and implements the `notes` plugin that the library
//! consumes — in-process, with the R4 Builder (closures, provides exactly what
//! is set). Then it calls the library's own (API) request, whose Nim provider
//! calls back into this app through EXTAPI.

use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;

use notes_ext::{ffi::BrokerExtHost, Builder, Host, NoteStored};
use storagelib::Storagelib;

extern "C" {
    fn storagelib_extHost() -> *const BrokerExtHost;
}

fn main() {
    let mut failures = 0;
    let mut expect = |cond: bool, what: &str| {
        println!("  {}  {}", if cond { "ok  " } else { "FAIL" }, what);
        if !cond {
            failures += 1;
        }
    };

    println!("== scenario 1b: lib mode, plugin implemented by the host app (Rust)");
    let mut lib = Storagelib::new();
    let created = lib.create_context();
    expect(created.is_ok(), "storagelib create_context");
    if created.is_err() {
        std::process::exit(1);
    }

    let raw = unsafe { storagelib_extHost() };
    expect(!raw.is_null(), "storagelib_extHost()");
    let host = unsafe { Host::from_raw(raw) };

    let stored = Arc::new(AtomicI32::new(0));
    let s2 = stored.clone();
    let port = Builder::new()
        .note_stored(move |text: String| {
            s2.fetch_add(1, Ordering::SeqCst);
            async move { Ok(NoteStored { id: format!("note-{}", text.len()) }) }
        })
        .open(host, lib.ctx());
    expect(port.is_ok(), "notes Builder.open (provides note_stored)");

    match lib.save_note("hello".to_string()).into_result() {
        Ok(v) => {
            expect(true, "SaveNote via the library's (API)");
            expect(v.id == "note-5", "id produced by the app's plugin");
            expect(v.via == "notes plugin", "Nim provider routed through EXTAPI");
        }
        Err(e) => {
            expect(false, "SaveNote via the library's (API)");
            println!("        error: {e}");
        }
    }
    expect(stored.load(Ordering::SeqCst) == 1, "plugin closure invoked once");

    drop(port); // Port::drop closes it
    expect(lib.save_note("again".to_string()).is_err(), "after close: no provider");

    lib.shutdown();
    if failures > 0 {
        println!("rust_host_lib: {failures} check(s) failed");
        std::process::exit(1);
    }
    println!("rust_host_lib: all checks passed");
}
