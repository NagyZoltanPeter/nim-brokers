// Rust parity matrix for typemappingtestlib.
//
// Mirrors the spirit of test_typemappingtestlib.{cpp,py}: walks the type
// surface the Rust codegen claims to support and asserts the wrapper
// returns the values the Nim providers compute. The same matrix runs in
// both build modes — the codegen now covers seq[primitive], seq[string],
// seq[Object], array[N, primitive], enums, and distinct/alias on the
// native side, so the assertion list is shared.
//
//     cargo run                 # native FFI build  (build/)
//     cargo run --features cbor # CBOR FFI build    (build_cbor/)

#[cfg(not(feature = "cbor"))]
#[path = "../../build/typemappingtestlib_rs/src/lib.rs"]
mod lib;

#[cfg(feature = "cbor")]
#[path = "../../build_cbor/typemappingtestlib_rs/src/lib.rs"]
mod lib;

use lib::Typemappingtestlib;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

static FAILURES: AtomicUsize = AtomicUsize::new(0);

macro_rules! check {
    ($cond:expr, $msg:expr) => {
        if !$cond {
            eprintln!("FAIL: {}", $msg);
            FAILURES.fetch_add(1, Ordering::SeqCst);
        } else {
            println!("ok: {}", $msg);
        }
    };
}

fn main() {
    println!("=== typemappingtestlib Rust parity matrix ===");
    println!("library version: {}", Typemappingtestlib::version());

    let mut t = Typemappingtestlib::new();
    let r = t.create_context();
    if !r.is_ok() {
        eprintln!("create_context failed: {}", r.error().unwrap_or("?"));
        std::process::exit(1);
    }

    matrix(&t);

    t.shutdown();

    let n = FAILURES.load(Ordering::SeqCst);
    if n > 0 {
        eprintln!("=== {} failure(s) ===", n);
        std::process::exit(1);
    }
    println!("=== all checks passed ===");
}

