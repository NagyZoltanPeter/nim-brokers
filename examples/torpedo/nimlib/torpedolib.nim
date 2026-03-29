## torpedolib — Torpedo Duel backend
## =================================
## A richer Broker FFI API example showing two isolated library contexts
## orchestrated by a foreign application.
##
## Architecture
## ------------
## Each library context spawns a dedicated processing thread.  All game
## state for one player lives inside a `Captain` ref object which is held
## by a single threadvar (`gCaptain`).  The `InitializeCaptainRequest`
## provider instantiates the Captain; the `ShutdownRequest` provider tears
## it down by niling the threadvar and dropping the peer link.
##
## Because the framework guarantees one processing thread per context, no
## locking is required on the Captain — all mutations happen on the owning
## thread's chronos event loop.
##
## Build (from repo root):
##   nimble buildTorpedoExamplePy
##
## Run (from repo root):
##   nimble runTorpedoExamplePy

{.push raises: [].}

import std/[sequtils, strutils]
import chronos, results
import brokers/[event_broker, request_broker, broker_context]

when defined(BrokerFfiApi):
  import brokers/api_library

# ---------------------------------------------------------------------------
# FFI-visible data types (shared between Nim, C, C++, Python)
# ---------------------------------------------------------------------------

type PublicCell* = object
  row*: int32
  col*: int32
  stateCode*: int32

type ShipStatus* = object
  name*: string
  length*: int32
  hits*: int32
  sunk*: bool

type ReplayEntry* = object
  turnNumber*: int32
  side*: string
  phase*: string
  message*: string

