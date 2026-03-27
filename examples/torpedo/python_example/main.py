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

_IS_WINDOWS = sys.platform == "win32"

if _IS_WINDOWS:
    import msvcrt
else:
    import os
    import select
    import termios
    import tty


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "nimlib" / "build"))

from torpedolib import Torpedolib, TorpedolibError


DEFAULT_REFRESH_DELAY = 0.18
DEFAULT_TURN_DELAY_MS = 650
DEFAULT_END_DELAY = 1.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Torpedo Duel text UI")
    parser.add_argument("--fast", action="store_true", help="reduce delays for quicker runs")
    parser.add_argument("--seed-red", type=int, default=101, help="seed for Red Fleet")
    parser.add_argument("--seed-blue", type=int, default=202, help="seed for Blue Fleet")
    parser.add_argument("--board-size", type=int, default=8, help="board size")
    parser.add_argument(
        "--starter",
        choices=("red", "blue"),
        default="red",
        help="which fleet opens the duel",
    )
    return parser.parse_args()


_OWN_SYMBOLS = {0: ".", 1: ".", 2: "S", 3: "o", 4: "x", 5: "*"}
_ENEMY_SYMBOLS = {0: ".", 1: ".", 3: "o", 4: "x", 5: "*"}


def state_symbol(state_code: int, own_board: bool) -> str:
    if own_board:
        return _OWN_SYMBOLS.get(state_code, "?")
    # stateCode 2 (OwnShip) should never appear in enemy cells — flag it
    if state_code == 2:
        return "!"
    return _ENEMY_SYMBOLS.get(state_code, "?")


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


class RawTerminal:
    """Context manager that puts stdin into raw mode for non-blocking key reads.

    Supports macOS, Linux (via termios), and Windows (via msvcrt).
    """

    def __init__(self) -> None:
        self._fd: int | None = None
        self._old_settings: list[object] | None = None

    def __enter__(self) -> RawTerminal:
        if _IS_WINDOWS:
            # msvcrt needs no setup — kbhit/getch work immediately
            self._fd = 0  # sentinel: active
        elif sys.stdin.isatty():
            self._fd = sys.stdin.fileno()
            self._old_settings = termios.tcgetattr(self._fd)
            tty.setcbreak(self._fd)
        return self

    def __exit__(self, *_: object) -> None:
        if not _IS_WINDOWS and self._fd is not None and self._old_settings is not None:
            termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old_settings)

    def key_pressed(self) -> str | None:
        """Return a single character if one is available, else None."""
        if self._fd is None:
            return None
        if _IS_WINDOWS:
            if msvcrt.kbhit():
                return msvcrt.getwch()
            return None
        readable, _, _ = select.select([sys.stdin], [], [], 0)
        if readable:
            return os.read(self._fd, 1).decode("utf-8", errors="ignore")
        return None


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


def format_status(view: object) -> list[str]:
    return [
        f"AI         {view.aiMode}",
        f"Delay      {view.turnDelayMs} ms",
        f"Placed     {'yes' if view.fleetPlaced else 'no'}",
        f"Linked     {'yes' if view.linked else 'no'}",
        f"Started    {'yes' if view.started else 'no'}",
        f"Opponent   {view.opponentCtx}",
        f"Outcome    {'won' if view.hasWon else 'lost' if view.gameOver else 'active'}",
    ]


def draw_screen(red_view: object, blue_view: object, event_log: deque[str], banner: str, refresh_delay: float) -> None:
    clear_screen()

    red_own = build_matrix(red_view.ownCells, red_view.boardSize, own_board=True)
    red_enemy = build_matrix(red_view.enemyCells, red_view.boardSize, own_board=False)
    blue_own = build_matrix(blue_view.ownCells, blue_view.boardSize, own_board=True)
    blue_enemy = build_matrix(blue_view.enemyCells, blue_view.boardSize, own_board=False)

    left_panel = ["RED FLEET", "Own Waters"] + red_own + [""] + ["Enemy Chart"] + red_enemy
    right_panel = ["BLUE FLEET", "Own Waters"] + blue_own + [""] + ["Enemy Chart"] + blue_enemy

    print("Torpedo Duel")
    print(f"Observer refresh={refresh_delay:.2f}s | backend duel is self-driven")
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
    meta_left = ["RED META"] + format_status(red_view)
    meta_right = ["BLUE META"] + format_status(blue_view)
    for line in render_side_by_side(meta_left, meta_right):
        print(line)

    print()
    print("Scoreboard")
    print(
        f"Red fired={red_view.totalShotsFired:<2} received={red_view.totalShotsReceived:<2}  |  "
        f"Blue fired={blue_view.totalShotsFired:<2} received={blue_view.totalShotsReceived:<2}"
    )
    print()
    print("Event Log")
    for line in list(event_log):
        print(f"- {line}")
    print()
    print("Press q to quit")


