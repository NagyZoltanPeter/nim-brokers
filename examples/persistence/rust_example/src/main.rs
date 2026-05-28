// Persistence — Rust wrapper example.
//
// Exercises the two-layer interface (IPersistence -> IBackend) with
// per-instance routing and per-subscription event delivery, replicating
// the C++ Scenario B.
//
//     cargo run   # builds against the FFI library in nimlib/build/

#[path = "../../nimlib/build/persistence_rs/src/lib.rs"]
mod persistence;

use persistence::Persistence;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const KIND_MEMORY: i32 = 0;
const KIND_FILE: i32 = 1;

fn wait_for<F: Fn() -> bool>(pred: F, timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while !pred() && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    pred()
}

fn roundtrip(_lib: &Persistence, be: &persistence::Backend, key: &str, val: &str) -> String {
    let result_val: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let result_count: Arc<AtomicI32> = Arc::new(AtomicI32::new(0));

    let k = key.to_string();
    let rv = result_val.clone();
    let rc = result_count.clone();
    let h = be.on_read_completed(move |rk: String, rv_str: String, found: bool| {
        if rk == k && found {
            *rv.lock().unwrap() = Some(rv_str);
            rc.fetch_add(1, Ordering::SeqCst);
        }
    });
    assert!(h != 0, "on_read_completed subscription failed");

    let r = be.store(key.to_string(), val.to_string());
    assert!(r.is_ok(), "store failed: {}", r.error().unwrap_or("?"));

    let before = result_count.load(Ordering::SeqCst);
    let r = be.read(key.to_string());
    assert!(r.is_ok(), "read failed: {}", r.error().unwrap_or("?"));

    assert!(
        wait_for(|| result_count.load(Ordering::SeqCst) > before, Duration::from_secs(2)),
        "read event timed out"
    );
    be.off_read_completed(h);

    let guard = result_val.lock().unwrap();
    guard.clone().expect("expected value")
}

fn scenario_two_contexts() {
    println!("  [A] two IPersistence contexts (File + Memory)");

    let mut p_file = Persistence::new();
    assert!(p_file.create_context().is_ok());
    assert!(p_file.initialize_request("cfg".to_string()).is_ok());
    let bf = p_file.make_backend(KIND_FILE);
    assert!(bf.is_ok(), "make_backend(FILE) failed: {}", bf.error().unwrap_or("?"));
    let mut bf = bf.into_result().unwrap();
    assert!(bf.valid());
    assert_eq!(roundtrip(&p_file, &bf, "alpha", "file-payload"), "file-payload");

    let mut p_mem = Persistence::new();
    assert!(p_mem.create_context().is_ok());
    assert!(p_mem.initialize_request("cfg".to_string()).is_ok());
    let bm = p_mem.make_backend(KIND_MEMORY);
    assert!(bm.is_ok(), "make_backend(MEMORY) failed: {}", bm.error().unwrap_or("?"));
    let mut bm = bm.into_result().unwrap();
    assert!(bm.valid());
    assert_eq!(roundtrip(&p_mem, &bm, "alpha", "memory-payload"), "memory-payload");

    assert_ne!(bf.ctx() & 0xFFFF, bm.ctx() & 0xFFFF);

    bm.close();
    p_mem.shutdown();
    bf.close();
    p_file.shutdown();
}