# ---------------------------------------------------------------------------
# Request brokers — each generates an exported C function + wrappers
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeCaptainRequest = object
    captainName*: string
    boardSize*: int32
    aiMode*: string
    seed*: int64
    turnDelayMs*: int32
    initialized*: bool

  proc signature*(
    captainName: string,
    boardSize: int32,
    aiMode: string,
    seed: int64,
    turnDelayMs: int32,
  ): Future[Result[InitializeCaptainRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type AutoPlaceFleetRequest = object
    captainName*: string
    success*: bool
    shipCount*: int32
    ownCells*: seq[PublicCell]
    fleet*: seq[ShipStatus]

  proc signature*(): Future[Result[AutoPlaceFleetRequest, string]] {.async.}

RequestBroker(API):
  type LinkOpponentRequest = object
    accepted*: bool
    opponentCtx*: uint32

  proc signature*(
    opponentCtx: uint32
  ): Future[Result[LinkOpponentRequest, string]] {.async.}

RequestBroker(API):
  type StartGameRequest = object
    accepted*: bool
    started*: bool

  proc signature*(): Future[Result[StartGameRequest, string]] {.async.}

RequestBroker(API):
  type GetPublicBoardRequest = object
    captainName*: string
    boardSize*: int32
    aiMode*: string
    turnDelayMs*: int32
    ownCells*: seq[PublicCell]
    enemyCells*: seq[PublicCell]
    fleet*: seq[ShipStatus]
    replayTail*: seq[ReplayEntry]
    fleetPlaced*: bool
    linked*: bool
    started*: bool
    gameOver*: bool
    hasWon*: bool
    opponentCtx*: uint32
    totalShotsFired*: int32
    totalShotsReceived*: int32

  proc signature*(): Future[Result[GetPublicBoardRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Event brokers — each generates a C callback type + on/off exports
# ---------------------------------------------------------------------------

EventBroker(API):
  type CaptainRemark = object
    captainName*: string
    phase*: string
    message*: string
    turnNumber*: int32

EventBroker(API):
  type ShotResolved = object
    captainName*: string
    turnNumber*: int32
    row*: int32
    col*: int32
    incoming*: bool
    hit*: bool
    sunk*: bool
    shipName*: string
    gameOver*: bool

EventBroker(API):
  type MatchEnded = object
    captainName*: string
    outcome*: string
    message*: string
    turnNumber*: int32

EventBroker(API):
  type BoardChanged = object
    captainName*: string
    turnNumber*: int32
    totalShotsFired*: int32
    totalShotsReceived*: int32

EventBroker(API):
  type VolleyEvent = object
    captainName*: string
    exchangeId*: int32
    stage*: string
    row*: int32
    col*: int32
    reasoning*: string
    hit*: bool
    sunk*: bool
    shipName*: string
    gameOver*: bool
    message*: string

# ---------------------------------------------------------------------------
# Internal types & constants
# ---------------------------------------------------------------------------

type Ship = object
  ## A single ship on the board.  `cells` records the (row, col) positions
  ## it occupies so we can look up occupancy by index.
  name: string
  length: int32
  hits: int32
  sunk: bool
  cells: seq[(int, int)]

const FleetTemplates = [
  ("Battleship", 4'i32),
  ("Cruiser", 3'i32),
  ("Submarine", 3'i32),
  ("Patrol Boat", 2'i32),
]

const
  EnemyUnknown = 0'i32 ## Enemy cell not yet targeted
  OwnWater = 1'i32 ## Own cell with no ship
  OwnShip = 2'i32 ## Own cell occupied by a ship (not yet hit)
  ShotMiss = 3'i32 ## Shot landed in water
  ShotHit = 4'i32 ## Shot hit a ship (not yet sunk)
  ShotSunk = 5'i32 ## Shot hit and sank a ship

const MaxReplayLogSize = 256

# ---------------------------------------------------------------------------
# Captain — the per-player state object
# ---------------------------------------------------------------------------
# All mutable game state lives here instead of in threadvars.
# `InitializeCaptainRequest` creates the instance, `ShutdownRequest` nils it.

type Captain = ref object
  ## Encapsulates the full state of one player (one library context).
  ## Created by InitializeCaptainRequest, destroyed by ShutdownRequest.

  # Identity & configuration
  ctx: BrokerContext ## The broker context this captain is bound to
  name: string ## Display name ("Red Fleet", "Blue Fleet", etc.)
  aiMode: string ## Targeting strategy: "hunt", "random", "sweep"
  boardSize: int32 ## Board dimension (NxN, typically 8)
  seed: int64 ## Original RNG seed for reproducibility
  turnDelayMs: int32 ## Artificial delay between turns for pacing

  # RNG — XorShift64 state (Marsaglia 2003, triple 13/7/17)
  rngState: uint64

  # Lifecycle flags
  fleetPlaced: bool ## True after AutoPlaceFleetRequest succeeds
  linked: bool ## True after LinkOpponentRequest succeeds
  started: bool ## True after the first shot is fired or received
  gameOver: bool ## True when all ships on either side are sunk
  hasWon: bool ## True if this captain won the duel

  # Own board — what the opponent shoots at
  ships: seq[Ship] ## The fleet
  shipIndexBoard: seq[seq[int]] ## Grid mapping (row,col) → ship index (-1 = water)
  incomingHit: seq[seq[bool]] ## Cells where incoming shots hit a ship
  incomingMiss: seq[seq[bool]] ## Cells where incoming shots missed

  # Enemy board — what this captain knows about the opponent
  enemyState: seq[seq[int32]]
    ## Per-cell knowledge (EnemyUnknown/ShotMiss/ShotHit/ShotSunk)

  # Combat counters
  shotsFired: int32 ## Total shots this captain has fired
  shotsReceived: int32 ## Total shots this captain has received

  # Pending outgoing shot — waiting for opponent's reply
  pendingShot: bool
  pendingExchangeId: int32
  pendingTurn: int32
  pendingRow: int32
  pendingCol: int32
  nextExchangeId: int32 ## Monotonically increasing exchange counter

  # Peer link — native Nim listener on the opponent's VolleyEvent
  opponentCtx: BrokerContext
  peerVolleyHandle: VolleyEventListener
  peerListenerInstalled: bool

  # Replay log — bounded ring of recent game events for the observer
  replayLog: seq[ReplayEntry]

# ---------------------------------------------------------------------------
# Thread-local state
# ---------------------------------------------------------------------------
# The framework spawns one processing thread per library context.
# `gProviderCtx` is set once by setupProviders and never changes.
# `gCaptain` is nil until InitializeCaptainRequest creates it.

var gProviderCtx {.threadvar.}: BrokerContext
var gCaptain {.threadvar.}: Captain

# ---------------------------------------------------------------------------
# Helpers — pure utilities with no state dependencies
# ---------------------------------------------------------------------------

proc toCoordLabel(row: int32, col: int32): string =
  ## Convert (row, col) to human-readable label like "A1", "B3".
  $(char(ord('A') + int(col))) & $(row + 1)

proc normalizeAiMode(aiMode: string): string =
  ## Map user-supplied AI mode string to one of the three canonical values.
  let normalized = aiMode.strip().toLowerAscii()
  case normalized
  of "", "hunt": "hunt"
  of "random": "random"
  of "sweep", "scripted": "sweep"
  else: "hunt"

# ---------------------------------------------------------------------------
# Captain — RNG
# ---------------------------------------------------------------------------

proc nextRandRaw(c: Captain): uint64 =
  ## XorShift64 PRNG — Marsaglia "Xorshift RNGs", Journal of Statistical
  ## Software 2003, triple (13, 7, 17) which is a full-period generator
  ## for 64-bit state (period 2^64 - 1).
  if c.rngState == 0'u64:
    c.rngState = 0x9E3779B97F4A7C15'u64
  var value = c.rngState
  value = value xor (value shl 13)
  value = value xor (value shr 7)
  value = value xor (value shl 17)
  c.rngState = value
  result = value

proc nextRand(c: Captain, maxExclusive: int): int =
  ## Returns a value in [0, maxExclusive).  Uses simple modulo reduction
  ## which has negligible bias for small maxExclusive relative to 2^64.
  if maxExclusive <= 0:
    return 0
  int(c.nextRandRaw() mod uint64(maxExclusive))

# ---------------------------------------------------------------------------
# Captain — board state queries
# ---------------------------------------------------------------------------

proc inBounds(c: Captain, row: int32, col: int32): bool =
  row >= 0 and col >= 0 and row < c.boardSize and col < c.boardSize

proc allShipsSunk(c: Captain): bool =
  ## Returns true when every ship in the fleet has been sunk.
  if c.ships.len == 0:
    return false
  for ship in c.ships:
    if not ship.sunk:
      return false
  true

proc ownCellState(c: Captain, row: int, col: int): int32 =
  ## Compute the public view of one of our own cells.
  let shipIndex = c.shipIndexBoard[row][col]
  if shipIndex >= 0:
    if c.ships[shipIndex].sunk:
      return ShotSunk
    if c.incomingHit[row][col]:
      return ShotHit
    return OwnShip
  if c.incomingMiss[row][col]:
    return ShotMiss
  OwnWater

proc ownCells(c: Captain): seq[PublicCell] =
  for row in 0 ..< int(c.boardSize):
    for col in 0 ..< int(c.boardSize):
      result.add(
        PublicCell(
          row: int32(row), col: int32(col), stateCode: c.ownCellState(row, col)
        )
      )

proc enemyCells(c: Captain): seq[PublicCell] =
  for row in 0 ..< int(c.boardSize):
    for col in 0 ..< int(c.boardSize):
      result.add(
        PublicCell(row: int32(row), col: int32(col), stateCode: c.enemyState[row][col])
      )

proc fleetStatus(c: Captain): seq[ShipStatus] =
  for ship in c.ships:
    result.add(
      ShipStatus(name: ship.name, length: ship.length, hits: ship.hits, sunk: ship.sunk)
    )

# ---------------------------------------------------------------------------
# Captain — replay log
# ---------------------------------------------------------------------------

proc appendReplay(c: Captain, phase: string, turnNumber: int32, message: string) =
  if c.replayLog.len >= MaxReplayLogSize:
    # Trim oldest half to amortize the copy cost
    let keepFrom = c.replayLog.len - (MaxReplayLogSize div 2)
    c.replayLog = c.replayLog[keepFrom ..< c.replayLog.len]
  c.replayLog.add(
    ReplayEntry(turnNumber: turnNumber, side: c.name, phase: phase, message: message)
  )

proc replayTail(c: Captain): seq[ReplayEntry] =
  let startIndex = max(0, c.replayLog.len - 14)
  for index in startIndex ..< c.replayLog.len:
    result.add(c.replayLog[index])

# ---------------------------------------------------------------------------
# Captain — event emission helpers
# ---------------------------------------------------------------------------
# These thin wrappers keep the emit call sites readable.  Each one appends
# to the replay log (where appropriate) and emits the broker event on the
# captain's context.

proc emitRemark(
    c: Captain, phase: string, turnNumber: int32, message: string
): Future[void] {.async.} =
  c.appendReplay(phase, turnNumber, message)
  await CaptainRemark.emit(
    c.ctx,
    CaptainRemark(
      captainName: c.name, phase: phase, message: message, turnNumber: turnNumber
    ),
  )

proc emitBoardChanged(c: Captain, turnNumber: int32): Future[void] {.async.} =
  await BoardChanged.emit(
    c.ctx,
    BoardChanged(
      captainName: c.name,
      turnNumber: turnNumber,
      totalShotsFired: c.shotsFired,
      totalShotsReceived: c.shotsReceived,
    ),
  )

proc emitMatchEnded(
    c: Captain, outcome: string, turnNumber: int32, message: string
): Future[void] {.async.} =
  c.appendReplay("end", turnNumber, message)
  await MatchEnded.emit(
    c.ctx,
    MatchEnded(
      captainName: c.name, outcome: outcome, message: message, turnNumber: turnNumber
    ),
  )

proc emitVolley(
    c: Captain,
    exchangeId: int32,
    stage: string,
    row: int32,
    col: int32,
    reasoning: string,
    hit: bool,
    sunk: bool,
    shipName: string,
    gameOver: bool,
    message: string,
): Future[void] {.async.} =
  await VolleyEvent.emit(
    c.ctx,
    VolleyEvent(
      captainName: c.name,
      exchangeId: exchangeId,
      stage: stage,
      row: row,
      col: col,
      reasoning: reasoning,
      hit: hit,
      sunk: sunk,
      shipName: shipName,
      gameOver: gameOver,
      message: message,
    ),
  )

proc applyTurnDelay(c: Captain): Future[void] {.async.} =
  if c.turnDelayMs > 0:
    await sleepAsync(milliseconds(c.turnDelayMs))

# ---------------------------------------------------------------------------
# Captain — board initialization & fleet placement
# ---------------------------------------------------------------------------

proc initBoardState(c: Captain) =
  ## Allocate empty NxN grids for own-board tracking and enemy knowledge.
  let n = int(c.boardSize)
  c.shipIndexBoard = newSeqWith(n, newSeqWith(n, -1))
  c.incomingHit = newSeqWith(n, newSeqWith(n, false))
  c.incomingMiss = newSeqWith(n, newSeqWith(n, false))
  c.enemyState = newSeqWith(n, newSeqWith(n, EnemyUnknown))

proc canPlaceShip(
    c: Captain, startRow: int, startCol: int, horizontal: bool, shipLen: int32
): bool =
  ## Check whether a ship of `shipLen` fits at the given position without
  ## overlapping existing ships or going out of bounds.
  for offset in 0 ..< int(shipLen):
    let row =
      if horizontal:
        startRow
      else:
        startRow + offset
    let col =
      if horizontal:
        startCol + offset
      else:
        startCol
    if row < 0 or col < 0 or row >= int(c.boardSize) or col >= int(c.boardSize):
      return false
    if c.shipIndexBoard[row][col] >= 0:
      return false
  true

proc placeFleet(c: Captain): Result[void, string] =
  ## Deterministically place all ships using the seeded PRNG.
  ## Tries up to 256 random placements per ship before giving up.
  c.ships = @[]
  c.initBoardState()

  for (shipName, shipLen) in FleetTemplates:
    var placed = false
    for _ in 0 ..< 256:
      let horizontal = c.nextRand(2) == 0
      let maxRow =
        if horizontal:
          int(c.boardSize)
        else:
          int(c.boardSize - shipLen + 1)
      let maxCol =
        if horizontal:
          int(c.boardSize - shipLen + 1)
        else:
          int(c.boardSize)
      let startRow = c.nextRand(maxRow)
      let startCol = c.nextRand(maxCol)
      if not c.canPlaceShip(startRow, startCol, horizontal, shipLen):
        continue

      let shipIndex = c.ships.len
      var cells: seq[(int, int)] = @[]
      for offset in 0 ..< int(shipLen):
        let row =
          if horizontal:
            startRow
          else:
            startRow + offset
        let col =
          if horizontal:
            startCol + offset
          else:
            startCol
        c.shipIndexBoard[row][col] = shipIndex
        cells.add((row, col))

      c.ships.add(
        Ship(name: shipName, length: shipLen, hits: 0, sunk: false, cells: cells)
      )
      placed = true
      break

    if not placed:
      return err("failed to place fleet for " & shipName)

  c.fleetPlaced = true
  ok()

# ---------------------------------------------------------------------------
# Captain — AI target selection
# ---------------------------------------------------------------------------

proc chooseShot(c: Captain): tuple[row: int32, col: int32, reasoning: string] =
  ## Pick the next cell to fire at.
  ##
  ## Hunt mode: if any enemy cell is ShotHit (hit but not yet sunk), look
  ## for adjacent unknown cells to finish off the ship.  If none found,
  ## fall through to random search.
  ##
  ## Sweep mode: deterministic top-left-to-bottom-right scan.
  ## Random / default: pick uniformly from all unknown cells.
  var candidates: seq[(int32, int32)] = @[]

  # Hunt phase — look for adjacents to existing hits
  if c.aiMode == "hunt":
    for row in 0 ..< int(c.boardSize):
      for col in 0 ..< int(c.boardSize):
        if c.enemyState[row][col] != ShotHit:
          continue
        for (deltaRow, deltaCol) in [
          (-1'i32, 0'i32), (1'i32, 0'i32), (0'i32, -1'i32), (0'i32, 1'i32)
        ]:
          let nextRow = int32(row) + deltaRow
          let nextCol = int32(col) + deltaCol
          if not c.inBounds(nextRow, nextCol):
            continue
          if c.enemyState[int(nextRow)][int(nextCol)] != EnemyUnknown:
            continue
          var seen = false
          for candidate in candidates:
            if candidate[0] == nextRow and candidate[1] == nextCol:
              seen = true
              break
          if not seen:
            candidates.add((nextRow, nextCol))

    if candidates.len > 0:
      let pick = candidates[c.nextRand(candidates.len)]
      return (pick[0], pick[1], "finish-contact")

  # Fallback: hunt found no adjacent targets, or mode is sweep/random.
  # Collect all unknown cells and pick one according to mode.
  candidates.setLen(0)
  for row in 0 ..< int(c.boardSize):
    for col in 0 ..< int(c.boardSize):
      if c.enemyState[row][col] == EnemyUnknown:
        candidates.add((int32(row), int32(col)))

  if candidates.len == 0:
    return (-1'i32, -1'i32, "no-target")

  if c.aiMode == "sweep":
    # Deterministic top-left-to-bottom-right scan
    return (candidates[0][0], candidates[0][1], "sweep")

  let pick = candidates[c.nextRand(candidates.len)]
  let reasoning =
    if c.aiMode == "hunt":
      "search"
    elif c.aiMode == "random":
      "random-search"
    else:
      "search"
  (pick[0], pick[1], reasoning)

# ---------------------------------------------------------------------------
# Captain — state guards
# ---------------------------------------------------------------------------

proc requireActive(c: Captain): Result[void, string] =
  ## Ensure the captain is initialized, fleet is placed, and game is live.
  if not c.fleetPlaced:
    return err("fleet not placed")
  if c.gameOver:
    return err("game already finished")
  ok()

proc requireLinked(c: Captain): Result[void, string] =
  ## Ensure the captain is in a live, linked game.
  let activeRes = c.requireActive()
  if activeRes.isErr():
    return activeRes
  if not c.linked:
    return err("opponent not linked")
  ok()

# ---------------------------------------------------------------------------
# Captain — pending shot management
# ---------------------------------------------------------------------------

proc clearPendingShot(c: Captain) =
  c.pendingShot = false
  c.pendingExchangeId = 0
  c.pendingTurn = 0
  c.pendingRow = -1
  c.pendingCol = -1

# ---------------------------------------------------------------------------
# Captain — peer link management
# ---------------------------------------------------------------------------

proc dropPeerLink(c: Captain) =
  ## Tear down the native listener on the opponent's VolleyEvent and
  ## reset all link/game-outcome state so the captain can be re-linked.
  if c.peerListenerInstalled:
    VolleyEvent.dropListener(c.opponentCtx, c.peerVolleyHandle)
  c.peerListenerInstalled = false
  c.peerVolleyHandle = VolleyEventListener(id: 0'u64)
  c.opponentCtx = BrokerContext(0'u32)
  c.linked = false
  c.started = false
  c.gameOver = false
  c.hasWon = false
  c.clearPendingShot()

# ---------------------------------------------------------------------------
# Captain — combat: plan, receive, observe
# ---------------------------------------------------------------------------

proc planNextShot(c: Captain): Result[(int32, int32, int32, int32, string), string] =
  ## Choose a target and record it as the pending outgoing shot.
  let activeRes = c.requireLinked()
  if activeRes.isErr():
    return err(activeRes.error())
  if c.pendingShot:
    return err("pending shot must be resolved before planning another")

  let shot = c.chooseShot()
  if shot.row < 0 or shot.col < 0:
    return err("no valid target remaining")

  c.pendingShot = true
  c.pendingExchangeId = c.nextExchangeId + 1
  c.nextExchangeId = c.pendingExchangeId
  c.pendingTurn = c.shotsFired + 1
  c.pendingRow = shot.row
  c.pendingCol = shot.col
  c.shotsFired = c.pendingTurn

  ok((c.pendingExchangeId, c.pendingTurn, shot.row, shot.col, shot.reasoning))

proc receiveShot(
    c: Captain, exchangeId: int32, row: int32, col: int32
): Future[Result[(bool, bool, string, bool, int32), string]] {.async.} =
  ## Process an incoming shot from the opponent.  Updates own board,
  ## emits ShotResolved + BoardChanged, and detects loss.
  let activeRes = c.requireLinked()
  if activeRes.isErr():
    return err(activeRes.error())
  if not c.inBounds(row, col):
    return err("incoming shot out of bounds")

  let rowIndex = int(row)
  let colIndex = int(col)
  if c.incomingHit[rowIndex][colIndex] or c.incomingMiss[rowIndex][colIndex]:
    return err("incoming shot already resolved at " & toCoordLabel(row, col))

  c.started = true
  c.shotsReceived.inc()

  var hit = false
  var sunk = false
  var shipName = ""

  let shipIndex = c.shipIndexBoard[rowIndex][colIndex]
  if shipIndex >= 0:
    hit = true
    c.incomingHit[rowIndex][colIndex] = true
    c.ships[shipIndex].hits.inc()
    shipName = c.ships[shipIndex].name
    if c.ships[shipIndex].hits >= c.ships[shipIndex].length:
      c.ships[shipIndex].sunk = true
      sunk = true
  else:
    c.incomingMiss[rowIndex][colIndex] = true

  let turnNumber = c.shotsReceived
  let lost = c.allShipsSunk()
  if lost:
    c.gameOver = true
    c.hasWon = false

  let message =
    if not hit:
      c.name & " reports miss at " & toCoordLabel(row, col)
    elif sunk:
      c.name & " loses " & shipName & " at " & toCoordLabel(row, col)
    else:
      c.name & " takes a hit at " & toCoordLabel(row, col)

  c.appendReplay("defense", turnNumber, message)
  await ShotResolved.emit(
    c.ctx,
    ShotResolved(
      captainName: c.name,
      turnNumber: turnNumber,
      row: row,
      col: col,
      incoming: true,
      hit: hit,
      sunk: sunk,
      shipName: shipName,
      gameOver: lost,
    ),
  )
  await c.emitBoardChanged(turnNumber)

  if lost:
    await c.emitMatchEnded("lost", turnNumber, c.name & " has been destroyed")

  return ok((hit, sunk, shipName, lost, turnNumber))

proc observeOutcome(
    c: Captain,
    exchangeId: int32,
    row: int32,
    col: int32,
    hit: bool,
    sunk: bool,
    shipName: string,
    gameOver: bool,
): Future[Result[bool, string]] {.async.} =
  ## Process the opponent's reply to our outgoing shot.  Updates enemy
  ## board knowledge, emits ShotResolved + BoardChanged, detects win.
  # Guard: allow a pending shot to resolve even if the game state has
  # transitioned (e.g. opponent's final shot set gameOver before our
  # reply arrived).  Only reject if there is genuinely no pending shot.
  if not c.pendingShot:
    let activeRes = c.requireLinked()
    if activeRes.isErr():
      return err(activeRes.error())
    return err("no pending shot to observe")
  if exchangeId != c.pendingExchangeId:
    return err("reply exchange id does not match pending shot")
  if row != c.pendingRow or col != c.pendingCol:
    return err("shot outcome does not match pending coordinate")

  c.started = true

  if hit:
    c.enemyState[int(row)][int(col)] = if sunk: ShotSunk else: ShotHit
  else:
    c.enemyState[int(row)][int(col)] = ShotMiss

  let turnNumber = c.pendingTurn
  let message =
    if not hit:
      c.name & " confirms miss at " & toCoordLabel(row, col)
    elif sunk:
      c.name & " sinks " & shipName & " at " & toCoordLabel(row, col)
    else:
      c.name & " scores a hit at " & toCoordLabel(row, col)

  c.appendReplay("attack", turnNumber, message)
  await ShotResolved.emit(
    c.ctx,
    ShotResolved(
      captainName: c.name,
      turnNumber: turnNumber,
      row: row,
      col: col,
      incoming: false,
      hit: hit,
      sunk: sunk,
      shipName: shipName,
      gameOver: gameOver,
    ),
  )

  if gameOver:
    c.gameOver = true
    c.hasWon = true
    await c.emitMatchEnded("won", turnNumber, c.name & " wins the duel")

  c.clearPendingShot()
  await c.emitBoardChanged(turnNumber)
  ok(not gameOver)

# ---------------------------------------------------------------------------
# Captain — volley exchange (the autonomous duel loop)
# ---------------------------------------------------------------------------
# Once started, the duel is self-driven: fireNextVolley emits a "fire"
# VolleyEvent on our context.  The opponent's peer listener picks it up,
# calls receiveShot, and emits a "reply" VolleyEvent back.  Our peer
# listener picks up the reply, calls observeOutcome, and — if the game
# isn't over — fires the next volley as a counter-attack.

proc fireNextVolley(c: Captain, trigger: string): Future[Result[void, string]] {.async.}

proc handlePeerVolley(c: Captain, event: VolleyEvent): Future[void] {.async.} =
  ## Called when the opponent emits a VolleyEvent on their context.
  ## We are listening on their context, so this runs on our processing thread.
  if c.gameOver:
    return

  case event.stage
  of "fire":
    # Opponent fired at us — resolve the incoming shot and reply
    c.started = true
    await c.emitRemark(
      "contact",
      max(event.exchangeId, c.shotsReceived + 1),
      c.name & " receives torpedo at " & toCoordLabel(event.row, event.col),
    )
    await c.applyTurnDelay()
    let receiveRes = await c.receiveShot(event.exchangeId, event.row, event.col)
    if receiveRes.isErr():
      await c.emitRemark("error", event.exchangeId, receiveRes.error())
      return

    let (hit, sunk, shipName, ended, _) = receiveRes.get()
    let replyMessage =
      if not hit:
        c.name & " replies miss"
      elif sunk:
        c.name & " replies sunk " & shipName
      else:
        c.name & " replies hit"

    await c.emitVolley(
      event.exchangeId, "reply", event.row, event.col, "", hit, sunk, shipName, ended,
      replyMessage,
    )
    # If we survived, counter-attack
    if not ended:
      let counterRes = await c.fireNextVolley("counter")
      if counterRes.isErr():
        await c.emitRemark("error", event.exchangeId, counterRes.error())
  of "reply":
    # Opponent replied to our shot — observe the outcome
    let observeRes = await c.observeOutcome(
      event.exchangeId, event.row, event.col, event.hit, event.sunk, event.shipName,
      event.gameOver,
    )
    if observeRes.isErr():
      await c.emitRemark("error", event.exchangeId, observeRes.error())
      return
    discard observeRes.get()
  else:
    discard

proc fireNextVolley(
    c: Captain, trigger: string
): Future[Result[void, string]] {.async.} =
  ## Plan a shot, apply pacing delay, emit remark + fire VolleyEvent.
  let planRes = c.planNextShot()
  if planRes.isErr():
    return err(planRes.error())

  let (exchangeId, turnNumber, row, col, reasoning) = planRes.get()
  c.started = true
  await c.applyTurnDelay()
  await c.emitRemark(
    "target",
    turnNumber,
    c.name & " targets " & toCoordLabel(row, col) & " [" & trigger & "]",
  )
  await c.emitVolley(
    exchangeId,
    "fire",
    row,
    col,
    reasoning,
    false,
    false,
    "",
    false,
    c.name & " launches toward " & toCoordLabel(row, col),
  )
  ok()

# ---------------------------------------------------------------------------
# Captain — snapshot builders (for request responses)
# ---------------------------------------------------------------------------

proc buildAutoPlaceResult(c: Captain): AutoPlaceFleetRequest =
  AutoPlaceFleetRequest(
    captainName: c.name,
    success: true,
    shipCount: int32(c.ships.len),
    ownCells: c.ownCells(),
    fleet: c.fleetStatus(),
  )

proc buildPublicBoardResult(c: Captain): GetPublicBoardRequest =
  GetPublicBoardRequest(
    captainName: c.name,
    boardSize: c.boardSize,
    aiMode: c.aiMode,
    turnDelayMs: c.turnDelayMs,
    ownCells: c.ownCells(),
    enemyCells: c.enemyCells(),
    fleet: c.fleetStatus(),
    replayTail: c.replayTail(),
    fleetPlaced: c.fleetPlaced,
    linked: c.linked,
    started: c.started,
    gameOver: c.gameOver,
    hasWon: c.hasWon,
    opponentCtx: uint32(c.opponentCtx),
    totalShotsFired: c.shotsFired,
    totalShotsReceived: c.shotsReceived,
  )

# ---------------------------------------------------------------------------
# setupProviders — register all request handlers for this context
# ---------------------------------------------------------------------------
# Called once per context by the framework when the processing thread starts.
# Each provider closure captures `ctx` (the broker context) and accesses
# `gCaptain` for state.  Providers that require an initialized captain
# check `gCaptain.isNil` and return an error if so.

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  gProviderCtx = ctx
  gCaptain = nil # No captain until InitializeCaptainRequest

  # --- InitializeCaptainRequest ---
  # Creates a new Captain instance, tearing down any previous one.
  let initializeProviderRes = InitializeCaptainRequest.setProvider(
    ctx,
    proc(
        captainName: string,
        boardSize: int32,
        aiMode: string,
        seed: int64,
        turnDelayMs: int32,
    ): Future[Result[InitializeCaptainRequest, string]] {.closure, async.} =
      if boardSize < 6 or boardSize > 12:
        return err("board size must be between 6 and 12")
      if turnDelayMs < 0 or turnDelayMs > 10000:
        return err("turn delay must be between 0 and 10000 milliseconds")

      # Tear down any existing captain (drops peer link, etc.)
      if not gCaptain.isNil:
        gCaptain.dropPeerLink()

      # Create a fresh captain with the requested configuration
      let c = Captain(
        ctx: ctx,
        name: if captainName.strip().len == 0: "Captain" else: captainName,
        boardSize: boardSize,
        aiMode: normalizeAiMode(aiMode),
        seed: seed,
        turnDelayMs: turnDelayMs,
        rngState: uint64(seed),
        pendingRow: -1,
        pendingCol: -1,
      )
      # Guard against zero RNG state (would stall the generator)
      if c.rngState == 0'u64:
        c.rngState = 0xCAFEBABE12345678'u64
      c.initBoardState()
      gCaptain = c

      await c.emitRemark(
        "init",
        0,
        c.name & " ready on " & $c.boardSize & "x" & $c.boardSize & " board using " &
          c.aiMode & " AI with " & $c.turnDelayMs & "ms pacing",
      )

      return ok(
        InitializeCaptainRequest(
          captainName: c.name,
          boardSize: c.boardSize,
          aiMode: c.aiMode,
          seed: c.seed,
          turnDelayMs: c.turnDelayMs,
          initialized: true,
        )
      ),
  )
  if initializeProviderRes.isErr():
    return err(
      "failed to register InitializeCaptainRequest provider: " &
        initializeProviderRes.error()
    )

  # --- ShutdownRequest ---
  # Tears down the captain: drops the peer link and nils the threadvar.
  let shutdownProviderRes = ShutdownRequest.setProvider(
    ctx,
    proc(): Future[Result[ShutdownRequest, string]] {.closure, async.} =
      if not gCaptain.isNil:
        gCaptain.dropPeerLink()
        gCaptain = nil
      return ok(ShutdownRequest(status: 0)),
  )
  if shutdownProviderRes.isErr():
    return
      err("failed to register ShutdownRequest provider: " & shutdownProviderRes.error())

  # --- AutoPlaceFleetRequest ---
  # Deterministically places the fleet using the seeded PRNG.
  let autoPlaceProviderRes = AutoPlaceFleetRequest.setProvider(
    ctx,
    proc(): Future[Result[AutoPlaceFleetRequest, string]] {.closure, async.} =
      if gCaptain.isNil:
        return err("captain not initialized")

      let c = gCaptain
      let placeRes = c.placeFleet()
      if placeRes.isErr():
        return err(placeRes.error())

      await c.emitRemark("setup", 0, c.name & " deployed " & $c.ships.len & " ships")
      await c.emitBoardChanged(0)

      return ok(c.buildAutoPlaceResult()),
  )
  if autoPlaceProviderRes.isErr():
    return err(
      "failed to register AutoPlaceFleetRequest provider: " &
        autoPlaceProviderRes.error()
    )

  # --- LinkOpponentRequest ---
  # Installs a native Nim listener on the opponent's VolleyEvent so the
  # duel can proceed autonomously without foreign-app relay.
  let linkOpponentProviderRes = LinkOpponentRequest.setProvider(
    ctx,
    proc(
        opponentCtx: uint32
    ): Future[Result[LinkOpponentRequest, string]] {.closure, async.} =
      if gCaptain.isNil:
        return err("captain not initialized")

      let c = gCaptain
      let activeRes = c.requireActive()
      if activeRes.isErr():
        return err(activeRes.error())
      if opponentCtx == 0'u32:
        return err("opponent context must be non-zero")
      if BrokerContext(opponentCtx) == c.ctx:
        return err("opponent context must differ from local context")

      # Drop any existing link before establishing a new one
      c.dropPeerLink()

      # Install a native listener on the opponent's VolleyEvent.
      # The closure captures `c` (the Captain ref) so all state access
      # goes through the object, not bare threadvars.
      let captainRef = c
      let peerVolleyHandler: VolleyEventListenerProc = proc(
          event: VolleyEvent
      ): Future[void] {.closure, async: (raises: []), gcsafe.} =
        try:
          await captainRef.handlePeerVolley(event)
        except CatchableError as e:
          try:
            await captainRef.emitRemark(
              "error",
              event.exchangeId,
              captainRef.name & " peer handler failed: " & e.msg,
            )
          except CatchableError:
            discard
      let listenRes = VolleyEvent.listen(BrokerContext(opponentCtx), peerVolleyHandler)
      if listenRes.isErr():
        return err("failed to link opponent listener: " & listenRes.error())

      c.opponentCtx = BrokerContext(opponentCtx)
      c.peerVolleyHandle = listenRes.get()
      c.peerListenerInstalled = true
      c.linked = true

      await c.emitRemark(
        "link", 0, c.name & " linked to opponent context " & $opponentCtx
      )

      return ok(LinkOpponentRequest(accepted: true, opponentCtx: opponentCtx)),
  )
  if linkOpponentProviderRes.isErr():
    return err(
      "failed to register LinkOpponentRequest provider: " &
        linkOpponentProviderRes.error()
    )

  # --- StartGameRequest ---
  # Fires the opening volley, kicking off the autonomous duel loop.
  let startGameProviderRes = StartGameRequest.setProvider(
    ctx,
    proc(): Future[Result[StartGameRequest, string]] {.closure, async.} =
      if gCaptain.isNil:
        return err("captain not initialized")

      let c = gCaptain
      let activeRes = c.requireLinked()
      if activeRes.isErr():
        return err(activeRes.error())
      if c.started:
        return err("game already started")

      await c.emitRemark("start", 0, c.name & " begins the duel")
      let fireRes = await c.fireNextVolley("opening")
      if fireRes.isErr():
        return err(fireRes.error())

      return ok(StartGameRequest(accepted: true, started: true)),
  )
  if startGameProviderRes.isErr():
    return err(
      "failed to register StartGameRequest provider: " & startGameProviderRes.error()
    )

  # --- GetPublicBoardRequest ---
  # Returns a snapshot of both boards, fleet status, replay tail, etc.
  let getPublicBoardProviderRes = GetPublicBoardRequest.setProvider(
    ctx,
    proc(): Future[Result[GetPublicBoardRequest, string]] {.closure, async.} =
      if gCaptain.isNil:
        return err("captain not initialized")

      return ok(gCaptain.buildPublicBoardResult()),
  )
  if getPublicBoardProviderRes.isErr():
    return err(
      "failed to register GetPublicBoardRequest provider: " &
        getPublicBoardProviderRes.error()
    )

  ok()

# ---------------------------------------------------------------------------
# Library registration — generates C exports, header, Python wrapper
# ---------------------------------------------------------------------------

when defined(BrokerFfiApi):
  registerBrokerLibrary:
    name:
      "torpedolib"
    initializeRequest:
      InitializeCaptainRequest
    shutdownRequest:
      ShutdownRequest

{.pop.}
