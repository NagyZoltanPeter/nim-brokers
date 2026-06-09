// Rust port of test_typemappingtestlib.cpp — exercises every Nim→Rust
// type mapping through the generated Rust wrapper (typemappingtestlib_rs).
// One Rust function per C++ test, preserved in the same order.
//
//     cargo run   # builds against the FFI library in build/

#[path = "../../build/typemappingtestlib_rs/src/lib.rs"]
mod lib;

use lib::{Inner, KeyRange, Slot, Tag, Typemappingtestlib};
use std::collections::HashMap;
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Minimal test framework
// ---------------------------------------------------------------------------

static G_TOTAL: AtomicUsize = AtomicUsize::new(0);
static G_FAILED: AtomicUsize = AtomicUsize::new(0);
static G_CURRENT_FAILED: AtomicUsize = AtomicUsize::new(0);

fn check_impl(file: &str, line: u32, expr: &str, ok: bool) {
    if !ok {
        eprintln!("  FAIL {}:{}: {}", file, line, expr);
        G_CURRENT_FAILED.store(1, Ordering::SeqCst);
    }
}

macro_rules! check {
    ($cond:expr) => {{
        let __c = $cond;
        check_impl(file!(), line!(), stringify!($cond), __c);
    }};
}

macro_rules! check_eq {
    ($a:expr, $b:expr) => {{
        let __a = $a;
        let __b = $b;
        let __ok = __a == __b;
        if !__ok {
            eprintln!(
                "  FAIL {}:{}: {} == {} (got {:?} vs {:?})",
                file!(),
                line!(),
                stringify!($a),
                stringify!($b),
                __a,
                __b
            );
            G_CURRENT_FAILED.store(1, Ordering::SeqCst);
        }
    }};
}

macro_rules! check_ne {
    ($a:expr, $b:expr) => {{
        let __a = $a;
        let __b = $b;
        let __ok = __a != __b;
        if !__ok {
            eprintln!(
                "  FAIL {}:{}: {} != {}",
                file!(),
                line!(),
                stringify!($a),
                stringify!($b)
            );
            G_CURRENT_FAILED.store(1, Ordering::SeqCst);
        }
    }};
}

macro_rules! check_near {
    ($a:expr, $b:expr, $eps:expr) => {{
        let __a: f64 = $a as f64;
        let __b: f64 = $b as f64;
        let __eps: f64 = $eps as f64;
        if (__a - __b).abs() > __eps {
            eprintln!(
                "  FAIL {}:{}: |{} - {}| <= {}",
                file!(),
                line!(),
                stringify!($a),
                stringify!($b),
                __eps
            );
            G_CURRENT_FAILED.store(1, Ordering::SeqCst);
        }
    }};
}

fn run_test(name: &str, f: fn()) {
    G_CURRENT_FAILED.store(0, Ordering::SeqCst);
    G_TOTAL.fetch_add(1, Ordering::SeqCst);
    print!("  {:<60}", name);
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
    if res.is_err() {
        eprintln!("  PANIC in {}", name);
        G_CURRENT_FAILED.store(1, Ordering::SeqCst);
    }
    if G_CURRENT_FAILED.load(Ordering::SeqCst) != 0 {
        println!("FAIL");
        G_FAILED.fetch_add(1, Ordering::SeqCst);
    } else {
        println!("ok");
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn wait_for<F: FnMut() -> bool>(mut pred: F, timeout_secs: f64) -> bool {
    let deadline = Instant::now() + Duration::from_secs_f64(timeout_secs);
    while !pred() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    pred()
}

fn wait_for_default<F: FnMut() -> bool>(pred: F) -> bool {
    wait_for(pred, 2.0)
}

fn sleep_ms(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

fn make_tag(key: &str, value: &str) -> Tag {
    Tag {
        key: key.to_string(),
        value: value.to_string(),
    }
}

const K_CONST_ARRAY_LEN: usize = 6;

type SafeList<T> = Arc<Mutex<Vec<T>>>;

fn list_new<T>() -> SafeList<T> {
    Arc::new(Mutex::new(Vec::new()))
}

fn list_push<T>(l: &SafeList<T>, v: T) {
    l.lock().unwrap().push(v);
}

fn list_size<T>(l: &SafeList<T>) -> usize {
    l.lock().unwrap().len()
}

fn list_snapshot<T: Clone>(l: &SafeList<T>) -> Vec<T> {
    l.lock().unwrap().clone()
}

// ===========================================================================
// TestLifecycle
// ===========================================================================

fn test_lifecycle_create_and_shutdown() {
    let mut lib = Typemappingtestlib::new();
    check!(!lib.valid_context());
    let r = lib.create_context();
    check!(r.is_ok());
    check!(lib.valid_context());
    check_ne!(lib.ctx(), 0u32);
    lib.shutdown();
    check!(!lib.valid_context());
}

fn test_lifecycle_raii_shutdown() {
    let mut saved_ctx: u32 = 0;
    {
        let mut lib = Typemappingtestlib::new();
        let _ = lib.create_context();
        saved_ctx = lib.ctx();
        check_ne!(saved_ctx, 0u32);
    }
    check_ne!(saved_ctx, 0u32);
}

fn test_lifecycle_double_shutdown_is_safe() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    lib.shutdown();
    lib.shutdown();
}

fn test_lifecycle_double_create_returns_error() {
    let mut lib = Typemappingtestlib::new();
    let r1 = lib.create_context();
    check!(r1.is_ok());
    let r2 = lib.create_context();
    check!(!r2.is_ok());
    lib.shutdown();
}

fn test_lifecycle_request_without_context_fails() {
    let lib = Typemappingtestlib::new();
    let r = lib.echo_request("hello".to_string());
    check!(!r.is_ok());
}

// ===========================================================================
// TestRequests
// ===========================================================================

fn test_requests_initialize() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.initialize_request("test-label".to_string());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.label, &"test-label".to_string());
    }
    lib.shutdown();
}

fn test_requests_echo() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let _ = lib.initialize_request("ctx-A".to_string());
    let r = lib.echo_request("hello".to_string());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.reply, &"ctx-A:hello".to_string());
    }
    lib.shutdown();
}

fn test_requests_counter_increments() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    for expected in 1i32..=3 {
        let r = lib.counter_request();
        check!(r.is_ok());
        if let Some(v) = r.value() {
            check_eq!(v.value, expected);
        }
    }
    lib.shutdown();
}

fn test_requests_multiple_echo() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let _ = lib.initialize_request("multi".to_string());
    for i in 0..5 {
        let r = lib.echo_request(format!("msg-{}", i));
        check!(r.is_ok());
        if let Some(v) = r.value() {
            check_eq!(&v.reply, &format!("multi:msg-{}", i));
        }
    }
    lib.shutdown();
}

fn test_dual_sig_zero() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.dual_sig_request_zero();
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.label, &"zero".to_string());
        check_eq!(v.counter, 0);
    }
    lib.shutdown();
}

fn test_dual_sig_with_label() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.dual_sig_request_with_label("hello".to_string(), 7);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.label, &"hello".to_string());
        check_eq!(v.counter, 7);
    }
    lib.shutdown();
}

// ===========================================================================
// TestPrimitiveBrokerTypes — non-object (primitive) request result + event
// payload. IntResultRequest is `type X = int32`; SimpleIntEvent is
// `type X = int64`. Native mode exposes the result as a struct with a single
// `value` field; CBOR mode exposes it as the bare `i32` type alias.
// ===========================================================================

fn test_primitive_int_result_request() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.int_result_request(21);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(*v, 42); // IntResultRequest is the bare i32 alias
    }
    lib.shutdown();
}

fn test_primitive_simple_int_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let received: SafeList<i64> = list_new();
    let received_cb = received.clone();
    let h = lib.on_simple_int_event(move |v: i64| {
        list_push(&received_cb, v);
    });
    check_ne!(h, 0u64);

    let _ = lib.int_result_request(5); // provider emits SimpleIntEvent(value * 10)
    let received_w = received.clone();
    wait_for_default(|| list_size(&received_w) >= 1);

    check_eq!(list_size(&received), 1usize);
    check_eq!(list_snapshot(&received)[0], 50i64);

    lib.off_simple_int_event(h);
    lib.shutdown();
}

// ===========================================================================
// TestVoidBrokerTypes — payload-less request + event. VoidActionRequest is
// `type X = void`; VoidPing is a `void` event. The result carries only an
// ok/err signal; the event callback takes no payload argument.
// ===========================================================================

fn test_void_action_request() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let ok = lib.void_action_request("go".to_string());
    check!(ok.is_ok());

    let bad = lib.void_action_request("".to_string()); // provider rejects empty
    check!(!bad.is_ok());

    lib.shutdown();
}

fn test_void_ping_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let received: SafeList<i32> = list_new();
    let received_cb = received.clone();
    let h = lib.on_void_ping(move || {
        list_push(&received_cb, 1);
    });
    check_ne!(h, 0u64);

    let _ = lib.void_action_request("trigger".to_string()); // provider emits VoidPing
    let received_w = received.clone();
    wait_for_default(|| list_size(&received_w) >= 1);

    check_eq!(list_size(&received), 1usize);

    lib.off_void_ping(h);
    lib.shutdown();
}