fn matrix(t: &Typemappingtestlib) {
    let init = t.initialize_request("hello".to_string());
    check!(init.is_ok(), "InitializeRequest is_ok");
    if init.is_ok() {
        check!(
            init.value().unwrap().label == "hello",
            "InitializeRequest.label == \"hello\""
        );
    }

    let echo = t.echo_request("ping".to_string());
    check!(echo.is_ok(), "EchoRequest is_ok");

    let prim = t.prim_scalar_request(true, 42, 9_000_000_000, 3.14);
    check!(prim.is_ok(), "PrimScalarRequest is_ok");
    if prim.is_ok() {
        let v = prim.value().unwrap();
        check!(v.flag, "PrimScalarRequest.flag == true");
        check!(v.i32 == 42, "PrimScalarRequest.i32 == 42");
    }

    // Enum + distinct.
    let typed = t.typed_scalar_request(lib::Priority::pHigh, 41 as lib::JobId);
    check!(typed.is_ok(), "TypedScalarRequest is_ok");
    if typed.is_ok() {
        let v = typed.value().unwrap();
        check!(
            v.priority == lib::Priority::pHigh,
            "TypedScalarRequest.priority == pHigh"
        );
        check!(
            v.nextId == 42 as lib::JobId,
            "TypedScalarRequest.nextId == 42"
        );
    }

    let bs = t.byte_seq_request(5);
    check!(bs.is_ok(), "ByteSeqRequest is_ok");
    if bs.is_ok() {
        let v = bs.value().unwrap();
        check!(
            v.data == vec![0u8, 1, 2, 3, 4],
            "ByteSeqRequest.data == [0..5)"
        );
    }

    let ss = t.string_seq_request("p".to_string(), 3);
    check!(ss.is_ok(), "StringSeqRequest is_ok");
    if ss.is_ok() {
        let v = ss.value().unwrap();
        check!(v.items.len() == 3, "StringSeqRequest.items.len == 3");
        check!(v.items[0] == "p-0", "StringSeqRequest.items[0] == p-0");
    }

    let ps = t.prim_seq_request(4);
    check!(ps.is_ok(), "PrimSeqRequest is_ok");
    if ps.is_ok() {
        let v = ps.value().unwrap();
        check!(v.values == vec![0i64, 10, 20, 30], "PrimSeqRequest.values");
    }

    let fa = t.fixed_array_request(2);
    check!(fa.is_ok(), "FixedArrayRequest is_ok");
    if fa.is_ok() {
        let v = fa.value().unwrap();
        check!(
            v.values == vec![2i32, 4, 6, 8],
            "FixedArrayRequest.values == [2,4,6,8]"
        );
        check!(v.ts == 2 as lib::Timestamp, "FixedArrayRequest.ts == 2");
    }

    let osr = t.obj_seq_result_request(2);
    check!(osr.is_ok(), "ObjSeqResultRequest is_ok");
    if osr.is_ok() {
        let v = osr.value().unwrap();
        check!(v.tags.len() == 2, "ObjSeqResultRequest.tags.len == 2");
        check!(
            v.tags[0].key == "key-0",
            "ObjSeqResultRequest.tags[0].key == key-0"
        );
    }

    let tags = vec![
        lib::Tag {
            key: "k1".to_string(),
            value: "v1".to_string(),
        },
        lib::Tag {
            key: "k2".to_string(),
            value: "v2".to_string(),
        },
    ];
    let osp = t.obj_seq_param_request(tags);
    check!(osp.is_ok(), "ObjSeqParamRequest is_ok");
    if osp.is_ok() {
        let v = osp.value().unwrap();
        check!(v.count == 2, "ObjSeqParamRequest.count == 2");
        check!(v.first == "k1", "ObjSeqParamRequest.first == k1");
    }

    let ssp = t.seq_string_param_request(vec!["a".to_string(), "b".to_string()]);
    check!(ssp.is_ok(), "SeqStringParamRequest is_ok");
    if ssp.is_ok() {
        let v = ssp.value().unwrap();
        check!(v.joined == "a,b", "SeqStringParamRequest.joined == a,b");
    }

    let psp = t.prim_seq_param_request(vec![1i64, 2, 3, 4]);
    check!(psp.is_ok(), "PrimSeqParamRequest is_ok");
    if psp.is_ok() {
        let v = psp.value().unwrap();
        check!(v.total == 10, "PrimSeqParamRequest.total == 10");
    }

    // Object as request param — exercises whole-struct pass-by-value.
    // Only registered in CBOR mode (the broker definition is gated to
    // -d:BrokerFfiApiCBOR). Native C/C++/Python/Rust all fail for this
    // pattern; see doc/TYPESUPPORT.md, Section 2.
    #[cfg(feature = "cbor")]
    {
        let op = t.obj_param_request(lib::Tag {
            key: "k".to_string(),
            value: "v".to_string(),
        });
        check!(op.is_ok(), "ObjParamRequest is_ok");
        if op.is_ok() {
            let v = op.value().unwrap();
            check!(v.summary == "k=v", "ObjParamRequest.summary == k=v");
        }
    }

    event_matrix(t);
}

