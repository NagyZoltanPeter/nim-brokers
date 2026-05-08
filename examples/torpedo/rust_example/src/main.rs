// Torpedo Duel — Rust example.
//
// A minimal counterpart to the Python and C++ Torpedo examples: bootstraps
// two captain contexts, links them, starts the duel, and prints a status
// snapshot. Keeps the focus on demonstrating the Rust wrapper surface
// (request methods, Result<T> envelopes, lifecycle) rather than
// reproducing the Python text UI.
//
//     cargo run                 # native FFI build  (nimlib/build/)
//     cargo run --features cbor # CBOR FFI build    (nimlib/build_cbor/)
//
// In native mode, the v1 codegen emits TODO stubs for request/event payloads
// that contain `seq[T]` / nested object fields, so this example only
// exercises the lifecycle + a couple of primitive-only requests on the
// native side. The CBOR build supports the full type matrix and is exercised
// end-to-end via the matching cargo feature.

#[cfg(not(feature = "cbor"))]
#[path = "../../nimlib/build/torpedolib_rs/src/lib.rs"]
mod torpedolib;

#[cfg(feature = "cbor")]
#[path = "../../nimlib/build_cbor/torpedolib_rs/src/lib.rs"]
mod torpedolib;

use torpedolib::Torpedolib;

fn main() {
    println!("=== torpedolib Rust example ===");
    println!("library version: {}", Torpedolib::version());

    let mut red = Torpedolib::new();
    let r = red.create_context();
    if !r.is_ok() {
        eprintln!("red.create_context failed: {}", r.error().unwrap_or("?"));
        std::process::exit(1);
    }
    println!("red ctx: {}", red.ctx());

    let mut blue = Torpedolib::new();
    let b = blue.create_context();
    if !b.is_ok() {
        eprintln!("blue.create_context failed: {}", b.error().unwrap_or("?"));
        std::process::exit(1);
    }
    println!("blue ctx: {}", blue.ctx());

    #[cfg(feature = "cbor")]
    cbor_exercise(&red, &blue);

    #[cfg(not(feature = "cbor"))]
    native_exercise(&red, &blue);

    blue.shutdown();
    red.shutdown();
    println!("OK");
}

#[cfg(not(feature = "cbor"))]
fn native_exercise(red: &Torpedolib, blue: &Torpedolib) {
    // Primitive-only request — exercises the native v1 codegen surface.
    let init = red.initialize_captain_request(
        "Red".to_string(),
        8,
        "balanced".to_string(),
        101,
        50,
    );
    match init.is_ok() {
        true => println!(
            "red initialize_captain_request OK: {:?}",
            init.value().unwrap()
        ),
        false => eprintln!(
            "red initialize_captain_request failed: {}",
            init.error().unwrap_or("?")
        ),
    }
    let _ = blue;
}

#[cfg(feature = "cbor")]
fn cbor_exercise(red: &Torpedolib, blue: &Torpedolib) {
    let init_red = red.initialize_captain_request(
        "Red".to_string(),
        8,
        "balanced".to_string(),
        101,
        10,
    );
    println!("red initialize: {:?}", init_red.is_ok());

    let init_blue = blue.initialize_captain_request(
        "Blue".to_string(),
        8,
        "aggressive".to_string(),
        202,
        10,
    );
    println!("blue initialize: {:?}", init_blue.is_ok());

    // CBOR mode handles seq[PublicCell] / seq[ShipStatus] etc., so we can
    // exercise auto_place_fleet_request which returns those.
    let place_red = red.auto_place_fleet_request();
    if place_red.is_ok() {
        let v = place_red.value().unwrap();
        println!(
            "red auto_place_fleet_request OK: shipCount={}, ownCells={}, fleet={}",
            v.shipCount,
            v.ownCells.len(),
            v.fleet.len()
        );
    } else {
        eprintln!(
            "red auto_place_fleet_request failed: {}",
            place_red.error().unwrap_or("?")
        );
    }

    let place_blue = blue.auto_place_fleet_request();
    println!("blue auto_place_fleet_request: {:?}", place_blue.is_ok());

    // Link and start.
    let link = red.link_opponent_request(blue.ctx());
    println!("red.link_opponent_request: {:?}", link.is_ok());

    let start = red.start_game_request();
    println!("red.start_game_request: {:?}", start.is_ok());

    // Sample the public board after a brief settle.
    std::thread::sleep(std::time::Duration::from_millis(100));
    let board = red.get_public_board_request();
    if board.is_ok() {
        let v = board.value().unwrap();
        println!(
            "red board snapshot: started={}, fleetPlaced={}, totalShotsFired={}",
            v.started, v.fleetPlaced, v.totalShotsFired
        );
    }
}