def register_callbacks(lib: Torpedolib, side: str, event_log: deque[str]) -> list[tuple[str, int]]:
    """Subscribe to all event types.  Returns [(event_name, handle), ...] for cleanup."""
    handles: list[tuple[str, int]] = []

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

    def on_volley(
        owner: Torpedolib,
        captainName: str,
        exchangeId: int,
        stage: str,
        row: int,
        col: int,
        reasoning: str,
        hit: bool,
        sunk: bool,
        shipName: str,
        gameOver: bool,
        message: str,
    ) -> None:
        _ = owner
        detail = f"{captainName} {stage} #{exchangeId} {coord_label(row, col)}"
        if stage == "fire" and reasoning:
            detail += f" [{reasoning}]"
        if stage == "reply":
            if sunk:
                detail += f" => sunk {shipName}"
            elif hit:
                detail += " => hit"
            else:
                detail += " => miss"
            if gameOver:
                detail += " => duel over"
        if message:
            detail += f": {message}"
        event_log.append(detail)

    handles.append(("CaptainRemark", lib.onCaptainRemark(on_remark)))
    handles.append(("ShotResolved", lib.onShotResolved(on_shot)))
    handles.append(("MatchEnded", lib.onMatchEnded(on_match)))
    handles.append(("VolleyEvent", lib.onVolleyEvent(on_volley)))
    event_log.append(f"{side} event listeners attached")
    return handles


def unregister_callbacks(lib: Torpedolib, handles: list[tuple[str, int]]) -> None:
    """Unsubscribe all event listeners before shutdown.

    This must be called while the library context is still alive so the
    Nim delivery thread stops invoking the ctypes function pointers before
    Python releases the CFUNCTYPE objects.
    """
    for event_name, handle in handles:
        if event_name == "CaptainRemark":
            lib.offCaptainRemark(handle)
        elif event_name == "ShotResolved":
            lib.offShotResolved(handle)
        elif event_name == "MatchEnded":
            lib.offMatchEnded(handle)
        elif event_name == "VolleyEvent":
            lib.offVolleyEvent(handle)


def run_duel(args: argparse.Namespace) -> int:
    refresh_delay = 0.05 if args.fast else DEFAULT_REFRESH_DELAY
    turn_delay_ms = 120 if args.fast else DEFAULT_TURN_DELAY_MS
    end_delay = 0.20 if args.fast else DEFAULT_END_DELAY
    event_log: deque[str] = deque(maxlen=24)

    with Torpedolib() as red, Torpedolib() as blue, RawTerminal() as term:
        red.createContext()
        blue.createContext()

        red_handles = register_callbacks(red, "Red Fleet", event_log)
        blue_handles = register_callbacks(blue, "Blue Fleet", event_log)

        red.initializeCaptainRequest("Red Fleet", args.board_size, "hunt", args.seed_red, turn_delay_ms)
        blue.initializeCaptainRequest("Blue Fleet", args.board_size, "hunt", args.seed_blue, turn_delay_ms)

        red_setup = red.autoPlaceFleetRequest()
        blue_setup = blue.autoPlaceFleetRequest()
        event_log.append(f"Red placed {red_setup.shipCount} ships")
        event_log.append(f"Blue placed {blue_setup.shipCount} ships")

        red.linkOpponentRequest(blue.ctx)
        blue.linkOpponentRequest(red.ctx)
        event_log.append(f"Linked contexts red={red.ctx} blue={blue.ctx}")

        starter = red if args.starter == "red" else blue
        starter_name = "Red Fleet" if args.starter == "red" else "Blue Fleet"
        starter.startGameRequest()

        banner = f"{starter_name} opens the duel"
        try:
            while True:
                # Check for quit key
                key = term.key_pressed()
                if key in ("q", "Q"):
                    return 0

                red_view = red.getPublicBoardRequest()
                blue_view = blue.getPublicBoardRequest()
                if event_log:
                    banner = event_log[-1]
                draw_screen(red_view, blue_view, event_log, banner, refresh_delay)

                if red_view.gameOver or blue_view.gameOver:
                    final_red = red.getPublicBoardRequest()
                    final_blue = blue.getPublicBoardRequest()
                    winner = "Red Fleet" if final_red.hasWon else "Blue Fleet" if final_blue.hasWon else "Unknown"
                    banner = f"{winner} wins the duel"
                    draw_screen(final_red, final_blue, event_log, banner, refresh_delay)
                    time.sleep(end_delay)
                    return 0

                time.sleep(refresh_delay)
        finally:
            # Unsubscribe all event listeners BEFORE the context manager
            # calls shutdown().  This ensures the Nim delivery thread stops
            # invoking ctypes function pointers before Python releases the
            # CFUNCTYPE objects — preventing a use-after-free crash.
            unregister_callbacks(red, red_handles)
            unregister_callbacks(blue, blue_handles)


def main() -> int:
    args = parse_args()
    try:
        return run_duel(args)
    except TorpedolibError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())