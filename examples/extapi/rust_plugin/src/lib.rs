//! EXTAPI example — the `storage` plugin in Rust (R1: implement the generated
//! async trait). Uses only the generated `storage_ext` crate; no Nim, no CBOR
//! by hand. Futures run on a thread-per-call spawner, so no async runtime is
//! needed; a Nim cancel / timeout drops the future (`Abortable`).

use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::channel::oneshot;
use futures::future::BoxFuture;
use storage_ext::*;

static CANCELS: AtomicI32 = AtomicI32::new(0);

/// Counts a cancel when dropped before `done`.
struct CancelProbe {
    done: bool,
}

impl Drop for CancelProbe {
    fn drop(&mut self) {
        if !self.done {
            CANCELS.fetch_add(1, Ordering::SeqCst);
        }
    }
}

async fn sleep_ms(ms: u64) {
    let (tx, rx) = oneshot::channel::<()>();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(ms));
        let _ = tx.send(());
    });
    let _ = rx.await;
}

#[derive(Default)]
struct RustStorage {
    emitter: Mutex<Option<Emitter>>,
}

impl Storage for RustStorage {
    async fn fetch_blob(&self, key: String) -> Result<FetchBlob, String> {
        Ok(FetchBlob { data: format!("rust:{key}").into_bytes() })
    }

    async fn store_blob(&self, key: String, data: Vec<u8>) -> Result<StoreBlob, String> {
        Ok(StoreBlob { etag: format!("etag-{key}-{}", data.len()) })
    }

    // Not provided by this plugin (attach never provides it).
    async fn list_keys(&self) -> Result<ListKeys, String> {
        Err("not provided".into())
    }

    // Slow: 2 s unless Nim cancels (the future is dropped at an await).
    async fn compact(&self, level: i32) -> Result<Compact, String> {
        let mut probe = CancelProbe { done: false };
        for _ in 0..200 {
            sleep_ms(10).await;
        }
        probe.done = true;
        Ok(Compact { freed: level as i64 * 1024 })
    }

    // One-way: react by emitting an event from another thread.
    fn compact_hint(&self, h: CompactHint) {
        if let Some(e) = self.emitter.lock().unwrap().clone() {
            std::thread::spawn(move || {
                e.blob_evicted(&BlobEvicted { key: format!("k{}", h.urgency), reason: "compact".into() });
            });
        }
    }
}

static PORT: Mutex<Option<Port>> = Mutex::new(None);

fn thread_spawner(f: BoxFuture<'static, ()>) {
    std::thread::spawn(move || futures::executor::block_on(f));
}

fn attach(host: *const ffi::BrokerExtHost, ctx: u32) -> i32 {
    let mut slot = PORT.lock().unwrap();
    let imp = Arc::new(RustStorage::default());
    let port = match Port::open(unsafe { Host::from_raw(host) }, ctx, imp.clone(), thread_spawner) {
        Ok(p) => p,
        Err(_) => return BAD_ARG,
    };
    // Provide individually: list_keys is deliberately left out.
    for a in [Api::FetchBlob, Api::StoreBlob, Api::Compact, Api::CompactHint] {
        let rc = port.provide(a);
        if rc != OK {
            return rc;
        }
    }
    *imp.emitter.lock().unwrap() = Some(port.emitter());
    *slot = Some(port);
    OK
}

/// Exe mode entry point, called by ExtHost.loadPlugin(). Opens on
/// DefaultBrokerContext (1).
#[no_mangle]
pub extern "C" fn broker_ext_plugin_entry(host: *const ffi::BrokerExtHost) -> i32 {
    attach(host, 1)
}

// Example-specific controls (scenario 2: detach / re-attach at runtime).
#[no_mangle]
pub extern "C" fn storage_plugin_attach(host: *const ffi::BrokerExtHost, ctx: u32) -> i32 {
    attach(host, ctx)
}

#[no_mangle]
pub extern "C" fn storage_plugin_detach() -> i32 {
    // Port::drop closes it.
    PORT.lock().unwrap().take();
    OK
}

#[no_mangle]
pub extern "C" fn storage_plugin_cancels() -> i32 {
    CANCELS.load(Ordering::SeqCst)
}