fn scenario_mixed_one_context() {
    println!("  [B] one IPersistence context, File + Memory backends coexisting");

    let mut p = Persistence::new();
    assert!(p.create_context().is_ok());
    assert!(p.initialize_request("cfg".to_string()).is_ok());

    let created_count = Arc::new(AtomicI32::new(0));
    let cc = created_count.clone();
    let ch = p.on_backend_created(move |_handle: u32, _kind: i32| {
        cc.fetch_add(1, Ordering::SeqCst);
    });

    let bf = p.make_backend(KIND_FILE);
    assert!(bf.is_ok(), "{}", bf.error().unwrap_or("?"));
    let mut bf = bf.into_result().unwrap();

    let bm = p.make_backend(KIND_MEMORY);
    assert!(bm.is_ok(), "{}", bm.error().unwrap_or("?"));
    let mut bm = bm.into_result().unwrap();

    assert!(
        wait_for(|| created_count.load(Ordering::SeqCst) == 2, Duration::from_secs(2)),
        "BackendCreated events"
    );
    p.off_backend_created(ch);

    // Routing invariant: both backends share classCtx, differ in instanceCtx.
    assert_eq!(bf.ctx() & 0xFFFF, p.ctx() & 0xFFFF);
    assert_eq!(bm.ctx() & 0xFFFF, p.ctx() & 0xFFFF);
    assert_ne!(bf.ctx() >> 16, bm.ctx() >> 16);
    assert_ne!(bf.ctx(), bm.ctx());

    // Per-instance request routing + per-subscription event delivery.
    assert_eq!(roundtrip(&p, &bf, "x", "FILE-X"), "FILE-X");
    assert_eq!(roundtrip(&p, &bm, "x", "MEM-X"), "MEM-X");

    // State check: both backends listed and alive.
    let st = p.list_backends();
    assert!(st.is_ok(), "{}", st.error().unwrap_or("?"));
    let items = &st.value().unwrap().backends;
    assert_eq!(items.len(), 2);
    for it in items {
        assert!(it.alive);
    }

    // Targeted teardown: terminate the File backend.
    let r = p.terminate_backend(bf.ctx());
    assert!(r.is_ok(), "{}", r.error().unwrap_or("?"));
    let st = p.list_backends();
    assert!(st.is_ok());
    let items = &st.value().unwrap().backends;
    let mut file_dead = false;
    let mut mem_alive = false;
    for it in items {
        if it.handle == bf.ctx() {
            file_dead = !it.alive;
        }
        if it.handle == bm.ctx() {
            mem_alive = it.alive;
        }
    }
    assert!(file_dead, "File backend should be terminated");
    assert!(mem_alive, "Memory backend should still be alive");

    // Terminated backend rejects requests; sibling keeps working.
    assert!(bf.store("y".to_string(), "z".to_string()).is_err(), "terminated backend must reject requests");
    assert_eq!(roundtrip(&p, &bm, "y", "MEM-Y"), "MEM-Y");

    bf.close();
    bm.close();
    p.shutdown();
}

fn scenario_concurrent_load() {
    const N: usize = 30;
    println!("  [C] two IPersistence contexts running concurrently, {N} roundtrips each under load");

    let ok_file = Arc::new(AtomicI32::new(0));
    let ok_mem = Arc::new(AtomicI32::new(0));

    let run_lib = |kind: i32, tag: &str, ok_count: Arc<AtomicI32>| {
        let tag = tag.to_string();
        move || {
            let mut p = Persistence::new();
            if !p.create_context().is_ok() {
                return;
            }
            let _ = p.initialize_request("cfg".to_string());
            let be_r = p.make_backend(kind);
            if !be_r.is_ok() {
                p.shutdown();
                return;
            }
            let mut be = be_r.into_result().unwrap();

            let results: Arc<Mutex<std::collections::HashMap<String, String>>> =
                Arc::new(Mutex::new(std::collections::HashMap::new()));

            let res = results.clone();
            let h = be.on_read_completed(move |k: String, v: String, found: bool| {
                if found {
                    res.lock().unwrap().insert(k, v);
                }
            });

            let mut local = 0i32;
            for i in 0..N {
                let key = format!("{}_{}", tag, i);
                let val = format!("{}_val_{}", tag, i);
                if !be.store(key.clone(), val.clone()).is_ok() {
                    continue;
                }
                if !be.read(key.clone()).is_ok() {
                    continue;
                }
                let k = key.clone();
                let r = results.clone();
                let got = wait_for(
                    move || r.lock().unwrap().contains_key(&k),
                    Duration::from_secs(5),
                );
                if got {
                    let r = results.lock().unwrap();
                    if r.get(&key).map(|v2| v2 == &val).unwrap_or(false) {
                        local += 1;
                    }
                }
            }

            be.off_read_completed(h);
            ok_count.store(local, Ordering::SeqCst);

            // No barrier: each context's sub-instance close() + shutdown() must
            // be fully isolated from the sibling context still delivering events.
            be.close();
            p.shutdown();
        }
    };

    let of = ok_file.clone();
    let om = ok_mem.clone();
    let t_file = thread::spawn(run_lib(KIND_FILE, "fileLib", of));
    let t_mem = thread::spawn(run_lib(KIND_MEMORY, "memLib", om));
    t_file.join().unwrap();
    t_mem.join().unwrap();

    let f = ok_file.load(Ordering::SeqCst);
    let m = ok_mem.load(Ordering::SeqCst);
    println!("      File lib: {f}/{N}  Memory lib: {m}/{N} roundtrips OK");
    assert_eq!(f as usize, N, "File roundtrips: {f}/{N}");
    assert_eq!(m as usize, N, "Memory roundtrips: {m}/{N}");
}

fn main() {
    println!("persistence version: {}", Persistence::version());
    scenario_two_contexts();
    scenario_mixed_one_context();
    scenario_concurrent_load();
    println!("persistence rust example: OK");
}
