// Device Monitor — Rust wrapper example.
//
// Drives the same `mylib` shared library that the C, C++, Python, and
// Go examples consume. Exercises the full FFI surface: lifecycle,
// every request, every event broker. The same source compiles for
// both build modes — the generated wrapper crate exposes an identical
// public surface in either mode (the build switch lives in the
// `#[path]` module include below, not in the exercise code).
//
//     cargo run                 # native FFI build  (nimlib/build/)
//     cargo run --features cbor # CBOR FFI build    (nimlib/build_cbor/)

#[cfg(not(feature = "cbor"))]
#[path = "../../nimlib/build/mylib_rs/src/lib.rs"]
mod mylib;

#[cfg(feature = "cbor")]
#[path = "../../nimlib/build_cbor/mylib_rs/src/lib.rs"]
mod mylib;

use mylib::{AddDeviceSpec, DeviceStatus, Mylib, SensorId, Timestamp};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Default)]
struct Counters {
    discovered: Vec<String>,
    status_log: Vec<String>,
    alert_log: Vec<String>,
    batches: usize,
}

fn main() {
    println!("=== mylib Rust example ===");
    println!("library version: {}", Mylib::version());

    let mut lib = Mylib::new();
    let r = lib.create_context();
    if !r.is_ok() {
        eprintln!("create_context failed: {}", r.error().unwrap_or("?"));
        std::process::exit(1);
    }
    println!("Library context: 0x{:08X}\n", lib.ctx());

    let counters: Arc<Mutex<Counters>> = Arc::new(Mutex::new(Counters::default()));

    let h_disc = {
        let c = counters.clone();
        lib.on_device_discovered(
            move |device_id: i64, name: String, device_type: String, address: String| {
                c.lock().unwrap().discovered.push(format!(
                    "id={device_id} name={name} type={device_type} addr={address}"
                ));
            },
        )
    };
    let h_status = {
        let c = counters.clone();
        lib.on_device_status_changed(move |device_id: i64, name: String, online: bool, ts: i64| {
            let state = if online { "online" } else { "offline" };
            c.lock()
                .unwrap()
                .status_log
                .push(format!("id={device_id} {name} {state} ts={ts}"));
        })
    };
    // Second listener on the same event — exercises the dispatcher's
    // fan-out path. Mirrors the cpp example's `h_status2`.
    let h_status2 = lib.on_device_status_changed(|_id, _name, _online, _ts| {});
    let h_alert = {
        let c = counters.clone();
        lib.on_sensor_alert(
            move |sensor: SensorId, device: i64, status: DeviceStatus, ts: Timestamp| {
                c.lock().unwrap().alert_log.push(format!(
                    "sensor={sensor} device={device} status={status:?} ts={ts}"
                ));
            },
        )
    };
    let h_batch = {
        let c = counters.clone();
        lib.on_device_batch(
            move |labels: Vec<String>, device_ids: Vec<i64>, capabilities: Vec<i32>| {
                let mut g = c.lock().unwrap();
                g.batches += 1;
                println!(
                    "  >>> DeviceBatch #{}: labels={:?} ids={:?} caps={:?}",
                    g.batches, labels, device_ids, capabilities
                );
            },
        )
    };
    println!(
        "Handles: disc={h_disc} status={h_status} status2={h_status2} alert={h_alert} batch={h_batch}\n"
    );

    println!("--- Configuring library ---");
    let init = lib.initialize_request("/opt/devices.yaml".to_string());
    if init.is_ok() {
        let v = init.value().unwrap();
        println!(
            "  config={} initialized={}\n",
            v.configPath, v.initialized
        );
    } else {
        eprintln!("InitializeRequest failed: {}", init.error().unwrap_or("?"));
    }

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
        eprintln!("AddDevice failed: {}", add.error().unwrap_or("?"));
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

    println!("--- Device inventory ({} added) ---", ids.len());
    let listed = lib.list_devices();
    if listed.is_ok() {
        let v = listed.value().unwrap();
        println!("  Count: {}", v.devices.len());
        for (i, d) in v.devices.iter().enumerate() {
            let state = if d.online { "online" } else { "offline" };
            println!(
                "  [{i}] id={:<3} {:<18} type={:<10} addr={:<16} {state}",
                d.deviceId, d.name, d.deviceType, d.address
            );
        }
    }
    println!();

    println!("--- Per-device queries ---");
    for &qid in &ids {
        let gd = lib.get_device(qid);
        if !gd.is_ok() {
            continue;
        }
        let v = gd.value().unwrap();
        println!("  GetDevice({qid}): {} [{}]", v.name, v.address);

        let sd = lib.get_sensor_data(qid);
        if sd.is_ok() {
            let s = sd.value().unwrap();
            println!(
                "    GetSensorData: sensor={} {} bytes",
                s.sensorId,
                s.rawData.len()
            );
        }
        let tg = lib.get_device_tags(qid);
        if tg.is_ok() {
            println!("    GetDeviceTags: {:?}", tg.value().unwrap().tags);
        }
        let cp = lib.get_device_capabilities(qid);
        if cp.is_ok() {
            println!(
                "    GetDeviceCapabilities: {:?}",
                cp.value().unwrap().capabilities
            );
        }
        thread::sleep(Duration::from_millis(100));
    }
    println!();

    if ids.len() > 1 {
        println!("--- Removing devices ---");
        if lib.remove_device(ids[1]).is_ok() {
            println!("  RemoveDevice({}) ok", ids[1]);
        }
        if ids.len() > 2 && lib.remove_device(ids[2]).is_ok() {
            println!("  RemoveDevice({}) ok", ids[2]);
        }
        thread::sleep(Duration::from_millis(200));
        println!();
    }

    // Drop one of the listeners, let the rest keep firing.
    lib.off_device_status_changed(h_status);
    thread::sleep(Duration::from_millis(200));

    let g = counters.lock().unwrap();
    println!("--- Event totals ---");
    println!("  DeviceDiscovered events: {}", g.discovered.len());
    println!("  DeviceStatusChanged events: {}", g.status_log.len());
    println!("  SensorAlert events: {}", g.alert_log.len());
    println!("  DeviceBatch events: {}", g.batches);
    drop(g);

    lib.shutdown();
    println!("OK");
}