// ===========================================================================
// TestEvents
// ===========================================================================

fn test_events_counter_changed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let ctx = lib.ctx();

    let received: SafeList<(u32, i32)> = list_new();
    let received_cb = received.clone();
    let h = lib.on_counter_changed(move |v: i32| {
        list_push(&received_cb, (ctx, v));
    });
    check_ne!(h, 0u64);

    let _ = lib.counter_request();
    let _ = lib.counter_request();
    let _ = lib.counter_request();
    let received_w = received.clone();
    wait_for_default(|| list_size(&received_w) >= 3);

    check_eq!(list_size(&received), 3usize);
    let snap = list_snapshot(&received);
    for (i, p) in snap.iter().enumerate() {
        check_eq!(p.1, (i as i32) + 1);
    }
    for (c, _) in &snap {
        check_eq!(*c, ctx);
    }

    lib.off_counter_changed(h);
    lib.shutdown();
}

fn test_events_off_stops_delivery() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let received: SafeList<i32> = list_new();
    let cb = received.clone();
    let h = lib.on_counter_changed(move |v: i32| list_push(&cb, v));

    let _ = lib.counter_request();
    let w = received.clone();
    wait_for_default(|| list_size(&w) >= 1);

    lib.off_counter_changed(h);
    let count_after_off = list_size(&received);

    let _ = lib.counter_request();
    sleep_ms(300);
    check_eq!(list_size(&received), count_after_off);

    lib.shutdown();
}

// ===========================================================================
// TestContextSeparation
// ===========================================================================

fn test_context_independent_counters() {
    let mut lib1 = Typemappingtestlib::new();
    let mut lib2 = Typemappingtestlib::new();
    let _ = lib1.create_context();
    let _ = lib2.create_context();
    check_ne!(lib1.ctx(), lib2.ctx());

    let _ = lib1.initialize_request("alpha".to_string());
    let _ = lib2.initialize_request("beta".to_string());

    for i in 1i32..=3 {
        let r = lib1.counter_request();
        if let Some(v) = r.value() {
            check_eq!(v.value, i);
        }
    }
    for i in 1i32..=2 {
        let r = lib2.counter_request();
        if let Some(v) = r.value() {
            check_eq!(v.value, i);
        }
    }
    let r = lib1.counter_request();
    if let Some(v) = r.value() {
        check_eq!(v.value, 4);
    }

    lib1.shutdown();
    lib2.shutdown();
    sleep_ms(50);
}

fn test_context_independent_echo() {
    let mut lib1 = Typemappingtestlib::new();
    let mut lib2 = Typemappingtestlib::new();
    let _ = lib1.create_context();
    let _ = lib2.create_context();
    let _ = lib1.initialize_request("one".to_string());
    let _ = lib2.initialize_request("two".to_string());

    let r1 = lib1.echo_request("x".to_string());
    if let Some(v) = r1.value() {
        check_eq!(&v.reply, &"one:x".to_string());
    }
    let r2 = lib2.echo_request("x".to_string());
    if let Some(v) = r2.value() {
        check_eq!(&v.reply, &"two:x".to_string());
    }

    lib1.shutdown();
    lib2.shutdown();
    sleep_ms(50);
}

#[allow(dead_code)]
fn test_context_independent_events() {
    let events1: SafeList<i32> = list_new();
    let events2: SafeList<i32> = list_new();

    let mut lib1 = Typemappingtestlib::new();
    let mut lib2 = Typemappingtestlib::new();
    let _ = lib1.create_context();
    let _ = lib2.create_context();

    let e1 = events1.clone();
    let h1 = lib1.on_counter_changed(move |v: i32| list_push(&e1, v));
    let e2 = events2.clone();
    let h2 = lib2.on_counter_changed(move |v: i32| list_push(&e2, v));

    let _ = lib1.counter_request();
    let _ = lib1.counter_request();
    let _ = lib2.counter_request();

    let w1 = events1.clone();
    let w2 = events2.clone();
    wait_for_default(|| list_size(&w1) >= 2 && list_size(&w2) >= 1);

    let snap1 = list_snapshot(&events1);
    let snap2 = list_snapshot(&events2);
    check_eq!(snap1.len(), 2usize);
    check_eq!(snap2.len(), 1usize);
    if snap1.len() >= 2 {
        check_eq!(snap1[0], 1);
        check_eq!(snap1[1], 2);
    }
    if !snap2.is_empty() {
        check_eq!(snap2[0], 1);
    }

    lib1.off_counter_changed(h1);
    lib2.off_counter_changed(h2);
    lib1.shutdown();
    lib2.shutdown();
    sleep_ms(50);
}

fn test_context_shutdown_one_does_not_affect_other() {
    let mut lib1 = Typemappingtestlib::new();
    let mut lib2 = Typemappingtestlib::new();
    let _ = lib1.create_context();
    let _ = lib2.create_context();

    let _ = lib1.initialize_request("first".to_string());
    let _ = lib2.initialize_request("second".to_string());

    lib1.shutdown();

    let r = lib2.echo_request("still-alive".to_string());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.reply, &"second:still-alive".to_string());
    }

    lib2.shutdown();
    sleep_ms(50);
}

// ===========================================================================
// TestScalarTypes
// ===========================================================================

fn test_scalar_bool_true() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_scalar_request(true, 0, 0, 0.0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.flag == true);
    }
    lib.shutdown();
}

fn test_scalar_bool_false() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_scalar_request(false, 0, 0, 0.0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.flag == false);
    }
    lib.shutdown();
}

fn test_scalar_int32_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r1 = lib.prim_scalar_request(false, i32::MIN, 0, 0.0);
    check!(r1.is_ok());
    if let Some(v) = r1.value() {
        check_eq!(v.i32, i32::MIN);
    }
    let r2 = lib.prim_scalar_request(false, i32::MAX, 0, 0.0);
    check!(r2.is_ok());
    if let Some(v) = r2.value() {
        check_eq!(v.i32, i32::MAX);
    }
    lib.shutdown();
}

fn test_scalar_int64_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let big: i64 = 9_000_000_000_000;
    let r = lib.prim_scalar_request(false, 0, big, 0.0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.i64, big);
    }
    lib.shutdown();
}

fn test_scalar_float64_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let pi = 3.141592653589793_f64;
    let r = lib.prim_scalar_request(false, 0, 0, pi);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_near!(v.f64, pi, 1e-12);
    }
    lib.shutdown();
}

fn test_scalar_all_fields_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_scalar_request(true, 42, 1_000_000_000, 2.718);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.flag == true);
        check_eq!(v.i32, 42);
        check_eq!(v.i64, 1_000_000_000_i64);
        check_near!(v.f64, 2.718, 1e-12);
    }
    lib.shutdown();
}

fn test_scalar_prim_scalar_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<(bool, i32, i64, f64)> = list_new();
    let cb = evts.clone();
    let h = lib.on_prim_scalar_event(move |flag: bool, a: i32, b: i64, c: f64| {
        list_push(&cb, (flag, a, b, c));
    });

    let _ = lib.prim_scalar_request(true, 7, 777_777, 1.5);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let e = &snap[0];
        check!(e.0 == true);
        check_eq!(e.1, 7);
        check_eq!(e.2, 777_777_i64);
        check_near!(e.3, 1.5, 1e-12);
    }

    lib.off_prim_scalar_event(h);
    lib.shutdown();
}

fn test_scalar_prim_scalar_event_false_flag() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<bool> = list_new();
    let cb = evts.clone();
    let h = lib.on_prim_scalar_event(move |flag: bool, _a: i32, _b: i64, _c: f64| {
        list_push(&cb, flag);
    });

    let _ = lib.prim_scalar_request(false, 0, 0, 0.0);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        check!(snap[0] == false);
    }

    lib.off_prim_scalar_event(h);
    lib.shutdown();
}

// ===========================================================================
// TestEnumDistinctTypes
// ===========================================================================

fn test_enum_roundtrip_low() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.typed_scalar_request(lib::Priority::pLow, 10);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.priority, lib::Priority::pLow);
        check_eq!(v.priority as i32, 0);
    }
    lib.shutdown();
}

fn test_enum_roundtrip_high() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.typed_scalar_request(lib::Priority::pHigh, 1);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.priority, lib::Priority::pHigh);
        check_eq!(v.priority as i32, 2);
    }
    lib.shutdown();
}

fn test_enum_roundtrip_critical() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.typed_scalar_request(lib::Priority::pCritical, 1);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.priority as i32, 3);
    }
    lib.shutdown();
}

fn test_distinct_jobid_echoed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.typed_scalar_request(lib::Priority::pLow, 5);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.jobId, 5);
    }
    lib.shutdown();
}

fn test_distinct_jobid_next() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.typed_scalar_request(lib::Priority::pLow, 5);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.nextId, 6);
    }
    lib.shutdown();
}

fn test_distinct_jobid_zero() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.typed_scalar_request(lib::Priority::pMedium, 0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.jobId, 0);
        check_eq!(v.nextId, 1);
    }
    lib.shutdown();
}

fn test_all_priority_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let priorities = [
        lib::Priority::pLow,
        lib::Priority::pMedium,
        lib::Priority::pHigh,
        lib::Priority::pCritical,
    ];
    for p in priorities.iter().copied() {
        let r = lib.typed_scalar_request(p, 1);
        check!(r.is_ok());
        if let Some(v) = r.value() {
            check_eq!(v.priority, p);
        }
    }
    lib.shutdown();
}

