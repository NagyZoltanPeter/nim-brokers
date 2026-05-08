// Torpedo Duel — Rust wrapper example.
//
// Counterpart to the C++/Python/Go torpedo examples: bootstraps two
// captain contexts, links them, starts the duel, prints a status
// snapshot. The same source compiles for both build modes — the
// generated wrapper crate exposes an identical public surface in
// either mode.
//
//     cargo run                 # native FFI build (nimlib/build/)
//     cargo run --features cbor # CBOR FFI build   (nimlib/build_cbor/)

#[cfg(not(feature = "cbor"))]
#[path = "../../nimlib/build/torpedolib_rs/src/lib.rs"]
mod torpedolib;

#[cfg(feature = "cbor")]
#[path = "../../nimlib/build_cbor/torpedolib_rs/src/lib.rs"]
mod torpedolib;

use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use torpedolib::Torpedolib;

#[derive(Default)]
struct Counters {
    remarks: usize,
    volleys: usize,
    shots: usize,
    match_ends: Vec<String>,
}

fn main() {
    println!("=== torpedolib Rust example ===");
    println!("library version: {}", Torpedolib::version());

    let mut red = Torpedolib::new();
    let r = red.create_context();
    if !r.is_ok() {
        eprintln!("red.create_context failed: {}", r.error().unwrap_or("?"));
        std::process::exit(1);
    }
    println!("red ctx:  {}", red.ctx());

    let mut blue = Torpedolib::new();
    let b = blue.create_context();
    if !b.is_ok() {
        eprintln!("blue.create_context failed: {}", b.error().unwrap_or("?"));
        std::process::exit(1);
    }
    println!("blue ctx: {}\n", blue.ctx());

    let counters: Arc<Mutex<Counters>> = Arc::new(Mutex::new(Counters::default()));

    for lib in [&red, &blue] {
        let c1 = counters.clone();
        lib.on_captain_remark(move |_cap, _phase, _msg, _turn| {
            c1.lock().unwrap().remarks += 1;
        });
        let c2 = counters.clone();
        lib.on_volley_event(
            move |_cap, _ex, _stage, _row, _col, _reason, _hit, _sunk, _ship, _gameover, _msg| {
                c2.lock().unwrap().volleys += 1;
            },
        );
        let c3 = counters.clone();
        lib.on_shot_resolved(
            move |_cap, _turn, _row, _col, _inc, _hit, _sunk, _ship, _gameover| {
                c3.lock().unwrap().shots += 1;
            },
        );
        let c4 = counters.clone();
        lib.on_match_ended(move |captain, outcome, message, _turn| {
            c4.lock()
                .unwrap()
                .match_ends
                .push(format!("{captain} {outcome}: {message}"));
        });
    }

    // --- Initialize captains ---------------------------------------------
    let r = red.initialize_captain_request("Red".to_string(), 8, "balanced".to_string(), 101, 10);
    if r.is_ok() {
        println!("red initialize:  initialized={}", r.value().unwrap().initialized);
    }
    let r = blue.initialize_captain_request(
        "Blue".to_string(),
        8,
        "aggressive".to_string(),
        202,
        10,
    );
    if r.is_ok() {
        println!(
            "blue initialize: initialized={}\n",
            r.value().unwrap().initialized
        );
    }

    // --- Auto-place fleets (exercises seq[Object] result) ----------------
    let p = red.auto_place_fleet_request();
    if p.is_ok() {
        let v = p.value().unwrap();
        println!(
            "red autoPlace:  shipCount={} ownCells={} fleet={}",
            v.shipCount,
            v.ownCells.len(),
            v.fleet.len()
        );
    }
    let p = blue.auto_place_fleet_request();
    if p.is_ok() {
        let v = p.value().unwrap();
        println!(
            "blue autoPlace: shipCount={} ownCells={} fleet={}\n",
            v.shipCount,
            v.ownCells.len(),
            v.fleet.len()
        );
    }

    // --- Link the captains -----------------------------------------------
    let l = red.link_opponent_request(blue.ctx());
    if l.is_ok() {
        let v = l.value().unwrap();
        println!(
            "red linkOpponent: accepted={} opponentCtx={}",
            v.accepted, v.opponentCtx
        );
    }

    // --- Start the duel --------------------------------------------------
    let s = red.start_game_request();
    if s.is_ok() {
        let v = s.value().unwrap();
        println!(
            "red startGame:    accepted={} started={}\n",
            v.accepted, v.started
        );
    }

    // --- Settle, then snapshot the public board --------------------------
    thread::sleep(Duration::from_millis(300));
    let b = red.get_public_board_request();
    if b.is_ok() {
        let v = b.value().unwrap();
        println!(
            "red board snapshot: started={} fleetPlaced={} totalShotsFired={}",
            v.started, v.fleetPlaced, v.totalShotsFired
        );
    }
    let b = blue.get_public_board_request();
    if b.is_ok() {
        let v = b.value().unwrap();
        println!(
            "blue board snapshot: started={} fleetPlaced={} totalShotsFired={}\n",
            v.started, v.fleetPlaced, v.totalShotsFired
        );
    }

    let g = counters.lock().unwrap();
    println!("--- Event totals ---");
    println!("  CaptainRemark: {}", g.remarks);
    println!("  VolleyEvent:   {}", g.volleys);
    println!("  ShotResolved:  {}", g.shots);
    println!("  MatchEnded:    {}", g.match_ends.len());
    for m in &g.match_ends {
        println!("    {m}");
    }
    drop(g);

    blue.shutdown();
    red.shutdown();
    println!("OK");
}
