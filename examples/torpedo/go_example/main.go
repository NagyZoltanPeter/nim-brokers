// Torpedo Duel — Go text UI example.
//
// Functional parity with python_example/main.py: bootstraps two captain
// contexts, links them bidirectionally, starts the duel, and polls
// get_public_board_request in a render loop until gameOver. Renders
// both own/enemy boards, fleet status, meta panels, and a tail of the
// event log driven by the broker callbacks.
//
//     go run .                # native FFI build (nimlib/build/)
//     go run -tags cbor .     # CBOR FFI build   (nimlib/build_cbor/)

package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"torpedolib"
)

const (
	maxLogEntries     = 16
	defaultRefreshMs  = 180
	defaultTurnDelay  = 650
	defaultEndDelayMs = 1000
	maxIterations     = 600 // hard ceiling so runs always terminate
)

func main() {
	fast := flag.Bool("fast", false, "reduce delays for quicker runs")
	seedRed := flag.Int64("seed-red", 101, "seed for Red Fleet")
	seedBlue := flag.Int64("seed-blue", 202, "seed for Blue Fleet")
	boardSize := flag.Int("board-size", 8, "board size")
	starter := flag.String("starter", "red", "which fleet opens the duel (red|blue)")
	flag.Parse()

	refreshMs := defaultRefreshMs
	turnDelay := defaultTurnDelay
	endDelayMs := defaultEndDelayMs
	if *fast {
		refreshMs = 50
		turnDelay = 120
		endDelayMs = 200
	}

	red := torpedolib.New()
	if err := red.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "FATAL: red.CreateContext:", err)
		os.Exit(1)
	}
	blue := torpedolib.New()
	if err := blue.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "FATAL: blue.CreateContext:", err)
		os.Exit(1)
	}

	var (
		mu  sync.Mutex
		log []string
	)
	push := func(s string) {
		mu.Lock()
		log = append(log, s)
		if len(log) > maxLogEntries {
			log = log[len(log)-maxLogEntries:]
		}
		mu.Unlock()
	}

	for _, lib := range []*torpedolib.Torpedolib{red, blue} {
		lib.OnCaptainRemark(func(captainName string, phase string, message string, turnNumber int32) {
			push(fmt.Sprintf("%s [%s] t%d: %s", captainName, phase, turnNumber, message))
		})
		lib.OnShotResolved(func(captainName string, turnNumber int32, row int32, col int32,
			incoming bool, hit bool, sunk bool, shipName string, gameOver bool) {
			direction := "attacks"
			if incoming {
				direction = "defends"
			}
			outcome := "miss"
			if hit {
				outcome = "hit"
			}
			if sunk {
				outcome = "sunk " + shipName
			}
			if gameOver {
				outcome += " and ended the duel"
			}
			push(fmt.Sprintf("%s %s %s on turn %d: %s",
				captainName, direction, coord(row, col), turnNumber, outcome))
		})
		lib.OnMatchEnded(func(captainName string, outcome string, message string, turnNumber int32) {
			push(fmt.Sprintf("%s %s on turn %d: %s", captainName, outcome, turnNumber, message))
		})
		lib.OnVolleyEvent(func(captainName string, exchangeId int32, stage string, row int32, col int32,
			reasoning string, hit bool, sunk bool, shipName string, gameOver bool, message string) {
			detail := fmt.Sprintf("%s %s #%d %s", captainName, stage, exchangeId, coord(row, col))
			if stage == "fire" && reasoning != "" {
				detail += " [" + reasoning + "]"
			}
			if stage == "reply" {
				switch {
				case sunk:
					detail += " => sunk " + shipName
				case hit:
					detail += " => hit"
				default:
					detail += " => miss"
				}
				if gameOver {
					detail += " => duel over"
				}
			}
			if message != "" {
				detail += ": " + message
			}
			push(detail)
		})
	}

	if _, err := red.InitializeCaptainRequest("Red Fleet", int32(*boardSize), "hunt", *seedRed, int32(turnDelay)); err != nil {
		fmt.Fprintln(os.Stderr, "red InitializeCaptainRequest:", err)
		os.Exit(1)
	}
	if _, err := blue.InitializeCaptainRequest("Blue Fleet", int32(*boardSize), "hunt", *seedBlue, int32(turnDelay)); err != nil {
		fmt.Fprintln(os.Stderr, "blue InitializeCaptainRequest:", err)
		os.Exit(1)
	}

	if r, err := red.AutoPlaceFleetRequest(); err == nil {
		push(fmt.Sprintf("Red placed %d ships", r.ShipCount))
	}
	if r, err := blue.AutoPlaceFleetRequest(); err == nil {
		push(fmt.Sprintf("Blue placed %d ships", r.ShipCount))
	}

	red.LinkOpponentRequest(blue.Ctx())
	blue.LinkOpponentRequest(red.Ctx())
	push(fmt.Sprintf("Linked contexts red=%d blue=%d", red.Ctx(), blue.Ctx()))

	starterLib := red
	starterName := "Red Fleet"
	if *starter == "blue" {
		starterLib = blue
		starterName = "Blue Fleet"
	}
	starterLib.StartGameRequest()
	push(starterName + " opens the duel")

	// --- Render loop ----------------------------------------------------
	for iter := 0; iter < maxIterations; iter++ {
		redView, err := red.GetPublicBoardRequest()
		if err != nil {
			fmt.Fprintln(os.Stderr, "red GetPublicBoardRequest:", err)
			break
		}
		blueView, err := blue.GetPublicBoardRequest()
		if err != nil {
			fmt.Fprintln(os.Stderr, "blue GetPublicBoardRequest:", err)
			break
		}

		mu.Lock()
		drawScreen(redView, blueView, log, iter)
		mu.Unlock()

		if redView.GameOver || blueView.GameOver {
			final := "Unknown"
			switch {
			case redView.HasWon:
				final = "Red Fleet"
			case blueView.HasWon:
				final = "Blue Fleet"
			}
			fmt.Printf("\n>>> %s wins the duel\n", final)
			time.Sleep(time.Duration(endDelayMs) * time.Millisecond)
			break
		}

		time.Sleep(time.Duration(refreshMs) * time.Millisecond)
	}

	blue.Close()
	red.Close()
}