fn test_typed_scalar_event_enum() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<(lib::Priority, i32, i64)> = list_new();
    let cb = evts.clone();
    let h = lib.on_typed_scalar_event(move |p, jid, ts| {
        list_push(&cb, (p, jid as i32, ts as i64));
    });

    let _ = lib.typed_scalar_request(lib::Priority::pHigh, 7);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let e = &snap[0];
        check_eq!(e.0, lib::Priority::pHigh);
        check_eq!(e.0 as i32, 2);
        check_eq!(e.1, 7);
        check_eq!(e.2, 70_i64);
    }

    lib.off_typed_scalar_event(h);
    lib.shutdown();
}

fn test_typed_scalar_event_distinct_timestamp() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<i64> = list_new();
    let cb = evts.clone();
    let h = lib.on_typed_scalar_event(move |_p, _jid, ts| {
        list_push(&cb, ts as i64);
    });

    let _ = lib.typed_scalar_request(lib::Priority::pLow, 3);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        check_eq!(snap[0], 30_i64);
    }

    lib.off_typed_scalar_event(h);
    lib.shutdown();
}

fn test_fixedarray_result_contains_timestamp() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.fixed_array_request(99);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.ts as i64, 99_i64);
    }
    lib.shutdown();
}

// ===========================================================================
// TestSeqByteResult
// ===========================================================================

fn test_seq_byte_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.byte_seq_request(0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.data.is_empty());
    }
    lib.shutdown();
}

fn test_seq_byte_length() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.byte_seq_request(8);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.data.len(), 8usize);
    }
    lib.shutdown();
}

fn test_seq_byte_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.byte_seq_request(5);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.data.len(), 5usize);
        for i in 0..v.data.len() {
            check_eq!(v.data[i], i as u8);
        }
    }
    lib.shutdown();
}

fn test_seq_byte_wrap_around() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.byte_seq_request(260);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.data.len(), 260usize);
        check_eq!(v.data[0], 0u8);
        check_eq!(v.data[255], 255u8);
        check_eq!(v.data[256], 0u8);
    }
    lib.shutdown();
}

fn test_seq_byte_single_element() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.byte_seq_request(1);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.data.len(), 1usize);
        check_eq!(v.data[0], 0u8);
    }
    lib.shutdown();
}

fn test_seq_byte_large() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.byte_seq_request(100);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.data.len(), 100usize);
        for i in 0..v.data.len() {
            check_eq!(v.data[i], (i % 256) as u8);
        }
    }
    lib.shutdown();
}

// ===========================================================================
// TestSeqStringTypes
// ===========================================================================

fn test_seq_string_result_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.string_seq_request("x".to_string(), 0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.items.is_empty());
    }
    lib.shutdown();
}

fn test_seq_string_result_count() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.string_seq_request("item".to_string(), 4);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.items.len(), 4usize);
    }
    lib.shutdown();
}

fn test_seq_string_result_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.string_seq_request("tag".to_string(), 3);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.items.len(), 3usize);
        check_eq!(&v.items[0], &"tag-0".to_string());
        check_eq!(&v.items[1], &"tag-1".to_string());
        check_eq!(&v.items[2], &"tag-2".to_string());
    }
    lib.shutdown();
}

fn test_seq_string_result_special_chars() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.string_seq_request("a/b:c".to_string(), 2);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.items.len(), 2usize);
        check_eq!(&v.items[0], &"a/b:c-0".to_string());
        check_eq!(&v.items[1], &"a/b:c-1".to_string());
    }
    lib.shutdown();
}

fn test_seq_string_param_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.seq_string_param_request(Vec::<String>::new());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 0);
        check_eq!(&v.joined, &"".to_string());
    }
    lib.shutdown();
}

fn test_seq_string_param_single() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.seq_string_param_request(vec!["hello".to_string()]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 1);
        check_eq!(&v.joined, &"hello".to_string());
    }
    lib.shutdown();
}

fn test_seq_string_param_multiple() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.seq_string_param_request(vec![
        "alpha".to_string(),
        "beta".to_string(),
        "gamma".to_string(),
    ]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 3);
        check_eq!(&v.joined, &"alpha,beta,gamma".to_string());
    }
    lib.shutdown();
}

fn test_seq_string_param_unicode() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.seq_string_param_request(vec!["héllo".to_string(), "wörld".to_string()]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 2);
        check_eq!(&v.joined, &"héllo,wörld".to_string());
    }
    lib.shutdown();
}

fn test_string_seq_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<String>> = list_new();
    let cb = evts.clone();
    let h = lib.on_string_seq_event(move |items: Vec<String>| {
        list_push(&cb, items);
    });

    let _ = lib.string_seq_request("ev".to_string(), 3);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let s = &snap[0];
        check_eq!(s.len(), 3usize);
        check_eq!(&s[0], &"ev-0".to_string());
        check_eq!(&s[1], &"ev-1".to_string());
        check_eq!(&s[2], &"ev-2".to_string());
    }

    lib.off_string_seq_event(h);
    lib.shutdown();
}

fn test_string_seq_event_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<String>> = list_new();
    let cb = evts.clone();
    let h = lib.on_string_seq_event(move |items: Vec<String>| list_push(&cb, items));

    let _ = lib.string_seq_request("x".to_string(), 0);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        check!(snap[0].is_empty());
    }

    lib.off_string_seq_event(h);
    lib.shutdown();
}

// ===========================================================================
// TestSeqPrimTypes
// ===========================================================================

fn test_prim_seq_result_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_seq_request(0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.values.is_empty());
    }
    lib.shutdown();
}

fn test_prim_seq_result_length() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_seq_request(5);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values.len(), 5usize);
    }
    lib.shutdown();
}

fn test_prim_seq_result_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_seq_request(4);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values.len(), 4usize);
        for i in 0..v.values.len() {
            check_eq!(v.values[i], (i as i64) * 10);
        }
    }
    lib.shutdown();
}

fn test_prim_seq_result_large_int64() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_seq_request(3);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values[2], 20_i64);
    }
    lib.shutdown();
}

fn test_prim_seq_param_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_seq_param_request(Vec::<i64>::new());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 0);
        check_eq!(v.total, 0_i64);
    }
    lib.shutdown();
}

fn test_prim_seq_param_single() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_seq_param_request(vec![42_i64]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 1);
        check_eq!(v.total, 42_i64);
    }
    lib.shutdown();
}

fn test_prim_seq_param_sum() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.prim_seq_param_request(vec![1, 2, 3, 4, 5]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 5);
        check_eq!(v.total, 15_i64);
    }
    lib.shutdown();
}

fn test_prim_seq_param_large_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let big: i64 = 1_000_000_000_000;
    let r = lib.prim_seq_param_request(vec![big, big]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 2);
        check_eq!(v.total, 2 * big);
    }
    lib.shutdown();
}

fn test_prim_seq_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i64>> = list_new();
    let cb = evts.clone();
    let h = lib.on_prim_seq_event(move |values: Vec<i64>| list_push(&cb, values));

    let _ = lib.prim_seq_request(3);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let s = &snap[0];
        check_eq!(s.len(), 3usize);
        check_eq!(s[0], 0_i64);
        check_eq!(s[1], 10_i64);
        check_eq!(s[2], 20_i64);
    }

    lib.off_prim_seq_event(h);
    lib.shutdown();
}

fn test_prim_seq_event_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i64>> = list_new();
    let cb = evts.clone();
    let h = lib.on_prim_seq_event(move |values: Vec<i64>| list_push(&cb, values));

    let _ = lib.prim_seq_request(0);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        check!(snap[0].is_empty());
    }

    lib.off_prim_seq_event(h);
    lib.shutdown();
}

// ===========================================================================
// TestFixedArrayTypes
// ===========================================================================

fn test_array_result_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.fixed_array_request(5);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values[0], 5);
        check_eq!(v.values[1], 10);
        check_eq!(v.values[2], 15);
        check_eq!(v.values[3], 20);
    }
    lib.shutdown();
}

fn test_array_result_length() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.fixed_array_request(1);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values.len(), 4usize);
    }
    lib.shutdown();
}

fn test_array_result_seed_zero() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.fixed_array_request(0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        for x in &v.values {
            check_eq!(*x, 0);
        }
    }
    lib.shutdown();
}

fn test_array_result_negative_seed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.fixed_array_request(-3);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values[0], -3);
        check_eq!(v.values[1], -6);
        check_eq!(v.values[2], -9);
        check_eq!(v.values[3], -12);
    }
    lib.shutdown();
}

fn test_array_result_timestamp() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.fixed_array_request(42);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.ts as i64, 42_i64);
    }
    lib.shutdown();
}

fn test_fixed_array_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i32>> = list_new();
    let cb = evts.clone();
    let h = lib.on_fixed_array_event(move |values: Vec<i32>| list_push(&cb, values));

    let _ = lib.fixed_array_request(3);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let s = &snap[0];
        check_eq!(s.len(), 4usize);
        check_eq!(s[0], 3);
        check_eq!(s[1], 6);
        check_eq!(s[2], 9);
        check_eq!(s[3], 12);
    }

    lib.off_fixed_array_event(h);
    lib.shutdown();
}

