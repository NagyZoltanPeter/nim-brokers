#!/usr/bin/env python3
"""Torpedo Duel — Python text UI example.

Build from the repository root:
  nimble buildTorpedoExamplePy

Run from the repository root:
  nimble runTorpedoExamplePy
"""

from __future__ import annotations

import argparse
import sys
import time
from collections import deque
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "nimlib" / "build"))

from torpedolib import Torpedolib, TorpedolibError


DEFAULT_THINK_DELAY = 0.8
DEFAULT_TRAVEL_DELAY = 0.35
DEFAULT_RESOLVE_DELAY = 0.45
DEFAULT_END_DELAY = 1.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Torpedo Duel text UI")
    parser.add_argument("--fast", action="store_true", help="reduce delays for quicker runs")
    parser.add_argument("--seed-red", type=int, default=101, help="seed for Red Fleet")
    parser.add_argument("--seed-blue", type=int, default=202, help="seed for Blue Fleet")
    parser.add_argument("--board-size", type=int, default=8, help="board size")
    return parser.parse_args()


def state_symbol(state_code: int, own_board: bool) -> str:
    if own_board:
        return {
            0: ".",
            1: ".",
            2: "S",
            3: "o",
            4: "x",
            5: "*",
        }.get(state_code, "?")
    return {
        0: ".",
        1: ".",
        2: "?",
        3: "o",
        4: "x",
        5: "*",
    }.get(state_code, "?")


def build_matrix(cells: list[object], board_size: int, own_board: bool) -> list[str]:
    grid = [["." for _ in range(board_size)] for _ in range(board_size)]
    for cell in cells:
        grid[cell.row][cell.col] = state_symbol(cell.stateCode, own_board)
    header = "  " + " ".join(chr(ord("A") + index) for index in range(board_size))
    lines = [header]
    for row_index, row in enumerate(grid, start=1):
        lines.append(f"{row_index:<2}" + " ".join(row))
    return lines


def format_fleet(fleet: list[object]) -> list[str]:
    lines: list[str] = []
    for ship in fleet:
        status = "sunk" if ship.sunk else f"{ship.hits}/{ship.length}"
        lines.append(f"{ship.name:<12} {status}")
    return lines


def clear_screen() -> None:
    if sys.stdout.isatty():
        sys.stdout.write("\x1b[2J\x1b[H")
        sys.stdout.flush()


def render_side_by_side(left: list[str], right: list[str], gap: int = 4) -> list[str]:
    width = max(len(line) for line in left) if left else 0
    height = max(len(left), len(right))
    output: list[str] = []
    for index in range(height):
        left_line = left[index] if index < len(left) else ""
        right_line = right[index] if index < len(right) else ""
        output.append(left_line.ljust(width) + (" " * gap) + right_line)
    return output


def coord_label(row: int, col: int) -> str:
    return f"{chr(ord('A') + col)}{row + 1}"


def draw_screen(red_view: object, blue_view: object, event_log: deque[str], banner: str, delays: tuple[float, float, float]) -> None:
    clear_screen()
    think_delay, travel_delay, resolve_delay = delays

    red_own = build_matrix(red_view.ownCells, red_view.boardSize, own_board=True)
    red_enemy = build_matrix(red_view.enemyCells, red_view.boardSize, own_board=False)
    blue_own = build_matrix(blue_view.ownCells, blue_view.boardSize, own_board=True)
    blue_enemy = build_matrix(blue_view.enemyCells, blue_view.boardSize, own_board=False)

    left_panel = ["RED FLEET", "Own Waters"] + red_own + [""] + ["Enemy Chart"] + red_enemy
    right_panel = ["BLUE FLEET", "Own Waters"] + blue_own + [""] + ["Enemy Chart"] + blue_enemy

    print("Torpedo Duel")
    print(
        f"Delay profile | think={think_delay:.2f}s  travel={travel_delay:.2f}s  resolve={resolve_delay:.2f}s"
    )
    print(banner)
    print()
    for line in render_side_by_side(left_panel, right_panel):
        print(line)
    print()

    fleet_left = ["RED STATUS"] + format_fleet(red_view.fleet)
    fleet_right = ["BLUE STATUS"] + format_fleet(blue_view.fleet)
    for line in render_side_by_side(fleet_left, fleet_right):
        print(line)

    print()
    print("Scoreboard")
    print(
        f"Red fired={red_view.totalShotsFired:<2} received={red_view.totalShotsReceived:<2}  |  "
        f"Blue fired={blue_view.totalShotsFired:<2} received={blue_view.totalShotsReceived:<2}"
    )
    print()
    print("Event Log")
    for line in event_log:
        print(f"- {line}")


