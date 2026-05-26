// Rust consumer for the hierlib interface-model FFI example.
// Parity with cpp_example/main.cpp: lifecycle + requests + the Tick event.
#[path = "../../nimlib/build/hierlib_rs/src/lib.rs"]
mod hierlib;

use hierlib::Hierlib;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

fn main() {
    println!("hierlib version: {}", Hierlib::version());

    let mut lib = Hierlib::new();
    assert!(lib.create_context().is_ok(), "create_context");
    assert!(
        lib.initialize_request("cfg".to_string()).is_ok(),
        "initialize_request"
    );
    assert_eq!(*lib.get_value().value().unwrap(), 7);
    assert_eq!(*lib.echo_len("abcd".to_string()).value().unwrap(), 4);

    let received = Arc::new(AtomicI32::new(-1));
    let r2 = received.clone();
    let handle = lib.on_tick(move |n| r2.store(n, Ordering::SeqCst));
    assert_ne!(handle, 0);

    assert_eq!(*lib.fire_tick(99).value().unwrap(), 99);

    let deadline = Instant::now() + Duration::from_secs(2);
    while received.load(Ordering::SeqCst) < 0 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(received.load(Ordering::SeqCst), 99);

    lib.off_tick(handle);
    lib.shutdown();
    println!("hierlib rust example: OK");
}