fn test_fixed_array_event_zero_seed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i32>> = list_new();
    let cb = evts.clone();
    let h = lib.on_fixed_array_event(move |values: Vec<i32>| list_push(&cb, values));

    let _ = lib.fixed_array_request(0);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        for x in &snap[0] {
            check_eq!(*x, 0);
        }
    }

    lib.off_fixed_array_event(h);
    lib.shutdown();
}

fn test_fixed_array_multiple_requests() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i32>> = list_new();
    let cb = evts.clone();
    let h = lib.on_fixed_array_event(move |values: Vec<i32>| list_push(&cb, values));

    let _ = lib.fixed_array_request(1);
    let _ = lib.fixed_array_request(2);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 2);

    check_eq!(list_size(&evts), 2usize);
    let snap = list_snapshot(&evts);
    if snap.len() >= 2 {
        let e0 = &snap[0];
        let e1 = &snap[1];
        check_eq!(e0.len(), 4usize);
        check_eq!(e1.len(), 4usize);
        check_eq!(e0[0], 1);
        check_eq!(e0[1], 2);
        check_eq!(e0[2], 3);
        check_eq!(e0[3], 4);
        check_eq!(e1[0], 2);
        check_eq!(e1[1], 4);
        check_eq!(e1[2], 6);
        check_eq!(e1[3], 8);
    }

    lib.off_fixed_array_event(h);
    lib.shutdown();
}

// ===========================================================================
// TestSeqObjectTypes
// ===========================================================================

fn test_obj_seq_param_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.obj_seq_param_request(Vec::<Tag>::new());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 0);
        check_eq!(&v.first, &"".to_string());
    }
    lib.shutdown();
}

fn test_obj_seq_param_single() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let tags = vec![make_tag("mykey", "myval")];
    let r = lib.obj_seq_param_request(tags);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 1);
        check_eq!(&v.first, &"mykey".to_string());
    }
    lib.shutdown();
}

fn test_obj_seq_param_multiple() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let tags = vec![
        make_tag("first", "1"),
        make_tag("second", "2"),
        make_tag("third", "3"),
    ];
    let r = lib.obj_seq_param_request(tags);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 3);
        check_eq!(&v.first, &"first".to_string());
    }
    lib.shutdown();
}

fn test_obj_seq_param_string_encoding() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let tags = vec![make_tag("key with spaces", "value/path")];
    let r = lib.obj_seq_param_request(tags);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 1);
        check_eq!(&v.first, &"key with spaces".to_string());
    }
    lib.shutdown();
}

fn test_obj_as_param() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.obj_param_request(make_tag("k", "v"));
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.summary, &"k=v".to_string());
    }
    lib.shutdown();
}

// Native + CBOR Option[int32] probe (Phase E1).
fn test_opt_scalar_present() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_scalar_request(true);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.value, Some(42i32));
    }
    lib.shutdown();
}

fn test_opt_scalar_absent() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_scalar_request(false);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.value, None::<i32>);
    }
    lib.shutdown();
}

// Phase E2a — Option[string]. Native + CBOR.
fn test_opt_string_present() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_string_request(true);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.value.clone(), Some("hello".to_string()));
    }
    lib.shutdown();
}

fn test_opt_string_absent() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_string_request(false);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.value.clone(), None::<String>);
    }
    lib.shutdown();
}

// Phase E3 — Option[Tag] (Option of a registered object). Native + CBOR.
fn test_opt_obj_present() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_obj_request(true);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.value.is_some());
        if let Some(t) = &v.value {
            check_eq!(&t.key, &"ok".to_string());
            check_eq!(&t.value, &"yes".to_string());
        }
    }
    lib.shutdown();
}

fn test_opt_obj_absent() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_obj_request(false);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.value.is_none());
    }
    lib.shutdown();
}

// Option[seq[byte]] probe — works in BOTH native (E2b) and CBOR builds.
// Wrapper maps to `Option<Vec<u8>>`.
fn test_opt_seq_present() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_seq_request(true);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.value.clone(), Some(vec![1u8, 2, 3, 4]));
    }
    lib.shutdown();
}

fn test_opt_seq_absent() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.opt_seq_request(false);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.value.clone(), None::<Vec<u8>>);
    }
    lib.shutdown();
}

// Inbound `seq[byte]` probe — verifies the Rust args struct serialises
// `Vec<u8>` as a CBOR byte string (via `#[serde(with = "serde_bytes")]`)
// rather than a sequence-of-int that the Nim decoder rejects.
fn test_bytes_echo_request_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.bytes_echo_request(vec![10u8, 20, 30, 40, 50]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.length, 5i32);
        check_eq!(v.first, 10i32);
        check_eq!(v.last, 50i32);
    }
    lib.shutdown();
}

fn test_bytes_echo_request_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.bytes_echo_request(Vec::<u8>::new());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.length, 0i32);
        check_eq!(v.first, -1i32);
        check_eq!(v.last, -1i32);
    }
    lib.shutdown();
}

fn test_scan_request_forward() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let kr = KeyRange { startKey: "lo".to_string(), stopKey: "hi".to_string() };
    let r = lib.scan_request("scan".to_string(), kr, false);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.rows.len(), 3);
        check_eq!(&v.rows[0].key, &"0:lo".to_string());
        check_eq!(&v.rows[2].key, &"2:lo".to_string());
        check_eq!(&v.rows[0].payload, &"scan-row-0:hi".to_string());
    }
    lib.shutdown();
}

fn test_scan_request_reverse() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let kr = KeyRange { startKey: "lo".to_string(), stopKey: "hi".to_string() };
    let r = lib.scan_request("scan".to_string(), kr, true);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.rows.len(), 3);
        check_eq!(&v.rows[0].key, &"2:lo".to_string());
        check_eq!(&v.rows[2].key, &"0:lo".to_string());
    }
    lib.shutdown();
}

fn test_obj_seq_result_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.obj_seq_result_request(0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.tags.is_empty());
    }
    lib.shutdown();
}

fn test_obj_seq_result_length() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.obj_seq_result_request(4);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.tags.len(), 4usize);
    }
    lib.shutdown();
}

fn test_obj_seq_result_keys() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.obj_seq_result_request(3);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.tags.len(), 3usize);
        check_eq!(&v.tags[0].key, &"key-0".to_string());
        check_eq!(&v.tags[1].key, &"key-1".to_string());
        check_eq!(&v.tags[2].key, &"key-2".to_string());
    }
    lib.shutdown();
}

fn test_obj_seq_result_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.obj_seq_result_request(3);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.tags[0].value, &"val-0".to_string());
        check_eq!(&v.tags[1].value, &"val-1".to_string());
        check_eq!(&v.tags[2].value, &"val-2".to_string());
    }
    lib.shutdown();
}

fn test_obj_seq_result_tag_fields() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.obj_seq_result_request(2);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        for tag in &v.tags {
            check!(!tag.key.is_empty());
            check!(!tag.value.is_empty());
        }
    }
    lib.shutdown();
}

fn test_obj_seq_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let gen = lib.obj_seq_result_request(3);
    check!(gen.is_ok());
    let tags = gen.value().map(|v| v.tags.clone()).unwrap_or_default();
    let r = lib.obj_seq_param_request(tags);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.count, 3);
        check_eq!(&v.first, &"key-0".to_string());
    }
    lib.shutdown();
}

// ===========================================================================
// TestConstArraySize
// ===========================================================================

fn test_const_array_result_length() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.const_array_request(1);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values.len(), K_CONST_ARRAY_LEN);
    }
    lib.shutdown();
}

fn test_const_array_result_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.const_array_request(3);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.values.len(), K_CONST_ARRAY_LEN);
        let expected = [3, 6, 9, 12, 15, 18];
        for i in 0..K_CONST_ARRAY_LEN {
            check_eq!(v.values[i], expected[i]);
        }
    }
    lib.shutdown();
}

fn test_const_array_result_zero_seed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.const_array_request(0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        for x in &v.values {
            check_eq!(*x, 0);
        }
    }
    lib.shutdown();
}

fn test_const_array_result_negative_seed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.const_array_request(-2);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        let expected = [-2, -4, -6, -8, -10, -12];
        for i in 0..K_CONST_ARRAY_LEN {
            check_eq!(v.values[i], expected[i]);
        }
    }
    lib.shutdown();
}

fn test_const_array_event_values() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i32>> = list_new();
    let cb = evts.clone();
    let h = lib.on_const_array_event(move |values: Vec<i32>| list_push(&cb, values));

    let _ = lib.const_array_request(2);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let s = &snap[0];
        check_eq!(s.len(), K_CONST_ARRAY_LEN);
        let expected = [2, 4, 6, 8, 10, 12];
        for i in 0..K_CONST_ARRAY_LEN {
            check_eq!(s[i], expected[i]);
        }
    }

    lib.off_const_array_event(h);
    lib.shutdown();
}

fn test_const_array_event_length() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i32>> = list_new();
    let cb = evts.clone();
    let h = lib.on_const_array_event(move |values: Vec<i32>| list_push(&cb, values));

    let _ = lib.const_array_request(1);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        check_eq!(snap[0].len(), K_CONST_ARRAY_LEN);
    } else {
        check!(false);
    }

    lib.off_const_array_event(h);
    lib.shutdown();
}