def register_callbacks(lib: Torpedolib, side: str, event_log: deque[str]) -> None:
    def on_remark(owner: Torpedolib, captainName: str, phase: str, message: str, turnNumber: int) -> None:
        _ = owner
        event_log.append(f"{captainName} [{phase}] t{turnNumber}: {message}")

    def on_shot(
        owner: Torpedolib,
        captainName: str,
        turnNumber: int,
        row: int,
        col: int,
        incoming: bool,
        hit: bool,
        sunk: bool,
        shipName: str,
        gameOver: bool,
    ) -> None:
        _ = owner
        direction = "defends" if incoming else "attacks"
        outcome = "miss"
        if hit:
            outcome = "hit"
        if sunk:
            outcome = f"sunk {shipName}"
        if gameOver:
            outcome += " and ended the duel"
        event_log.append(
            f"{captainName} {direction} {coord_label(row, col)} on turn {turnNumber}: {outcome}"
        )

    def on_match(owner: Torpedolib, captainName: str, outcome: str, message: str, turnNumber: int) -> None:
        _ = owner
        event_log.append(f"{captainName} {outcome} on turn {turnNumber}: {message}")

    lib.onCaptainRemark(on_remark)
    lib.onShotResolved(on_shot)
    lib.onMatchEnded(on_match)
    event_log.append(f"{side} event listeners attached")


def run_duel(args: argparse.Namespace) -> int:
    think_delay = 0.15 if args.fast else DEFAULT_THINK_DELAY
    travel_delay = 0.08 if args.fast else DEFAULT_TRAVEL_DELAY
    resolve_delay = 0.10 if args.fast else DEFAULT_RESOLVE_DELAY
    end_delay = 0.20 if args.fast else DEFAULT_END_DELAY
    delays = (think_delay, travel_delay, resolve_delay)
    event_log: deque[str] = deque(maxlen=18)

    with Torpedolib() as red, Torpedolib() as blue:
        red.createContext()
        blue.createContext()

        register_callbacks(red, "Red Fleet", event_log)
        register_callbacks(blue, "Blue Fleet", event_log)

        red.initializeCaptainRequest("Red Fleet", args.board_size, "hunt", args.seed_red)
        blue.initializeCaptainRequest("Blue Fleet", args.board_size, "hunt", args.seed_blue)
        red.autoPlaceFleetRequest()
        blue.autoPlaceFleetRequest()

        active = red
        active_name = "Red Fleet"
        passive = blue
        passive_name = "Blue Fleet"

        banner = "Opening salvo sequence"
        while True:
            red_view = red.getPublicBoardRequest()
            blue_view = blue.getPublicBoardRequest()
            draw_screen(red_view, blue_view, event_log, banner, delays)

            event_log.append(f"{active_name} is thinking")
            banner = f"{active_name} acquiring target"
            draw_screen(red_view, blue_view, event_log, banner, delays)
            time.sleep(think_delay)

            shot = active.getNextShotRequest()
            event_log.append(
                f"{active_name} fires at {coord_label(shot.row, shot.col)} using {shot.reasoning}"
            )
            banner = f"{active_name} launches torpedo toward {coord_label(shot.row, shot.col)}"
            red_view = red.getPublicBoardRequest()
            blue_view = blue.getPublicBoardRequest()
            draw_screen(red_view, blue_view, event_log, banner, delays)
            time.sleep(travel_delay)

            outcome = passive.receiveShotRequest(shot.row, shot.col)
            active.observeShotOutcomeRequest(
                shot.row,
                shot.col,
                outcome.hit,
                outcome.sunk,
                outcome.shipName,
                outcome.gameOver,
            )

            if outcome.hit:
                if outcome.sunk:
                    result_text = f"sunk {outcome.shipName}"
                else:
                    result_text = "hit"
            else:
                result_text = "miss"

            banner = f"{active_name} -> {passive_name}: {coord_label(shot.row, shot.col)} is a {result_text}"
            red_view = red.getPublicBoardRequest()
            blue_view = blue.getPublicBoardRequest()
            draw_screen(red_view, blue_view, event_log, banner, delays)
            time.sleep(resolve_delay)

            if outcome.gameOver:
                final_red = red.getPublicBoardRequest()
                final_blue = blue.getPublicBoardRequest()
                winner = active_name
                banner = f"{winner} wins the duel"
                draw_screen(final_red, final_blue, event_log, banner, delays)
                time.sleep(end_delay)
                return 0

            active, passive = passive, active
            active_name, passive_name = passive_name, active_name


def main() -> int:
    args = parse_args()
    try:
        return run_duel(args)
    except TorpedolibError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())