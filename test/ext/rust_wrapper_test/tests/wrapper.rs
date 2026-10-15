//! Drives the generated `life_ext` crate through a fake host table: the test
//! plays the Nim host (calls `invoke` / `cancel`) and records the replies.

use std::ffi::{c_char, c_void};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use futures::future::BoxFuture;
use life_ext::ffi::{BrokerExtHost, BrokerExtImpl};
use life_ext::*;

#[derive(Clone, Copy)]
struct Captured {
    invoke: unsafe extern "C" fn(*mut c_void, u64, u32, *const c_char, *const u8, usize),
    cancel: unsafe extern "C" fn(*mut c_void, u64),
    user: usize,
}

static SERIAL: Mutex<()> = Mutex::new(());
static IMPL: Mutex<Option<Captured>> = Mutex::new(None);
static REPLIES: Mutex<Vec<(u64, i32, Vec<u8>)>> = Mutex::new(Vec::new());

fn lk<T>(m: &'static Mutex<T>) -> MutexGuard<'static, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

unsafe extern "C" fn h_open(_h: *mut c_void, _ctx: u32, imp: *const BrokerExtImpl, out: *mut u64) -> i32 {
    let imp = &*imp;
    *lk(&IMPL) = Some(Captured {
        invoke: imp.invoke.unwrap(),
        cancel: imp.cancel.unwrap(),
        user: imp.user as usize,
    });
    *out = 1;
    0
}
unsafe extern "C" fn h_close(_h: *mut c_void, _p: u64) -> i32 {
    0
}
unsafe extern "C" fn h_name(_h: *mut c_void, _p: u64, _n: *const c_char) -> i32 {
    0
}
unsafe extern "C" fn h_reply(_h: *mut c_void, _p: u64, id: u64, st: i32, b: *const u8, n: usize) -> i32 {
    let v = if n == 0 { Vec::new() } else { std::slice::from_raw_parts(b, n).to_vec() };
    lk(&REPLIES).push((id, st, v));
    0
}
unsafe extern "C" fn h_emit(_h: *mut c_void, _p: u64, _n: *const c_char, _b: *const u8, _l: usize) -> i32 {
    0
}

fn host() -> Host {
    let t = Box::leak(Box::new(BrokerExtHost {
        abi_version: 1,
        host: std::ptr::null_mut(),
        open: Some(h_open),
        close: Some(h_close),
        provide: Some(h_name),
        withdraw: Some(h_name),
        reply: Some(h_reply),
        emit: Some(h_emit),
        list_apis: None,
        get_schema: None,
        free_buffer: None,
        schema_hash: None,
    }));
    unsafe { Host::from_raw(t) }
}

fn invoke(api: Api, id: u64, args: &[u8]) {
    let c = lk(&IMPL).unwrap();
    let name = format!("{}\0", api.wire_name());
    unsafe { (c.invoke)(c.user as *mut c_void, id, api as u32, name.as_ptr() as *const c_char, args.as_ptr(), args.len()) };
}

fn cancel(id: u64) {
    let c = lk(&IMPL).unwrap();
    unsafe { (c.cancel)(c.user as *mut c_void, id) };
}

fn reply_for(id: u64, wait: Duration) -> Option<(i32, Vec<u8>)> {
    let deadline = Instant::now() + wait;
    loop {
        if let Some((_, st, b)) = lk(&REPLIES).iter().find(|r| r.0 == id).cloned() {
            return Some((st, b));
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn cbor<T: serde_like::Ser>(v: &T) -> Vec<u8> {
    v.bytes()
}

mod serde_like {
    pub trait Ser {
        fn bytes(&self) -> Vec<u8>;
    }
    impl Ser for (&str, i64) {
        fn bytes(&self) -> Vec<u8> {
            let mut m = std::collections::BTreeMap::new();
            m.insert(self.0.to_string(), self.1);
            let mut out = Vec::new();
            ciborium::into_writer(&m, &mut out).unwrap();
            out
        }
    }
}

fn n_of(b: &[u8]) -> i64 {
    let m: std::collections::BTreeMap<String, i64> = ciborium::from_reader(b).unwrap();
    m["n"]
}

fn thread_spawner(f: BoxFuture<'static, ()>) {
    std::thread::spawn(move || futures::executor::block_on(f));
}

struct SyncImpl;
impl LifeSync for SyncImpl {
    fn life_bridge(&self, _: &CancelFlag) -> Result<LifeBridge, String> {
        Err("unused".into())
    }
    fn life_dual_args(&self, _: i32, _: &CancelFlag) -> Result<LifeDual, String> {
        Err("unused".into())
    }
    fn life_dual_zero(&self, _: &CancelFlag) -> Result<LifeDual, String> {
        Err("unused".into())
    }
    fn life_echo(&self, x: i32, _: &CancelFlag) -> Result<LifeEcho, String> {
        if x < 0 {
            panic!("negative {x}");
        }
        Ok(LifeEcho { n: x * 2 })
    }
    fn life_hook_bridge(&self, _: &CancelFlag) -> Result<LifeHookBridge, String> {
        Err("unused".into())
    }
    fn life_hook_worker(&self, _: &CancelFlag) -> Result<LifeHookWorker, String> {
        Err("unused".into())
    }
    fn life_owned(&self, _: &CancelFlag) -> Result<LifeOwned, String> {
        Err("unused".into())
    }
    fn life_sig(&self, _: LifeSig) {}
    fn life_tid(&self, _: &CancelFlag) -> Result<LifeTid, String> {
        Err("unused".into())
    }
    fn life_work(&self, _: &CancelFlag) -> Result<LifeWork, String> {
        Err("unused".into())
    }
}

#[test]
fn r2_sync_replies_inline() {
    let _s = lk(&SERIAL);
    let _port = Port::open_sync(host(), 1, Arc::new(SyncImpl)).unwrap();
    invoke(Api::LifeEcho, 11, &cbor(&("x", 21)));
    // REPLY_INLINE: the reply is there when invoke returns.
    let (st, b) = reply_for(11, Duration::ZERO).expect("inline reply");
    assert_eq!(st, REPLY_OK);
    assert_eq!(n_of(&b), 42);
}

#[test]
fn r2_panic_becomes_error_with_message() {
    let _s = lk(&SERIAL);
    let _port = Port::open_sync(host(), 1, Arc::new(SyncImpl)).unwrap();
    invoke(Api::LifeEcho, 12, &cbor(&("x", -1)));
    let (st, b) = reply_for(12, Duration::ZERO).expect("reply");
    assert_eq!(st, REPLY_ERR);
    assert!(String::from_utf8_lossy(&b).contains("negative -1"));
}

#[test]
fn r1_panic_in_future_becomes_error_with_message() {
    let _s = lk(&SERIAL);
    let _port = Builder::new()
        .spawner(thread_spawner)
        .life_echo(|_x: i32| async move {
            if true {
                panic!("boom");
            }
            Ok(LifeEcho { n: 0 })
        })
        .open(host(), 1)
        .unwrap();
    invoke(Api::LifeEcho, 13, &cbor(&("x", 1)));
    let (st, b) = reply_for(13, Duration::from_secs(5)).expect("reply");
    assert_eq!(st, REPLY_ERR);
    assert!(String::from_utf8_lossy(&b).contains("plugin panicked: boom"));
}

#[test]
fn r1_future_dropped_by_executor_replies_dropped() {
    let _s = lk(&SERIAL);
    let _port = Builder::new()
        .spawner(|f: BoxFuture<'static, ()>| drop(f)) // an executor that discards work
        .life_echo(|x: i32| async move { Ok(LifeEcho { n: x }) })
        .open(host(), 1)
        .unwrap();
    invoke(Api::LifeEcho, 14, &cbor(&("x", 1)));
    let (st, b) = reply_for(14, Duration::from_secs(1)).expect("a reply, not a hang");
    assert_eq!(st, REPLY_ERR);
    assert_eq!(b, b"dropped");
}

#[test]
fn r1_cancel_drops_the_future_without_reply() {
    let _s = lk(&SERIAL);
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    let tx = Arc::new(Mutex::new(Some(tx)));
    let _port = Builder::new()
        .spawner(thread_spawner)
        .life_echo(move |_x: i32| {
            let tx = tx.clone();
            async move {
                struct OnDrop(Arc<Mutex<Option<std::sync::mpsc::Sender<()>>>>);
                impl Drop for OnDrop {
                    fn drop(&mut self) {
                        if let Some(t) = self.0.lock().unwrap().take() {
                            let _ = t.send(());
                        }
                    }
                }
                let _probe = OnDrop(tx);
                futures::future::pending::<()>().await;
                Ok(LifeEcho { n: 0 })
            }
        })
        .open(host(), 1)
        .unwrap();
    invoke(Api::LifeEcho, 15, &cbor(&("x", 1)));
    std::thread::sleep(Duration::from_millis(50));
    cancel(15);
    assert!(rx.recv_timeout(Duration::from_secs(2)).is_ok(), "future dropped on cancel");
    assert!(reply_for(15, Duration::from_millis(100)).is_none(), "no reply after cancel");
}

#[test]
fn cancel_of_unknown_id_is_harmless() {
    let _s = lk(&SERIAL);
    let _port = Port::open_sync(host(), 1, Arc::new(SyncImpl)).unwrap();
    cancel(9999); // must not panic across the C boundary
}