fn test_const_array_event_neg_seed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i32>> = list_new();
    let cb = evts.clone();
    let h = lib.on_const_array_event(move |values: Vec<i32>| list_push(&cb, values));

    let _ = lib.const_array_request(-2);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let s = &snap[0];
        let expected = vec![-2, -4, -6, -8, -10, -12];
        check_eq!(s.len(), expected.len());
        for i in 0..s.len().min(expected.len()) {
            check_eq!(s[i], expected[i]);
        }
    }

    lib.off_const_array_event(h);
    lib.shutdown();
}

fn test_distinct_jobid_max_minus_one() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.typed_scalar_request(lib::Priority::pLow, i32::MAX - 1);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.jobId, i32::MAX - 1);
        check_eq!(v.nextId, i32::MAX);
    }
    lib.shutdown();
}

fn test_const_array_event_zero_seed() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts: SafeList<Vec<i32>> = list_new();
    let cb = evts.clone();
    let h = lib.on_const_array_event(move |values: Vec<i32>| list_push(&cb, values));

    let _ = lib.const_array_request(0);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);

    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        for x in &snap[0] {
            check_eq!(*x, 0);
        }
    }

    lib.off_const_array_event(h);
    lib.shutdown();
}

// ===========================================================================
// TestMultipleEventListeners
// ===========================================================================

#[allow(dead_code)]
fn test_two_scalar_event_listeners() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts1: SafeList<i32> = list_new();
    let evts2: SafeList<i32> = list_new();

    let c1 = evts1.clone();
    let h1 = lib.on_prim_scalar_event(move |_flag, i: i32, _b, _c| list_push(&c1, i));
    let c2 = evts2.clone();
    let h2 = lib.on_prim_scalar_event(move |_flag, i: i32, _b, _c| list_push(&c2, i));

    let _ = lib.prim_scalar_request(false, 99, 0, 0.0);
    let w1 = evts1.clone();
    let w2 = evts2.clone();
    wait_for_default(|| list_size(&w1) >= 1);
    wait_for_default(|| list_size(&w2) >= 1);

    check_eq!(list_size(&evts1), 1usize);
    check_eq!(list_size(&evts2), 1usize);
    let s1 = list_snapshot(&evts1);
    let s2 = list_snapshot(&evts2);
    if !s1.is_empty() {
        check_eq!(s1[0], 99);
    }
    if !s2.is_empty() {
        check_eq!(s2[0], 99);
    }

    lib.off_prim_scalar_event(h1);
    lib.off_prim_scalar_event(h2);
    lib.shutdown();
}

#[allow(dead_code)]
fn test_remove_one_listener_keeps_other() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let evts1: SafeList<i32> = list_new();
    let evts2: SafeList<i32> = list_new();

    let c1 = evts1.clone();
    let h1 = lib.on_prim_scalar_event(move |_f, i: i32, _b, _c| list_push(&c1, i));
    let c2 = evts2.clone();
    let h2 = lib.on_prim_scalar_event(move |_f, i: i32, _b, _c| list_push(&c2, i));

    let _ = lib.prim_scalar_request(false, 1, 0, 0.0);
    let w1 = evts1.clone();
    let w2 = evts2.clone();
    wait_for_default(|| list_size(&w1) >= 1);
    wait_for_default(|| list_size(&w2) >= 1);
    check_eq!(list_size(&evts1), 1usize);
    check_eq!(list_size(&evts2), 1usize);

    lib.off_prim_scalar_event(h1);

    let _ = lib.prim_scalar_request(false, 2, 0, 0.0);
    let w2b = evts2.clone();
    wait_for_default(|| list_size(&w2b) >= 2);
    sleep_ms(100);

    check_eq!(list_size(&evts1), 1usize);
    check_eq!(list_size(&evts2), 2usize);
    let s2 = list_snapshot(&evts2);
    if s2.len() >= 2 {
        check_eq!(s2[1], 2);
    }

    lib.off_prim_scalar_event(h2);
    lib.shutdown();
}

fn test_concurrent_event_types() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let scalar_evts: SafeList<i32> = list_new();
    let array_evts: SafeList<Vec<i32>> = list_new();
    let string_evts: SafeList<Vec<String>> = list_new();

    let cs = scalar_evts.clone();
    let hs = lib.on_prim_scalar_event(move |_f, i: i32, _b, _c| list_push(&cs, i));
    let ca = array_evts.clone();
    let ha = lib.on_fixed_array_event(move |values: Vec<i32>| list_push(&ca, values));
    let cst = string_evts.clone();
    let hst = lib.on_string_seq_event(move |items: Vec<String>| list_push(&cst, items));

    let _ = lib.prim_scalar_request(false, 55, 0, 0.0);
    let _ = lib.fixed_array_request(4);
    let _ = lib.string_seq_request("z".to_string(), 2);

    let ws = scalar_evts.clone();
    let wa = array_evts.clone();
    let wst = string_evts.clone();
    wait_for_default(|| list_size(&ws) >= 1);
    wait_for_default(|| list_size(&wa) >= 1);
    wait_for_default(|| list_size(&wst) >= 1);

    check_eq!(list_size(&scalar_evts), 1usize);
    let ss = list_snapshot(&scalar_evts);
    if !ss.is_empty() {
        check_eq!(ss[0], 55);
    }

    check_eq!(list_size(&array_evts), 1usize);
    let sa = list_snapshot(&array_evts);
    if !sa.is_empty() {
        let arr = &sa[0];
        check_eq!(arr.len(), 4usize);
        check_eq!(arr[0], 4);
        check_eq!(arr[1], 8);
        check_eq!(arr[2], 12);
        check_eq!(arr[3], 16);
    }

    check_eq!(list_size(&string_evts), 1usize);
    let sst = list_snapshot(&string_evts);
    if !sst.is_empty() {
        let strs = &sst[0];
        check_eq!(strs.len(), 2usize);
        check_eq!(&strs[0], &"z-0".to_string());
        check_eq!(&strs[1], &"z-1".to_string());
    }

    lib.off_prim_scalar_event(hs);
    lib.off_fixed_array_event(ha);
    lib.off_string_seq_event(hst);
    lib.shutdown();
}

// ===========================================================================
// TestForeignThreadGcSafety
// ===========================================================================

