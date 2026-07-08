// Device Monitor — Rust wrapper example.
//
// Functional parity with cpp_example/main.cpp: same inline event
// printouts, same request flow, same listener-removal pattern.
//
//     cargo run   # builds against the FFI library in nimlib/build/

#[path = "../../nimlib/build/mylib_rs/src/lib.rs"]
mod mylib;

use mylib::{AddDeviceSpec, DeviceStatus, Mylib, SensorId, Timestamp};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

fn quote_strings(ss: &[String]) -> String {
    ss.iter()
        .map(|s| format!("\"{s}\""))
        .collect::<Vec<_>>()
        .join(", ")
}

fn join_i64(vs: &[i64]) -> String {
    vs.iter()
        .map(|v| v.to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

fn join_i32(vs: &[i32]) -> String {
    vs.iter()
        .map(|v| v.to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

fn main() {
    println!("=== Device Monitor — Rust Example ===\n");

    let mut lib = Mylib::new();
    let r = lib.create_context();
    if !r.is_ok() {
        eprintln!("FATAL: {}", r.error().unwrap_or("?"));
        std::process::exit(1);
    }
    println!("Library context: 0x{:08X}\n", lib.ctx());

    println!("--- Subscribing to events ---");

    let discovery_count = Arc::new(AtomicI32::new(0));
    let status_count = Arc::new(AtomicI32::new(0));
    let batch_count = Arc::new(AtomicI32::new(0));

    let h_disc = {
        let c = discovery_count.clone();
        lib.on_device_discovered(move |id: i64, name: String, typ: String, addr: String| {
            let n = c.fetch_add(1, Ordering::SeqCst) + 1;
            println!("  >>> DeviceDiscovered #{n}: id={id}  \"{name}\"  [{typ}]  {addr}");
        })
    };
    let h_status = {
        let c = status_count.clone();
        lib.on_device_status_changed(move |id: i64, name: String, online: bool, ts: i64| {
            let n = c.fetch_add(1, Ordering::SeqCst) + 1;
            let state = if online { "ONLINE" } else { "OFFLINE" };
            println!("  >>> DeviceStatusChanged #{n}: id={id}  \"{name}\"  {state}  (ts={ts})");
        })
    };
    let h_batch = {
        let c = batch_count.clone();
        lib.on_device_batch(
            move |labels: Vec<String>, device_ids: Vec<i64>, capabilities: Vec<i32>| {
                let n = c.fetch_add(1, Ordering::SeqCst) + 1;
                println!("  >>> DeviceBatch #{n}: {} devices", labels.len());
                println!("      labels:       [{}]", quote_strings(&labels));
                println!("      ids:          [{}]", join_i64(&device_ids));
                println!("      capabilities: [{}]", join_i32(&capabilities));
            },
        )
    };
    let h_alert = lib.on_sensor_alert(
        |sensor_id: SensorId, device_id: i64, status: DeviceStatus, ts: Timestamp| {
            println!(
                "  >>> SensorAlert: sensorId={sensor_id}  deviceId={device_id}  status={}  ts={ts}",
                status as i32
            );
        },
    );
    println!("  SensorAlert handle: {h_alert}");
    let h_status2 = lib.on_device_status_changed(|_id, name: String, online: bool, _ts| {
        let state = if online { "UP" } else { "DOWN" };
        println!("  >>> [Logger] {name} is now {state}");
    });
    println!("  Handles: discovered={h_disc}  status={h_status}  status2={h_status2}  batch={h_batch}\n");

    // --- Configure -------------------------------------------------------
    println!("--- Configuring library ---");
    let init = lib.initialize_request("/opt/devices.yaml".to_string());
    if !init.is_ok() {
        eprintln!("Initialize error: {}", init.error().unwrap_or("?"));
        lib.shutdown();
        std::process::exit(1);
    }
    let v = init.value().unwrap();
    println!(
        "  config={}  initialized={}\n",
        v.configPath,
        if v.initialized { "yes" } else { "no" }
    );

    // --- Add devices ----------------------------------------------------
    println!("--- Adding devices ---");
    let fleet = vec![
        AddDeviceSpec {
            name: "Core-Router".to_string(),
            deviceType: "router".to_string(),
            address: "10.0.0.1".to_string(),
        },
        AddDeviceSpec {
            name: "Edge-Switch-A".to_string(),
            deviceType: "switch".to_string(),
            address: "10.0.1.1".to_string(),
        },
        AddDeviceSpec {
            name: "Edge-Switch-B".to_string(),
            deviceType: "switch".to_string(),
            address: "10.0.1.2".to_string(),
        },
        AddDeviceSpec {
            name: "AP-Floor-3".to_string(),
            deviceType: "ap".to_string(),
            address: "10.0.2.10".to_string(),
        },
        AddDeviceSpec {
            name: "TempSensor-DC1".to_string(),
            deviceType: "sensor".to_string(),
            address: "10.0.3.50".to_string(),
        },
    ];
    let add = lib.add_device(fleet);
    if !add.is_ok() {
        eprintln!("  AddDevice error: {}", add.error().unwrap_or("?"));
        lib.shutdown();
        std::process::exit(1);
    }
    let added = add.value().unwrap();
    let ids: Vec<i64> = added.devices.iter().map(|d| d.deviceId).collect();
    for d in &added.devices {
        println!("  + {} -> id={}", d.name, d.deviceId);
    }
    thread::sleep(Duration::from_millis(300));
    println!();

    // --- Inventory ------------------------------------------------------
    println!("--- Device inventory ({} added) ---", ids.len());
    let listed = lib.list_devices();
    if listed.is_ok() {
        let v = listed.value().unwrap();
        println!("  Count: {}", v.devices.len());
        for (i, d) in v.devices.iter().enumerate() {
            let state = if d.online { "online" } else { "offline" };
            println!(
                "  [{i}] id={:<3}  {:<18}  type={:<10}  addr={:<16}  {state}",
                d.deviceId, d.name, d.deviceType, d.address
            );
        }
    }
    println!();

    // --- Async queries (tokio .await) -----------------------------------
    // get_device_async() returns a std Result<T, AsyncError> resolved on the
    // library's delivery thread via a runtime-agnostic futures-channel oneshot
    // — it composes with `?`, and backpressure/timeout/shutdown are MATCHABLE
    // variants: AsyncError::Again (window full, mylib::ASYNC_QUEUE_DEPTH —
    // retry), AsyncError::TimedOut (-12), AsyncError::ShutDown (-11),
    // AsyncError::Provider(msg) for handler errors.
    // Per-call deadline: pass `Some(ms)` as the trailing `timeout_ms` arg (the
    // ABI carries it); `None` uses the library default
    // (mylib::DEFAULT_ASYNC_TIMEOUT_MS). On expiry the call resolves to
    // AsyncError::TimedOut (-12). You can still stack your runtime's own timer
    // (e.g. tokio::time::timeout) on top for a client-side deadline.
    println!("--- Async device queries (get_device_async) ---");
    println!("  async window = {} in-flight", mylib::ASYNC_QUEUE_DEPTH);
    {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime");
        rt.block_on(async {
            for &qid in &ids {
                match lib.get_device_async(qid, Some(500)).await {
                    Ok(d) => {
                        let state = if d.online { "online" } else { "offline" };
                        println!("  [async] id={qid} -> \"{}\" ({state})", d.name);
                    }
                    Err(mylib::AsyncError::Again) => {
                        // Window full — a real caller backs off and retries.
                        println!("  [async] id={qid} -> window full (retry later)");
                    }
                    Err(e) => println!("  [async] id={qid} -> error: {e}"),
                }
            }
        });
        println!("  All async queries completed.");
    }
    println!();

    // --- Async without tokio (futures::executor::block_on) --------------
    // The generated crate depends only on futures-channel: the same _async
    // methods run under ANY executor. Prove it with futures' minimal block_on
    // — no tokio runtime in sight.
    if !ids.is_empty() {
        println!("--- Async query without tokio (block_on) ---");
        let qid = ids[0];
        match futures::executor::block_on(lib.get_device_async(qid, None)) {
            Ok(d) => println!("  [block_on] id={qid} -> \"{}\"", d.name),
            Err(e) => println!("  [block_on] id={qid} -> error: {e}"),
        }
        println!();
    }

    // --- Query one (cpp picks ids[2]) ----------------------------------
    if ids.len() > 2 {
        let qid = ids[2];
        println!("--- Query device id={qid} ---");
        let gd = lib.get_device(qid);
        if gd.is_ok() {
            let v = gd.value().unwrap();
            let online = if v.online { "yes" } else { "no" };
            println!(
                "  name=\"{}\"  type=\"{}\"  addr=\"{}\"  online={online}",
                v.name, v.deviceType, v.address
            );
        }
        println!();
    }

    // --- New type demos (cpp uses ids[0]) ------------------------------
    if !ids.is_empty() {
        let qid = ids[0];
        println!("--- GetSensorData (seq[byte] + enum + distinct) ---");
        let sd = lib.get_sensor_data(qid);
        if sd.is_ok() {
            let v = sd.value().unwrap();
            let n = v.rawData.len().min(8);
            let bytes: Vec<String> = v.rawData[..n].iter().map(|b| format!("0x{b:02X}")).collect();
            println!(
                "  sensorId={}  status={}  rawData[{}]: {}",
                v.sensorId,
                v.status as i32,
                v.rawData.len(),
                bytes.join(" ")
            );
        }
        println!("--- GetDeviceTags (seq[string]) ---");
        let tg = lib.get_device_tags(qid);
        if tg.is_ok() {
            let v = tg.value().unwrap();
            println!("  tags[{}]: {}", v.tags.len(), quote_strings(&v.tags));
        }
        println!("--- GetDeviceCapabilities (array[4,int32] + Timestamp) ---");
        let cp = lib.get_device_capabilities(qid);
        if cp.is_ok() {
            let v = cp.value().unwrap();
            println!(
                "  capturedAt={}  caps=[{}]",
                v.capturedAt as i64,
                join_i32(&v.capabilities)
            );
        }
        thread::sleep(Duration::from_millis(200));
        println!();
    }

    // --- Remove two -----------------------------------------------------
    println!("--- Removing devices ---");
    for &i in &[0usize, 3] {
        if i >= ids.len() {
            continue;
        }
        let rm = lib.remove_device(ids[i]);
        if rm.is_ok() {
            let v = rm.value().unwrap();
            let ok = if v.success { "yes" } else { "no" };
            println!("  Removed id={}  success={ok}", ids[i]);
        } else {
            eprintln!("  RemoveDevice error: {}", rm.error().unwrap_or("?"));
        }
    }
    thread::sleep(Duration::from_millis(200));
    println!();

    // --- Drop primary status listener -----------------------------------
    println!("--- Removing first status listener (keeping logger) ---");
    lib.off_device_status_changed(h_status);
    println!("  Removed handle {h_status}\n");

    // --- One more removal (logger only) ---------------------------------
    println!("--- Removing one more device (only logger active) ---");
    if ids.len() > 1 && lib.remove_device(ids[1]).is_ok() {
        println!("  Removed id={}", ids[1]);
    }
    thread::sleep(Duration::from_millis(200));
    println!();

    // --- Remaining ------------------------------------------------------
    println!("--- Remaining devices ---");
    let listed = lib.list_devices();
    if listed.is_ok() {
        let v = listed.value().unwrap();
        println!("  Count: {}", v.devices.len());
        for d in &v.devices {
            let state = if d.online { "online" } else { "offline" };
            println!(
                "  id={:<3}  {:<18}  type={:<10}  addr={:<16}  {state}",
                d.deviceId, d.name, d.deviceType, d.address
            );
        }
    }
    println!();

    // --- One-way signal (IngestReading) + readback (LastReading) --------
    println!("--- Firing IngestReading signals (one-way, slot-free) ---");
    if let Err(e) = lib.ingest_reading(42, 3.5) {
        eprintln!("FATAL: ingest_reading: {}", e);
        std::process::exit(1);
    }
    if let Err(e) = lib.ingest_reading(42, 7.25) {
        eprintln!("FATAL: ingest_reading: {}", e);
        std::process::exit(1);
    }
    thread::sleep(Duration::from_millis(50));
    let rb = lib.last_reading();
    match rb.value() {
        Some(v) => {
            println!(
                "  LastReading: deviceId={} value={} count={}",
                v.deviceId, v.value, v.count
            );
            assert!(
                v.count == 2 && v.deviceId == 42 && v.value == 7.25,
                "signal round-trip mismatch"
            );
            println!("  Signal round-trip verified.\n");
        }
        None => {
            eprintln!("FATAL: last_reading: {}", rb.error().unwrap_or("?"));
            std::process::exit(1);
        }
    }

    // --- Unsubscribe all ------------------------------------------------
    println!("--- Unsubscribing all ---");
    lib.off_device_discovered(0); // 0 -> remove all
    lib.off_sensor_alert(0);
    lib.off_device_batch(h_batch);
    lib.off_device_status_changed(0);
    println!("  All event listeners removed.\n");

    println!(
        "  Total discovery events received: {}",
        discovery_count.load(Ordering::SeqCst)
    );
    println!(
        "  Total status events received: {}\n",
        status_count.load(Ordering::SeqCst)
    );
    println!(
        "  Total batch events received:    {}\n",
        batch_count.load(Ordering::SeqCst)
    );

    println!("--- Shutting down (RAII) ---");
    lib.shutdown();
    println!("\n=== Rust example complete ===");
}