func coord(row, col int32) string {
	return fmt.Sprintf("%c%d", 'A'+col, row+1)
}

var ownSyms = map[int32]string{0: ".", 1: ".", 2: "S", 3: "o", 4: "x", 5: "*"}
var enemySyms = map[int32]string{0: ".", 1: ".", 3: "o", 4: "x", 5: "*"}

func cellSymbol(stateCode int32, ownBoard bool) string {
	if ownBoard {
		if s, ok := ownSyms[stateCode]; ok {
			return s
		}
		return "?"
	}
	if stateCode == 2 {
		return "!"
	}
	if s, ok := enemySyms[stateCode]; ok {
		return s
	}
	return "?"
}

func buildMatrix(cells []torpedolib.PublicCell, size int32, ownBoard bool) []string {
	grid := make([][]string, size)
	for r := range grid {
		grid[r] = make([]string, size)
		for c := range grid[r] {
			grid[r][c] = "."
		}
	}
	for _, c := range cells {
		if c.Row < size && c.Col < size {
			grid[c.Row][c.Col] = cellSymbol(c.StateCode, ownBoard)
		}
	}
	hdr := "  "
	for c := int32(0); c < size; c++ {
		hdr += string(rune('A'+c)) + " "
	}
	out := []string{strings.TrimRight(hdr, " ")}
	for r := int32(0); r < size; r++ {
		out = append(out, fmt.Sprintf("%-2d%s", r+1, strings.Join(grid[r], " ")))
	}
	return out
}

