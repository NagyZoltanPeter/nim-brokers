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

    // One-way signal (fire-and-forget, no response): nudge the value; poll
    // get_value for the observable effect once the handler has run.
    lib.nudge_signal(10).expect("nudge_signal");
    let sig_deadline = Instant::now() + Duration::from_secs(2);
    while *lib.get_value().value().unwrap() == 7 && Instant::now() < sig_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(*lib.get_value().value().unwrap(), 17);

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

    // reduced-A: create a sub-interface instance, drive its own methods (routed
    // to the same processing thread via shared classCtx), then release it.
    {
        let mut widget = lib.make_widget(5).into_result().expect("make_widget");
        assert_ne!(widget.ctx(), 0);
        assert_eq!(*widget.area().value().unwrap(), 25);
        assert_eq!(*widget.scale(3).value().unwrap(), 15);
        assert_eq!(*widget.area().value().unwrap(), 225);

        // Sub-interface one-way signal: routes to THIS widget by its ctx
        // (size 15 -> 20 -> area 400). Poll area for the async delivery.
        widget.resize_signal(5).expect("resize_signal");
        let sig_dl = Instant::now() + Duration::from_secs(2);
        while *widget.area().value().unwrap() == 225 && Instant::now() < sig_dl {
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(*widget.area().value().unwrap(), 400);

        // A second, independent widget (own instanceCtx, same library).
        let w2 = lib.make_widget(2).into_result().expect("make_widget 2");
        assert_eq!(*w2.area().value().unwrap(), 4);
        // w2 released by its Drop at scope exit.

        widget.close(); // explicit release
        widget.close(); // idempotent
        assert!(widget.area().is_err(), "post-release call must error");
    }

    lib.shutdown();
    println!("hierlib rust example: OK");
}