fn event_matrix(t: &Typemappingtestlib) {
    // Each request below also emits an event with the same payload values.
    // Subscribe first, fire the request, briefly wait for the delivery
    // thread to dispatch, then assert the captured payload.

    // -- CounterChanged: primitive scalar event -------------------------
    let counter_seen: Arc<Mutex<Vec<i32>>> = Arc::new(Mutex::new(Vec::new()));
    {
        let cs = counter_seen.clone();
        let _h = t.on_counter_changed(move |value: i32| {
            cs.lock().unwrap().push(value);
        });
    }
    let _ = t.counter_request();
    let _ = t.counter_request();
    settle();
    {
        let v = counter_seen.lock().unwrap();
        check!(v.len() >= 2, "CounterChanged fired ≥2 times");
        check!(
            v.iter().any(|&x| x >= 1),
            "CounterChanged carried a positive value"
        );
    }

    // -- TypedScalarEvent: enum + distinct (the original v1 gap) --------
    let typed_seen: Arc<Mutex<Vec<(lib::Priority, lib::JobId, lib::Timestamp)>>> =
        Arc::new(Mutex::new(Vec::new()));
    {
        let ts = typed_seen.clone();
        let _h = t.on_typed_scalar_event(move |p, j, _ts| {
            ts.lock().unwrap().push((p, j, _ts));
        });
    }
    let _ = t.typed_scalar_request(lib::Priority::pHigh, 99 as lib::JobId);
    settle();
    {
        let v = typed_seen.lock().unwrap();
        check!(v.len() >= 1, "TypedScalarEvent fired");
        if let Some(&(p, j, _)) = v.first() {
            check!(p == lib::Priority::pHigh, "TypedScalarEvent.priority == pHigh");
            check!(j == 99 as lib::JobId, "TypedScalarEvent.jobId == 99");
        }
    }

    // -- StringSeqEvent: seq[string] -----------------------------------
    let strs_seen: Arc<Mutex<Vec<Vec<String>>>> = Arc::new(Mutex::new(Vec::new()));
    {
        let ss = strs_seen.clone();
        let _h = t.on_string_seq_event(move |items: Vec<String>| {
            ss.lock().unwrap().push(items);
        });
    }
    let _ = t.string_seq_request("evt".to_string(), 2);
    settle();
    {
        let v = strs_seen.lock().unwrap();
        check!(v.len() >= 1, "StringSeqEvent fired");
        if let Some(items) = v.first() {
            check!(items.len() == 2, "StringSeqEvent items.len == 2");
            check!(items[0] == "evt-0", "StringSeqEvent items[0] == evt-0");
        }
    }

    // -- PrimSeqEvent: seq[primitive] ----------------------------------
    let prim_seen: Arc<Mutex<Vec<Vec<i64>>>> = Arc::new(Mutex::new(Vec::new()));
    {
        let ps = prim_seen.clone();
        let _h = t.on_prim_seq_event(move |values: Vec<i64>| {
            ps.lock().unwrap().push(values);
        });
    }
    let _ = t.prim_seq_request(3);
    settle();
    {
        let v = prim_seen.lock().unwrap();
        check!(v.len() >= 1, "PrimSeqEvent fired");
        if let Some(values) = v.first() {
            check!(values == &vec![0i64, 10, 20], "PrimSeqEvent.values [0,10,20]");
        }
    }

    // -- FixedArrayEvent: array[4, int32] ------------------------------
    let arr_seen: Arc<Mutex<Vec<Vec<i32>>>> = Arc::new(Mutex::new(Vec::new()));
    {
        let a = arr_seen.clone();
        let _h = t.on_fixed_array_event(move |values: Vec<i32>| {
            a.lock().unwrap().push(values);
        });
    }
    let _ = t.fixed_array_request(3);
    settle();
    {
        let v = arr_seen.lock().unwrap();
        check!(v.len() >= 1, "FixedArrayEvent fired");
        if let Some(values) = v.first() {
            check!(
                values == &vec![3i32, 6, 9, 12],
                "FixedArrayEvent.values [3,6,9,12]"
            );
        }
    }

    // -- TagSeqEvent: seq[Object] --------------------------------------
    let tags_seen: Arc<Mutex<Vec<Vec<lib::Tag>>>> = Arc::new(Mutex::new(Vec::new()));
    {
        let ts = tags_seen.clone();
        let _h = t.on_tag_seq_event(move |tags: Vec<lib::Tag>| {
            ts.lock().unwrap().push(tags);
        });
    }
    let _ = t.tag_seq_request(2);
    settle();
    {
        let v = tags_seen.lock().unwrap();
        check!(v.len() >= 1, "TagSeqEvent fired");
        if let Some(tags) = v.first() {
            check!(tags.len() == 2, "TagSeqEvent tags.len == 2");
            check!(
                tags[0].key == "tag-key-0",
                "TagSeqEvent tags[0].key == tag-key-0"
            );
        }
    }
}

fn settle() {
    // Give the delivery thread time to dispatch fired events to listeners.
    std::thread::sleep(Duration::from_millis(150));
}