func formatFleet(fleet []torpedolib.ShipStatus) []string {
	out := make([]string, 0, len(fleet))
	for _, s := range fleet {
		status := fmt.Sprintf("%d/%d", s.Hits, s.Length)
		if s.Sunk {
			status = "sunk"
		}
		out = append(out, fmt.Sprintf("%-12s %s", s.Name, status))
	}
	return out
}

func formatStatus(v torpedolib.GetPublicBoardRequest) []string {
	yn := func(b bool) string {
		if b {
			return "yes"
		}
		return "no"
	}
	outcome := "active"
	switch {
	case v.HasWon:
		outcome = "won"
	case v.GameOver:
		outcome = "lost"
	}
	return []string{
		fmt.Sprintf("AI         %s", v.AiMode),
		fmt.Sprintf("Delay      %d ms", v.TurnDelayMs),
		fmt.Sprintf("Placed     %s", yn(v.FleetPlaced)),
		fmt.Sprintf("Linked     %s", yn(v.Linked)),
		fmt.Sprintf("Started    %s", yn(v.Started)),
		fmt.Sprintf("Opponent   %d", v.OpponentCtx),
		fmt.Sprintf("Outcome    %s", outcome),
	}
}

func sideBySide(left, right []string, gap int) []string {
	width := 0
	for _, l := range left {
		if len(l) > width {
			width = len(l)
		}
	}
	height := len(left)
	if len(right) > height {
		height = len(right)
	}
	out := make([]string, height)
	for i := 0; i < height; i++ {
		l := ""
		if i < len(left) {
			l = left[i]
		}
		r := ""
		if i < len(right) {
			r = right[i]
		}
		out[i] = l + strings.Repeat(" ", width-len(l)+gap) + r
	}
	return out
}

func drawScreen(red, blue torpedolib.GetPublicBoardRequest, log []string, iter int) {
	fmt.Print("\x1b[2J\x1b[H") // clear + home (no-op if not a TTY)
	fmt.Println("Torpedo Duel — Go")
	fmt.Printf("Tick=%d  backend duel is self-driven\n\n", iter)

	redOwn := buildMatrix(red.OwnCells, red.BoardSize, true)
	redEnemy := buildMatrix(red.EnemyCells, red.BoardSize, false)
	blueOwn := buildMatrix(blue.OwnCells, blue.BoardSize, true)
	blueEnemy := buildMatrix(blue.EnemyCells, blue.BoardSize, false)

	left := append([]string{"RED FLEET", "Own Waters"}, redOwn...)
	left = append(left, "", "Enemy Chart")
	left = append(left, redEnemy...)
	right := append([]string{"BLUE FLEET", "Own Waters"}, blueOwn...)
	right = append(right, "", "Enemy Chart")
	right = append(right, blueEnemy...)
	for _, line := range sideBySide(left, right, 4) {
		fmt.Println(line)
	}
	fmt.Println()

	fLeft := append([]string{"RED STATUS"}, formatFleet(red.Fleet)...)
	fRight := append([]string{"BLUE STATUS"}, formatFleet(blue.Fleet)...)
	for _, line := range sideBySide(fLeft, fRight, 4) {
		fmt.Println(line)
	}
	fmt.Println()

	mLeft := append([]string{"RED META"}, formatStatus(red)...)
	mRight := append([]string{"BLUE META"}, formatStatus(blue)...)
	for _, line := range sideBySide(mLeft, mRight, 4) {
		fmt.Println(line)
	}
	fmt.Println()

	fmt.Println("Scoreboard")
	fmt.Printf("Red fired=%-2d received=%-2d  |  Blue fired=%-2d received=%-2d\n\n",
		red.TotalShotsFired, red.TotalShotsReceived,
		blue.TotalShotsFired, blue.TotalShotsReceived)

	fmt.Println("Event Log")
	for _, line := range log {
		fmt.Printf("- %s\n", line)
	}
}
