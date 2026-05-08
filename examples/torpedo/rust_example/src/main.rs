// Torpedo Duel — Rust text UI example.
//
// Functional parity with python_example/main.py: bootstraps two captain
// contexts, links them bidirectionally, starts the duel, polls
// get_public_board_request in a render loop until gameOver. Renders
// both own/enemy boards, fleet status, meta panels, and a tail of the
// event log driven by the broker callbacks.
//
//     cargo run                 # native FFI build (nimlib/build/)
//     cargo run --features cbor # CBOR FFI build   (nimlib/build_cbor/)

#[cfg(not(feature = "cbor"))]
#[path = "../../nimlib/build/torpedolib_rs/src/lib.rs"]
mod torpedolib;

#[cfg(feature = "cbor")]
#[path = "../../nimlib/build_cbor/torpedolib_rs/src/lib.rs"]
mod torpedolib;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use torpedolib::{GetPublicBoardRequest, PublicCell, ShipStatus, Torpedolib};

const MAX_LOG_ENTRIES: usize = 16;
const REFRESH_MS: u64 = 180;
const TURN_DELAY_MS: i32 = 650;
const END_DELAY_MS: u64 = 1000;
const MAX_ITERATIONS: usize = 600;

fn coord(row: i32, col: i32) -> String {
    format!("{}{}", (b'A' + col as u8) as char, row + 1)
}

fn cell_symbol(state_code: i32, own_board: bool) -> char {
    if own_board {
        match state_code {
            0 | 1 => '.',
            2 => 'S',
            3 => 'o',
            4 => 'x',
            5 => '*',
            _ => '?',
        }
    } else {
        match state_code {
            0 | 1 => '.',
            2 => '!', // OwnShip should never appear in enemy view
            3 => 'o',
            4 => 'x',
            5 => '*',
            _ => '?',
        }
    }
}

fn build_matrix(cells: &[PublicCell], size: i32, own_board: bool) -> Vec<String> {
    let s = size as usize;
    let mut grid = vec![vec!['.'; s]; s];
    for c in cells {
        if c.row >= 0 && c.col >= 0 && (c.row as usize) < s && (c.col as usize) < s {
            grid[c.row as usize][c.col as usize] = cell_symbol(c.stateCode, own_board);
        }
    }
    let mut hdr = String::from("  ");
    for c in 0..size {
        hdr.push((b'A' + c as u8) as char);
        hdr.push(' ');
    }
    let mut out = vec![hdr.trim_end().to_string()];
    for (r, row) in grid.iter().enumerate() {
        let line = format!(
            "{:<2}{}",
            r + 1,
            row.iter()
                .map(|ch| ch.to_string())
                .collect::<Vec<_>>()
                .join(" ")
        );
        out.push(line);
    }
    out
}

fn format_fleet(fleet: &[ShipStatus]) -> Vec<String> {
    fleet
        .iter()
        .map(|s| {
            let status = if s.sunk {
                "sunk".to_string()
            } else {
                format!("{}/{}", s.hits, s.length)
            };
            format!("{:<12} {}", s.name, status)
        })
        .collect()
}

fn format_status(v: &GetPublicBoardRequest) -> Vec<String> {
    let yn = |b: bool| if b { "yes" } else { "no" };
    let outcome = if v.hasWon {
        "won"
    } else if v.gameOver {
        "lost"
    } else {
        "active"
    };
    vec![
        format!("AI         {}", v.aiMode),
        format!("Delay      {} ms", v.turnDelayMs),
        format!("Placed     {}", yn(v.fleetPlaced)),
        format!("Linked     {}", yn(v.linked)),
        format!("Started    {}", yn(v.started)),
        format!("Opponent   {}", v.opponentCtx),
        format!("Outcome    {}", outcome),
    ]
}

fn side_by_side(left: &[String], right: &[String], gap: usize) -> Vec<String> {
    let width = left.iter().map(|s| s.len()).max().unwrap_or(0);
    let height = left.len().max(right.len());
    let mut out = Vec::with_capacity(height);
    for i in 0..height {
        let l = left.get(i).map(String::as_str).unwrap_or("");
        let r = right.get(i).map(String::as_str).unwrap_or("");
        let pad = " ".repeat(width - l.len() + gap);
        out.push(format!("{l}{pad}{r}"));
    }
    out
}

fn draw_screen(
    red: &GetPublicBoardRequest,
    blue: &GetPublicBoardRequest,
    log: &VecDeque<String>,
    iter: usize,
) {
    print!("\x1b[2J\x1b[H");
    println!("Torpedo Duel — Rust");
    println!("Tick={iter}  backend duel is self-driven\n");

    let red_own = build_matrix(&red.ownCells, red.boardSize, true);
    let red_enemy = build_matrix(&red.enemyCells, red.boardSize, false);
    let blue_own = build_matrix(&blue.ownCells, blue.boardSize, true);
    let blue_enemy = build_matrix(&blue.enemyCells, blue.boardSize, false);

    let mut left = vec!["RED FLEET".to_string(), "Own Waters".to_string()];
    left.extend(red_own);
    left.push(String::new());
    left.push("Enemy Chart".to_string());
    left.extend(red_enemy);

    let mut right = vec!["BLUE FLEET".to_string(), "Own Waters".to_string()];
    right.extend(blue_own);
    right.push(String::new());
    right.push("Enemy Chart".to_string());
    right.extend(blue_enemy);

    for line in side_by_side(&left, &right, 4) {
        println!("{line}");
    }
    println!();

    let mut fl = vec!["RED STATUS".to_string()];
    fl.extend(format_fleet(&red.fleet));
    let mut fr = vec!["BLUE STATUS".to_string()];
    fr.extend(format_fleet(&blue.fleet));
    for line in side_by_side(&fl, &fr, 4) {
        println!("{line}");
    }
    println!();

    let mut ml = vec!["RED META".to_string()];
    ml.extend(format_status(red));
    let mut mr = vec!["BLUE META".to_string()];
    mr.extend(format_status(blue));
    for line in side_by_side(&ml, &mr, 4) {
        println!("{line}");
    }
    println!();

    println!("Scoreboard");
    println!(
        "Red fired={:<2} received={:<2}  |  Blue fired={:<2} received={:<2}\n",
        red.totalShotsFired, red.totalShotsReceived, blue.totalShotsFired, blue.totalShotsReceived
    );

    println!("Event Log");
    for line in log {
        println!("- {line}");
    }
}