fn test_foreign_thread_concurrent_requests() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let _ = lib.initialize_request("gc-test".to_string());

    const K_THREADS: usize = 8;
    const K_ITERS: usize = 20;

    let lib = Arc::new(lib);
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let lib_c = lib.clone();
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            for i in 0..K_ITERS {
                let msg = format!("thread-{}-msg-{}", t, i);
                let r = lib_c.echo_request(msg);
                if !r.is_ok() {
                    failures_c.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                if let Some(v) = r.value() {
                    if !v.reply.starts_with("gc-test:") {
                        failures_c.fetch_add(1, Ordering::Relaxed);
                        return;
                    }
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.shutdown();
}

fn test_foreign_thread_concurrent_seq_string_requests() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let _ = lib.initialize_request("seq-str".to_string());

    const K_THREADS: usize = 6;
    const K_ITERS: usize = 10;

    let lib = Arc::new(lib);
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let lib_c = lib.clone();
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            for i in 0..K_ITERS {
                let prefix = format!("t{}i{}", t, i);
                let n = 5 + (t % 3) as i32;
                let r = lib_c.string_seq_request(prefix.clone(), n);
                if !r.is_ok() {
                    failures_c.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                if let Some(v) = r.value() {
                    if v.items.len() != n as usize {
                        failures_c.fetch_add(1, Ordering::Relaxed);
                        return;
                    }
                    for j in 0..n {
                        let expected = format!("{}-{}", prefix, j);
                        if v.items[j as usize] != expected {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    }
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.shutdown();
}

fn test_foreign_thread_concurrent_seq_prim_requests() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    const K_THREADS: usize = 6;
    const K_ITERS: usize = 15;

    let lib = Arc::new(lib);
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let lib_c = lib.clone();
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            for _i in 0..K_ITERS {
                let n = 3 + (t % 4) as i32;
                let r = lib_c.prim_seq_request(n);
                if !r.is_ok() {
                    failures_c.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                if let Some(v) = r.value() {
                    if v.values.len() != n as usize {
                        failures_c.fetch_add(1, Ordering::Relaxed);
                        return;
                    }
                    for j in 0..v.values.len() {
                        if v.values[j] != (j as i64) * 10 {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    }
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.shutdown();
}

fn test_foreign_thread_concurrent_seq_object_requests() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    const K_THREADS: usize = 4;
    const K_ITERS: usize = 10;

    let lib = Arc::new(lib);
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let lib_c = lib.clone();
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            for _i in 0..K_ITERS {
                let n = 3 + (t % 5) as i32;
                let r = lib_c.obj_seq_result_request(n);
                if !r.is_ok() {
                    failures_c.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                if let Some(v) = r.value() {
                    if v.tags.len() != n as usize {
                        failures_c.fetch_add(1, Ordering::Relaxed);
                        return;
                    }
                    for j in 0..n as usize {
                        let ek = format!("key-{}", j);
                        let ev = format!("val-{}", j);
                        if v.tags[j].key != ek || v.tags[j].value != ev {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    }
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.shutdown();
}

fn test_foreign_thread_concurrent_seq_object_param_requests() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    const K_THREADS: usize = 4;
    const K_ITERS: usize = 8;

    let lib = Arc::new(lib);
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let lib_c = lib.clone();
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            for _i in 0..K_ITERS {
                let n = 2 + (t % 3) as i32;
                let mut tags: Vec<Tag> = Vec::new();
                for j in 0..n {
                    tags.push(Tag {
                        key: format!("thread{}-key{}", t, j),
                        value: format!("thread{}-val{}", t, j),
                    });
                }
                let r = lib_c.obj_seq_param_request(tags);
                if !r.is_ok() {
                    failures_c.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                if let Some(v) = r.value() {
                    if v.count != n {
                        failures_c.fetch_add(1, Ordering::Relaxed);
                        return;
                    }
                    let expected = format!("thread{}-key0", t);
                    if v.first != expected {
                        failures_c.fetch_add(1, Ordering::Relaxed);
                        return;
                    }
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.shutdown();
}

fn test_foreign_thread_concurrent_lifecycle() {
    const K_THREADS: usize = 4;
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            let mut lib = Typemappingtestlib::new();
            let cr = lib.create_context();
            if !cr.is_ok() {
                failures_c.fetch_add(1, Ordering::Relaxed);
                return;
            }
            let ir = lib.initialize_request(format!("lifecycle-t{}", t));
            if !ir.is_ok() {
                failures_c.fetch_add(1, Ordering::Relaxed);
                return;
            }
            let r = lib.echo_request("test".to_string());
            if !r.is_ok() {
                failures_c.fetch_add(1, Ordering::Relaxed);
                return;
            }
            let expected = format!("lifecycle-t{}:test", t);
            if let Some(v) = r.value() {
                if v.reply != expected {
                    failures_c.fetch_add(1, Ordering::Relaxed);
                    return;
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
}

fn test_foreign_thread_mixed_request_types() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let _ = lib.initialize_request("mixed".to_string());

    const K_THREADS: usize = 6;
    const K_ITERS: usize = 10;

    let lib = Arc::new(lib);
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let lib_c = lib.clone();
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            for i in 0..K_ITERS {
                match i % 5 {
                    0 => {
                        let r = lib_c.echo_request(format!("t{}", t));
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    }
                    1 => {
                        let r = lib_c.counter_request();
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.value <= 0 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    2 => {
                        let r = lib_c.prim_scalar_request(true, 42, 1000, 3.14);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.flag != true || v.i32 != 42 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    3 => {
                        let r = lib_c.string_seq_request("x".to_string(), 3);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.items.len() != 3 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    4 => {
                        let r = lib_c.fixed_array_request(7);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.values[0] != 7 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.shutdown();
}

fn test_foreign_thread_stress_all_types() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let _ = lib.initialize_request("stress".to_string());

    const K_THREADS: usize = 8;
    const K_ITERS: usize = 30;

    let lib = Arc::new(lib);
    let failures = Arc::new(AtomicI32::new(0));
    let mut threads = Vec::new();

    for t in 0..K_THREADS {
        let lib_c = lib.clone();
        let failures_c = failures.clone();
        threads.push(std::thread::spawn(move || {
            for i in 0..K_ITERS {
                match i % 8 {
                    0 => {
                        let r = lib_c.echo_request(format!("stress-{}", t));
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    }
                    1 => {
                        let r = lib_c.counter_request();
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    }
                    2 => {
                        let r = lib_c.prim_scalar_request(false, -100, -999_999, -1.5);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    }
                    3 => {
                        let r = lib_c.string_seq_request("s".to_string(), 10);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.items.len() != 10 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    4 => {
                        let r = lib_c.prim_seq_request(20);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.values.len() != 20 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    5 => {
                        let r = lib_c.obj_seq_result_request(5);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.tags.len() != 5 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    6 => {
                        let mut tags: Vec<Tag> = Vec::new();
                        for j in 0..3 {
                            tags.push(Tag {
                                key: format!("k{}", j),
                                value: format!("v{}", j),
                            });
                        }
                        let r = lib_c.obj_seq_param_request(tags);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.count != 3 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    7 => {
                        let r = lib_c.seq_string_param_request(vec![
                            "a".to_string(),
                            "b".to_string(),
                            "c".to_string(),
                        ]);
                        if !r.is_ok() {
                            failures_c.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                        if let Some(v) = r.value() {
                            if v.count != 3 {
                                failures_c.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    check_eq!(failures.load(Ordering::Relaxed), 0);
    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.shutdown();
}

// ===========================================================================
// TestSeqObjectEventMemorySafety
// ===========================================================================

#[derive(Clone)]
struct TagData {
    key: String,
    value: String,
}

fn test_seq_object_event_callback_data_correctness() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let received: SafeList<Vec<TagData>> = list_new();
    let cb = received.clone();
    let h = lib.on_tag_seq_event(move |tags: Vec<Tag>| {
        let snapshot: Vec<TagData> = tags
            .iter()
            .map(|t| TagData {
                key: t.key.clone(),
                value: t.value.clone(),
            })
            .collect();
        list_push(&cb, snapshot);
    });
    check_ne!(h, 0u64);

    let _ = lib.obj_seq_result_request(3);
    let _ = lib.obj_seq_result_request(5);
    let _ = lib.obj_seq_result_request(0);

    let w = received.clone();
    wait_for_default(|| list_size(&w) >= 3);

    check_eq!(list_size(&received), 3usize);
    let snap = list_snapshot(&received);

    if snap.len() >= 3 {
        let s0 = &snap[0];
        check_eq!(s0.len(), 3usize);
        if s0.len() >= 3 {
            check_eq!(&s0[0].key, &"key-0".to_string());
            check_eq!(&s0[0].value, &"val-0".to_string());
            check_eq!(&s0[2].key, &"key-2".to_string());
            check_eq!(&s0[2].value, &"val-2".to_string());
        }
        let s1 = &snap[1];
        check_eq!(s1.len(), 5usize);
        if s1.len() >= 5 {
            check_eq!(&s1[0].key, &"key-0".to_string());
            check_eq!(&s1[4].value, &"val-4".to_string());
        }
        let s2 = &snap[2];
        check!(s2.is_empty());
    }

    lib.off_tag_seq_event(h);
    lib.shutdown();
}

fn test_seq_object_event_rapid_fire_no_leak() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let event_count = Arc::new(AtomicI32::new(0));
    let ec = event_count.clone();
    let h = lib.on_tag_seq_event(move |_tags: Vec<Tag>| {
        ec.fetch_add(1, Ordering::Relaxed);
    });

    const K_ITER: i32 = 100;
    for _ in 0..K_ITER {
        let _ = lib.obj_seq_result_request(10);
    }

    let ecw = event_count.clone();
    wait_for(|| ecw.load(Ordering::Relaxed) >= K_ITER, 10.0);
    check_eq!(event_count.load(Ordering::Relaxed), K_ITER);

    lib.off_tag_seq_event(h);
    lib.shutdown();
}

fn test_seq_object_event_concurrent_listeners_and_requesters() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();

    let event_count = Arc::new(AtomicI32::new(0));
    let ec = event_count.clone();
    let h = lib.on_tag_seq_event(move |tags: Vec<Tag>| {
        for t in &tags {
            let _kl = t.key.len();
            let _vl = t.value.len();
        }
        ec.fetch_add(1, Ordering::Relaxed);
    });

    const K_REQUESTERS: usize = 4;
    const K_ITERS: usize = 20;
    let request_failures = Arc::new(AtomicI32::new(0));

    let lib = Arc::new(lib);
    let mut threads = Vec::new();

    for t in 0..K_REQUESTERS {
        let lib_c = lib.clone();
        let rf = request_failures.clone();
        threads.push(std::thread::spawn(move || {
            for _i in 0..K_ITERS {
                let r = lib_c.obj_seq_result_request(5 + (t % 3) as i32);
                if !r.is_ok() {
                    rf.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                if let Some(v) = r.value() {
                    if v.tags.len() < 5 {
                        rf.fetch_add(1, Ordering::Relaxed);
                        return;
                    }
                }
            }
        }));
    }

    for th in threads {
        let _ = th.join();
    }

    let expected_events = (K_REQUESTERS * K_ITERS) as i32;
    check_eq!(request_failures.load(Ordering::Relaxed), 0);
    let ecw = event_count.clone();
    wait_for_default(|| ecw.load(Ordering::Relaxed) >= expected_events);
    check_eq!(event_count.load(Ordering::Relaxed), expected_events);

    let mut lib = Arc::try_unwrap(lib).unwrap_or_else(|_| panic!("Arc still shared"));
    lib.off_tag_seq_event(h);
    lib.shutdown();
}

// ===========================================================================
// TestPreviouslyRestrictedShapes — formerly ❌ in TYPESUPPORT.md.
// ===========================================================================

fn test_list_inners_result_empty() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.list_inners_request(0);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check!(v.items.is_empty());
    }
    lib.shutdown();
}

fn test_list_inners_result_count_and_fields() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.list_inners_request(3);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.items.len(), 3usize);
        check_eq!(v.items[0].id, 0);
        check_eq!(&v.items[0].tag, &"inner-0".to_string());
        check_eq!(&v.items[0].bytes, &vec![0u8]);
        check_eq!(v.items[2].id, 2);
        check_eq!(&v.items[2].tag, &"inner-2".to_string());
        check_eq!(&v.items[2].bytes, &vec![2u8, 3, 4]);
    }
    lib.shutdown();
}

fn test_bulk_inners_param_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let gen = lib.list_inners_request(5);
    check!(gen.is_ok());
    let items: Vec<Inner> = gen.value().map(|v| v.items.clone()).unwrap_or_default();
    let r = lib.bulk_inners_request(items);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.idSum, 10i64);
        check_eq!(v.byteCount, 15i64);
    }
    lib.shutdown();
}

fn test_inners_updated_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let evts: SafeList<Vec<Inner>> = list_new();
    let cb = evts.clone();
    let h = lib.on_inners_updated_event(move |items: Vec<Inner>| list_push(&cb, items));
    let _ = lib.trigger_inners_updated_request(4);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);
    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let items = &snap[0];
        check_eq!(items.len(), 4usize);
        check_eq!(items[0].id, 0);
        check_eq!(&items[0].tag, &"evt-0".to_string());
        check_eq!(&items[0].bytes, &vec![0u8]);
        check_eq!(items[3].id, 3);
        check_eq!(&items[3].bytes, &vec![3u8, 4, 5, 6]);
    }
    lib.off_inners_updated_event(h);
    lib.shutdown();
}

fn test_fixed_str_array_result() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.fixed_str_array_request("tag".to_string());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.tags.len(), 4usize);
        check_eq!(&v.tags[0], &"tag-0".to_string());
        check_eq!(&v.tags[1], &"tag-1".to_string());
        check_eq!(&v.tags[2], &"tag-2".to_string());
        check_eq!(&v.tags[3], &"tag-3".to_string());
    }
    lib.shutdown();
}

fn test_set_tags_array_param() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.set_tags_request(vec![
        "alpha".to_string(),
        "beta".to_string(),
        "".to_string(),
        "delta".to_string(),
    ]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.joined, &"alpha|beta||delta".to_string());
    }
    lib.shutdown();
}

fn test_sum_prim_array_param() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.sum_prim_array_request(vec![10i32, 20, 30, 40]);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.total, 100i64);
    }
    lib.shutdown();
}

fn test_fixed_obj_array_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let evts: SafeList<Vec<Slot>> = list_new();
    let cb = evts.clone();
    let h = lib.on_fixed_obj_array_event(move |slots: Vec<Slot>| list_push(&cb, slots));
    let _ = lib.trigger_fixed_obj_array_request(100);
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);
    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let slots = &snap[0];
        check_eq!(slots.len(), 4usize);
        check_eq!(slots[0].idx, 100);
        check_eq!(&slots[0].name, &"alpha".to_string());
        check_eq!(&slots[2].name, &"".to_string());
        check_eq!(slots[3].idx, 103);
        check_eq!(&slots[3].name, &"delta with spaces".to_string());
    }
    lib.off_fixed_obj_array_event(h);
    lib.shutdown();
}

// --- Last-three-❓ probes -------------------------------------------------

fn test_nested_obj_inline_field() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let r = lib.nested_obj_request("k".to_string(), "v".to_string());
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.label, &"k=v".to_string());
        check_eq!(&v.nested.key, &"k".to_string());
        check_eq!(&v.nested.value, &"v".to_string());
    }
    lib.shutdown();
}

fn test_set_slots_obj_array_param() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let slots = vec![
        Slot { idx: 1, name: "alpha".to_string() },
        Slot { idx: 2, name: "beta".to_string() },
        Slot { idx: 3, name: "".to_string() },
        Slot { idx: 4, name: "delta".to_string() },
    ];
    let r = lib.set_slots_request(slots);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(&v.summary, &"alpha|beta||delta".to_string());
    }
    lib.shutdown();
}

fn test_str_array_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let evts: SafeList<Vec<String>> = list_new();
    let cb = evts.clone();
    let h = lib.on_str_array_event(move |words: Vec<String>| list_push(&cb, words));
    let _ = lib.trigger_str_array_request("word".to_string());
    let w = evts.clone();
    wait_for_default(|| list_size(&w) >= 1);
    check_eq!(list_size(&evts), 1usize);
    let snap = list_snapshot(&evts);
    if !snap.is_empty() {
        let words = &snap[0];
        check_eq!(words.len(), 4usize);
        check_eq!(&words[0], &"word-0".to_string());
        check_eq!(&words[1], &"word-1".to_string());
        check_eq!(&words[2], &"word-2".to_string());
        check_eq!(&words[3], &"word-3".to_string());
    }
    lib.off_str_array_event(h);
    lib.shutdown();
}

// ===========================================================================
// main
// ===========================================================================

// Associative containers — Table[K, V]. Rust currently supports string-keyed
// tables (ciborium/serde decode them natively); non-string keys are exercised
// by the Python parity test (see doc/ASSOC_CONTAINERS_IMPL_PLAN.md §9b).

fn test_map_param_roundtrip() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let mut scores: HashMap<String, i32> = HashMap::new();
    scores.insert("x".to_string(), 10);
    scores.insert("y".to_string(), 20);
    scores.insert("z".to_string(), 30);
    let r = lib.map_param_request(scores);
    check!(r.is_ok());
    if let Some(v) = r.value() {
        check_eq!(v.total, 60i64);
        check_eq!(&v.joined, &"x|y|z".to_string());
    }
    lib.shutdown();
}

fn test_map_event() {
    let mut lib = Typemappingtestlib::new();
    let _ = lib.create_context();
    let received: SafeList<HashMap<String, i32>> = list_new();
    let received_cb = received.clone();
    let h = lib.on_map_event(move |counts: HashMap<String, i32>| {
        list_push(&received_cb, counts);
    });
    check_ne!(h, 0u64);
    let mut scores: HashMap<String, i32> = HashMap::new();
    scores.insert("a".to_string(), 1);
    scores.insert("b".to_string(), 2);
    let _ = lib.map_param_request(scores);
    let received_w = received.clone();
    wait_for_default(|| list_size(&received_w) >= 1);
    check_eq!(list_size(&received), 1usize);
    let snap = list_snapshot(&received);
    check_eq!(*snap[0].get("a").unwrap(), 1i32);
    check_eq!(*snap[0].get("b").unwrap(), 2i32);
    lib.off_map_event(h);
    lib.shutdown();
}

fn main() {
    println!("test_typemappingtestlib — Rust type mapping coverage\n");
    println!("library version: {}", Typemappingtestlib::version());

    println!("--- TestLifecycle ---");
    run_test("test_lifecycle_create_and_shutdown", test_lifecycle_create_and_shutdown);
    run_test("test_lifecycle_raii_shutdown", test_lifecycle_raii_shutdown);
    run_test("test_lifecycle_double_shutdown_is_safe", test_lifecycle_double_shutdown_is_safe);
    run_test("test_lifecycle_double_create_returns_error", test_lifecycle_double_create_returns_error);
    run_test("test_lifecycle_request_without_context_fails", test_lifecycle_request_without_context_fails);

    println!("\n--- TestRequests ---");
    run_test("test_requests_initialize", test_requests_initialize);
    run_test("test_requests_echo", test_requests_echo);
    run_test("test_requests_counter_increments", test_requests_counter_increments);
    run_test("test_requests_multiple_echo", test_requests_multiple_echo);
    run_test("test_dual_sig_zero", test_dual_sig_zero);
    run_test("test_dual_sig_with_label", test_dual_sig_with_label);

    println!("\n--- TestEvents ---");
    run_test("test_events_counter_changed", test_events_counter_changed);
    run_test("test_events_off_stops_delivery", test_events_off_stops_delivery);

    run_test("test_primitive_int_result_request", test_primitive_int_result_request);
    run_test("test_primitive_simple_int_event", test_primitive_simple_int_event);
    run_test("test_void_action_request", test_void_action_request);
    run_test("test_void_ping_event", test_void_ping_event);

    println!("\n--- TestContextSeparation ---");
    run_test("test_context_independent_counters", test_context_independent_counters);
    run_test("test_context_independent_echo", test_context_independent_echo);
    run_test("test_context_independent_events", test_context_independent_events);
    run_test("test_context_shutdown_one_does_not_affect_other", test_context_shutdown_one_does_not_affect_other);

    println!("\n--- TestScalarTypes ---");
    run_test("test_scalar_bool_true", test_scalar_bool_true);
    run_test("test_scalar_bool_false", test_scalar_bool_false);
    run_test("test_scalar_int32_roundtrip", test_scalar_int32_roundtrip);
    run_test("test_scalar_int64_roundtrip", test_scalar_int64_roundtrip);
    run_test("test_scalar_float64_roundtrip", test_scalar_float64_roundtrip);
    run_test("test_scalar_all_fields_roundtrip", test_scalar_all_fields_roundtrip);
    run_test("test_scalar_prim_scalar_event", test_scalar_prim_scalar_event);
    run_test("test_scalar_prim_scalar_event_false_flag", test_scalar_prim_scalar_event_false_flag);

    println!("\n--- TestEnumDistinctTypes ---");
    run_test("test_enum_roundtrip_low", test_enum_roundtrip_low);
    run_test("test_enum_roundtrip_high", test_enum_roundtrip_high);
    run_test("test_enum_roundtrip_critical", test_enum_roundtrip_critical);
    run_test("test_distinct_jobid_echoed", test_distinct_jobid_echoed);
    run_test("test_distinct_jobid_next", test_distinct_jobid_next);
    run_test("test_distinct_jobid_zero", test_distinct_jobid_zero);
    run_test("test_distinct_jobid_max_minus_one", test_distinct_jobid_max_minus_one);
    run_test("test_all_priority_values", test_all_priority_values);
    run_test("test_typed_scalar_event_enum", test_typed_scalar_event_enum);
    run_test("test_typed_scalar_event_distinct_timestamp", test_typed_scalar_event_distinct_timestamp);
    run_test("test_fixedarray_result_contains_timestamp", test_fixedarray_result_contains_timestamp);

    println!("\n--- TestSeqByteResult ---");
    run_test("test_seq_byte_empty", test_seq_byte_empty);
    run_test("test_seq_byte_length", test_seq_byte_length);
    run_test("test_seq_byte_values", test_seq_byte_values);
    run_test("test_seq_byte_wrap_around", test_seq_byte_wrap_around);
    run_test("test_seq_byte_single_element", test_seq_byte_single_element);
    run_test("test_seq_byte_large", test_seq_byte_large);

    println!("\n--- TestSeqStringTypes ---");
    run_test("test_seq_string_result_empty", test_seq_string_result_empty);
    run_test("test_seq_string_result_count", test_seq_string_result_count);
    run_test("test_seq_string_result_values", test_seq_string_result_values);
    run_test("test_seq_string_result_special_chars", test_seq_string_result_special_chars);
    run_test("test_seq_string_param_empty", test_seq_string_param_empty);
    run_test("test_seq_string_param_single", test_seq_string_param_single);
    run_test("test_seq_string_param_multiple", test_seq_string_param_multiple);
    run_test("test_seq_string_param_unicode", test_seq_string_param_unicode);
    run_test("test_string_seq_event", test_string_seq_event);
    run_test("test_string_seq_event_empty", test_string_seq_event_empty);

    println!("\n--- TestSeqPrimTypes ---");
    run_test("test_prim_seq_result_empty", test_prim_seq_result_empty);
    run_test("test_prim_seq_result_length", test_prim_seq_result_length);
    run_test("test_prim_seq_result_values", test_prim_seq_result_values);
    run_test("test_prim_seq_result_large_int64", test_prim_seq_result_large_int64);
    run_test("test_prim_seq_param_empty", test_prim_seq_param_empty);
    run_test("test_prim_seq_param_single", test_prim_seq_param_single);
    run_test("test_prim_seq_param_sum", test_prim_seq_param_sum);
    run_test("test_prim_seq_param_large_values", test_prim_seq_param_large_values);
    run_test("test_prim_seq_event", test_prim_seq_event);
    run_test("test_prim_seq_event_empty", test_prim_seq_event_empty);

    println!("\n--- TestFixedArrayTypes ---");
    run_test("test_array_result_values", test_array_result_values);
    run_test("test_array_result_length", test_array_result_length);
    run_test("test_array_result_seed_zero", test_array_result_seed_zero);
    run_test("test_array_result_negative_seed", test_array_result_negative_seed);
    run_test("test_array_result_timestamp", test_array_result_timestamp);
    run_test("test_fixed_array_event", test_fixed_array_event);
    run_test("test_fixed_array_event_zero_seed", test_fixed_array_event_zero_seed);
    run_test("test_fixed_array_multiple_requests", test_fixed_array_multiple_requests);

    println!("\n--- TestConstArraySize ---");
    run_test("test_const_array_result_length", test_const_array_result_length);
    run_test("test_const_array_result_values", test_const_array_result_values);
    run_test("test_const_array_result_zero_seed", test_const_array_result_zero_seed);
    run_test("test_const_array_result_negative_seed", test_const_array_result_negative_seed);
    run_test("test_const_array_event_values", test_const_array_event_values);
    run_test("test_const_array_event_length", test_const_array_event_length);
    run_test("test_const_array_event_zero_seed", test_const_array_event_zero_seed);
    run_test("test_const_array_event_neg_seed", test_const_array_event_neg_seed);

    println!("\n--- TestSeqObjectTypes ---");
    run_test("test_obj_seq_param_empty", test_obj_seq_param_empty);
    run_test("test_obj_seq_param_single", test_obj_seq_param_single);
    run_test("test_obj_seq_param_multiple", test_obj_seq_param_multiple);
    run_test("test_obj_seq_param_string_encoding", test_obj_seq_param_string_encoding);
    run_test("test_opt_scalar_present", test_opt_scalar_present);
    run_test("test_opt_scalar_absent", test_opt_scalar_absent);
    run_test("test_opt_string_present", test_opt_string_present);
    run_test("test_opt_string_absent", test_opt_string_absent);
    run_test("test_opt_seq_present", test_opt_seq_present);
    run_test("test_opt_seq_absent", test_opt_seq_absent);
    run_test("test_opt_obj_present", test_opt_obj_present);
    run_test("test_opt_obj_absent", test_opt_obj_absent);
    {
        run_test("test_obj_as_param", test_obj_as_param);
        run_test("test_bytes_echo_request_roundtrip", test_bytes_echo_request_roundtrip);
        run_test("test_bytes_echo_request_empty", test_bytes_echo_request_empty);
        run_test("test_scan_request_forward", test_scan_request_forward);
        run_test("test_scan_request_reverse", test_scan_request_reverse);
    }
    run_test("test_obj_seq_result_empty", test_obj_seq_result_empty);
    run_test("test_obj_seq_result_length", test_obj_seq_result_length);
    run_test("test_obj_seq_result_keys", test_obj_seq_result_keys);
    run_test("test_obj_seq_result_values", test_obj_seq_result_values);
    run_test("test_obj_seq_result_tag_fields", test_obj_seq_result_tag_fields);
    run_test("test_obj_seq_roundtrip", test_obj_seq_roundtrip);

    println!("\n--- TestMultipleEventListeners ---");
    run_test("test_two_scalar_event_listeners", test_two_scalar_event_listeners);
    run_test("test_remove_one_listener_keeps_other", test_remove_one_listener_keeps_other);
    run_test("test_concurrent_event_types", test_concurrent_event_types);

    println!("\n--- TestForeignThreadGcSafety ---");
    run_test("test_foreign_thread_concurrent_requests", test_foreign_thread_concurrent_requests);
    run_test("test_foreign_thread_concurrent_seq_string_requests", test_foreign_thread_concurrent_seq_string_requests);
    run_test("test_foreign_thread_concurrent_seq_prim_requests", test_foreign_thread_concurrent_seq_prim_requests);
    run_test("test_foreign_thread_concurrent_seq_object_requests", test_foreign_thread_concurrent_seq_object_requests);
    run_test("test_foreign_thread_concurrent_seq_object_param_requests", test_foreign_thread_concurrent_seq_object_param_requests);
    run_test("test_foreign_thread_concurrent_lifecycle", test_foreign_thread_concurrent_lifecycle);
    run_test("test_foreign_thread_mixed_request_types", test_foreign_thread_mixed_request_types);
    run_test("test_foreign_thread_stress_all_types", test_foreign_thread_stress_all_types);

    println!("\n--- TestSeqObjectEventMemorySafety ---");
    run_test("test_seq_object_event_callback_data_correctness", test_seq_object_event_callback_data_correctness);
    run_test("test_seq_object_event_rapid_fire_no_leak", test_seq_object_event_rapid_fire_no_leak);
    run_test("test_seq_object_event_concurrent_listeners_and_requesters", test_seq_object_event_concurrent_listeners_and_requesters);

    println!("\n--- TestPreviouslyRestrictedShapes ---");
    run_test("test_list_inners_result_empty", test_list_inners_result_empty);
    run_test("test_list_inners_result_count_and_fields", test_list_inners_result_count_and_fields);
    run_test("test_bulk_inners_param_roundtrip", test_bulk_inners_param_roundtrip);
    run_test("test_inners_updated_event", test_inners_updated_event);
    run_test("test_fixed_str_array_result", test_fixed_str_array_result);
    run_test("test_set_tags_array_param", test_set_tags_array_param);
    run_test("test_sum_prim_array_param", test_sum_prim_array_param);
    run_test("test_fixed_obj_array_event", test_fixed_obj_array_event);
    run_test("test_nested_obj_inline_field", test_nested_obj_inline_field);
    run_test("test_set_slots_obj_array_param", test_set_slots_obj_array_param);
    run_test("test_str_array_event", test_str_array_event);

    println!("\n--- TestTableTypes ---");
    run_test("test_map_param_roundtrip", test_map_param_roundtrip);
    run_test("test_map_event", test_map_event);

    let total = G_TOTAL.load(Ordering::SeqCst);
    let failed = G_FAILED.load(Ordering::SeqCst);
    println!("\n----------------------------------------------------------------------");
    println!("Ran {} tests: {} ok, {} failed", total, total - failed, failed);

    if failed != 0 {
        std::process::exit(1);
    }
}