fn push_log(log: &Arc<Mutex<VecDeque<String>>>, s: String) {
    let mut g = log.lock().unwrap();
    g.push_back(s);
    while g.len() > MAX_LOG_ENTRIES {
        g.pop_front();
    }
}

fn subscribe(lib: &Torpedolib, log: &Arc<Mutex<VecDeque<String>>>) {
    let l1 = log.clone();
    lib.on_captain_remark(move |captain: String, phase: String, message: String, turn: i32| {
        push_log(&l1, format!("{captain} [{phase}] t{turn}: {message}"));
    });
    let l2 = log.clone();
    lib.on_shot_resolved(
        move |captain: String,
              turn: i32,
              row: i32,
              col: i32,
              incoming: bool,
              hit: bool,
              sunk: bool,
              ship_name: String,
              game_over: bool| {
            let direction = if incoming { "defends" } else { "attacks" };
            let mut outcome = if hit { "hit".to_string() } else { "miss".to_string() };
            if sunk {
                outcome = format!("sunk {ship_name}");
            }
            if game_over {
                outcome += " and ended the duel";
            }
            push_log(
                &l2,
                format!(
                    "{captain} {direction} {} on turn {turn}: {outcome}",
                    coord(row, col)
                ),
            );
        },
    );
    let l3 = log.clone();
    lib.on_match_ended(
        move |captain: String, outcome: String, message: String, turn: i32| {
            push_log(&l3, format!("{captain} {outcome} on turn {turn}: {message}"));
        },
    );
    let l4 = log.clone();
    lib.on_volley_event(
        move |captain: String,
              exchange: i32,
              stage: String,
              row: i32,
              col: i32,
              reasoning: String,
              hit: bool,
              sunk: bool,
              ship_name: String,
              game_over: bool,
              message: String| {
            let mut detail = format!("{captain} {stage} #{exchange} {}", coord(row, col));
            if stage == "fire" && !reasoning.is_empty() {
                detail += &format!(" [{reasoning}]");
            }
            if stage == "reply" {
                if sunk {
                    detail += &format!(" => sunk {ship_name}");
                } else if hit {
                    detail += " => hit";
                } else {
                    detail += " => miss";
                }
                if game_over {
                    detail += " => duel over";
                }
            }
            if !message.is_empty() {
                detail += &format!(": {message}");
            }
            push_log(&l4, detail);
        },
    );
}

fn main() {
    let mut red = Torpedolib::new();
    if !red.create_context().is_ok() {
        eprintln!("FATAL: red.create_context");
        std::process::exit(1);
    }
    let mut blue = Torpedolib::new();
    if !blue.create_context().is_ok() {
        eprintln!("FATAL: blue.create_context");
        std::process::exit(1);
    }

    let log: Arc<Mutex<VecDeque<String>>> = Arc::new(Mutex::new(VecDeque::new()));
    subscribe(&red, &log);
    subscribe(&blue, &log);

    red.initialize_captain_request("Red Fleet".to_string(), 8, "hunt".to_string(), 101, TURN_DELAY_MS);
    blue.initialize_captain_request("Blue Fleet".to_string(), 8, "hunt".to_string(), 202, TURN_DELAY_MS);

    if let Some(v) = red.auto_place_fleet_request().value() {
        push_log(&log, format!("Red placed {} ships", v.shipCount));
    }
    if let Some(v) = blue.auto_place_fleet_request().value() {
        push_log(&log, format!("Blue placed {} ships", v.shipCount));
    }

    red.link_opponent_request(blue.ctx());
    blue.link_opponent_request(red.ctx());
    push_log(
        &log,
        format!("Linked contexts red={} blue={}", red.ctx(), blue.ctx()),
    );

    red.start_game_request();
    push_log(&log, "Red Fleet opens the duel".to_string());

    for iter in 0..MAX_ITERATIONS {
        let red_view = match red.get_public_board_request().value().cloned() {
            Some(v) => v,
            None => break,
        };
        let blue_view = match blue.get_public_board_request().value().cloned() {
            Some(v) => v,
            None => break,
        };

        {
            let g = log.lock().unwrap();
            draw_screen(&red_view, &blue_view, &g, iter);
        }

        if red_view.gameOver || blue_view.gameOver {
            let final_who = if red_view.hasWon {
                "Red Fleet"
            } else if blue_view.hasWon {
                "Blue Fleet"
            } else {
                "Unknown"
            };
            println!("\n>>> {final_who} wins the duel");
            thread::sleep(Duration::from_millis(END_DELAY_MS));
            break;
        }

        thread::sleep(Duration::from_millis(REFRESH_MS));
    }

    blue.shutdown();
    red.shutdown();
}
