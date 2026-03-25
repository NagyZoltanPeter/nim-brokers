## torpedolib — Torpedo Duel backend
## =================================
## A richer Broker FFI API example showing two isolated library contexts
## orchestrated by a foreign application.
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

ApiType:
  type PublicCell = object
    row*: int32
    col*: int32
    stateCode*: int32

ApiType:
  type ShipStatus = object
    name*: string
    length*: int32
    hits*: int32
    sunk*: bool

ApiType:
  type ReplayEntry = object
    turnNumber*: int32
    side*: string
    phase*: string
    message*: string

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

type Ship = object
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
  EnemyUnknown = 0'i32
  OwnWater = 1'i32
  OwnShip = 2'i32
  ShotMiss = 3'i32
  ShotHit = 4'i32
  ShotSunk = 5'i32

## Thread-local captain state
## --------------------------
## Each library context gets its own processing thread, so all game state
## is kept in threadvars.  This means exactly one captain per thread; the
## framework enforces that invariant via registerBrokerLibrary which spawns
## a dedicated processing thread per context.
var gProviderCtx {.threadvar.}: BrokerContext
var gInitialized {.threadvar.}: bool
var gFleetPlaced {.threadvar.}: bool
var gLinked {.threadvar.}: bool
var gStarted {.threadvar.}: bool
var gCaptainName {.threadvar.}: string
var gAiMode {.threadvar.}: string
var gBoardSize {.threadvar.}: int32
var gSeed {.threadvar.}: int64
var gTurnDelayMs {.threadvar.}: int32
var gRngState {.threadvar.}: uint64
var gHasWon {.threadvar.}: bool
var gGameOver {.threadvar.}: bool
var gShips {.threadvar.}: seq[Ship]
var gShipIndexBoard {.threadvar.}: seq[seq[int]]
var gIncomingHit {.threadvar.}: seq[seq[bool]]
var gIncomingMiss {.threadvar.}: seq[seq[bool]]
var gEnemyState {.threadvar.}: seq[seq[int32]]
var gReplayLog {.threadvar.}: seq[ReplayEntry]
var gShotsFired {.threadvar.}: int32
var gShotsReceived {.threadvar.}: int32
var gPendingShot {.threadvar.}: bool
var gPendingExchangeId {.threadvar.}: int32
var gPendingTurn {.threadvar.}: int32
var gPendingRow {.threadvar.}: int32
var gPendingCol {.threadvar.}: int32
var gNextExchangeId {.threadvar.}: int32
var gOpponentCtx {.threadvar.}: BrokerContext
var gPeerVolleyHandle {.threadvar.}: VolleyEventListener
var gPeerListenerInstalled {.threadvar.}: bool

proc toCoordLabel(row: int32, col: int32): string =
  $(char(ord('A') + int(col))) & $(row + 1)

proc normalizeAiMode(aiMode: string): string =
  let normalized = aiMode.strip().toLowerAscii()
  case normalized
  of "", "hunt": "hunt"
  of "random": "random"
  of "sweep", "scripted": "sweep"
  else: "hunt"

proc nextRandRaw(): uint64 =
  ## XorShift64 PRNG — Marsaglia "Xorshift RNGs", Journal of Statistical
  ## Software 2003, triple (13, 7, 17) which is a full-period generator
  ## for 64-bit state (period 2^64 - 1).
  if gRngState == 0'u64:
    gRngState = 0x9E3779B97F4A7C15'u64
  var value = gRngState
  value = value xor (value shl 13)
  value = value xor (value shr 7)
  value = value xor (value shl 17)
  gRngState = value
  result = value

proc nextRand(maxExclusive: int): int =
  ## Returns a value in [0, maxExclusive).  Uses simple modulo reduction
  ## which has negligible bias for small maxExclusive relative to 2^64.
  if maxExclusive <= 0:
    return 0
  int(nextRandRaw() mod uint64(maxExclusive))

proc resetState() =
  gInitialized = false
  gFleetPlaced = false
  gLinked = false
  gStarted = false
  gCaptainName = ""
  gAiMode = "hunt"
  gBoardSize = 8
  gSeed = 0
  gTurnDelayMs = 0
  gRngState = 0
  gHasWon = false
  gGameOver = false
  gShips = @[]
  gShipIndexBoard = @[]
  gIncomingHit = @[]
  gIncomingMiss = @[]
  gEnemyState = @[]
  gReplayLog = @[]
  gShotsFired = 0
  gShotsReceived = 0
  gPendingShot = false
  gPendingExchangeId = 0
  gPendingTurn = 0
  gPendingRow = -1
  gPendingCol = -1
  gNextExchangeId = 0
  gOpponentCtx = BrokerContext(0'u32)
  gPeerVolleyHandle = VolleyEventListener(id: 0'u64)
  gPeerListenerInstalled = false

proc initBoardState(boardSize: int32) =
  gShipIndexBoard = newSeqWith(int(boardSize), newSeqWith(int(boardSize), -1))
  gIncomingHit = newSeqWith(int(boardSize), newSeqWith(int(boardSize), false))
  gIncomingMiss = newSeqWith(int(boardSize), newSeqWith(int(boardSize), false))
  gEnemyState = newSeqWith(int(boardSize), newSeqWith(int(boardSize), EnemyUnknown))

proc inBounds(row: int32, col: int32): bool =
  row >= 0 and col >= 0 and row < gBoardSize and col < gBoardSize

proc allShipsSunk(): bool =
  if gShips.len == 0:
    return false
  for ship in gShips:
    if not ship.sunk:
      return false
  true

const MaxReplayLogSize = 256

proc appendReplay(phase: string, turnNumber: int32, message: string) =
  if gReplayLog.len >= MaxReplayLogSize:
    # Trim oldest half to amortize the copy cost
    let keepFrom = gReplayLog.len - (MaxReplayLogSize div 2)
    gReplayLog = gReplayLog[keepFrom ..< gReplayLog.len]
  gReplayLog.add(
    ReplayEntry(
      turnNumber: turnNumber, side: gCaptainName, phase: phase, message: message
    )
  )

proc replayTail(): seq[ReplayEntry] =
  let startIndex = max(0, gReplayLog.len - 14)
  for index in startIndex ..< gReplayLog.len:
    result.add(gReplayLog[index])

proc emitRemark(
    phase: string, turnNumber: int32, message: string
): Future[void] {.async.} =
  appendReplay(phase, turnNumber, message)
  await CaptainRemark.emit(
    gProviderCtx,
    CaptainRemark(
      captainName: gCaptainName, phase: phase, message: message, turnNumber: turnNumber
    ),
  )

proc emitBoardChanged(turnNumber: int32): Future[void] {.async.} =
  await BoardChanged.emit(
    gProviderCtx,
    BoardChanged(
      captainName: gCaptainName,
      turnNumber: turnNumber,
      totalShotsFired: gShotsFired,
      totalShotsReceived: gShotsReceived,
    ),
  )

proc emitMatchEnded(
    outcome: string, turnNumber: int32, message: string
): Future[void] {.async.} =
  appendReplay("end", turnNumber, message)
  await MatchEnded.emit(
    gProviderCtx,
    MatchEnded(
      captainName: gCaptainName,
      outcome: outcome,
      message: message,
      turnNumber: turnNumber,
    ),
  )

proc emitVolley(
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
    gProviderCtx,
    VolleyEvent(
      captainName: gCaptainName,
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

proc applyTurnDelay(): Future[void] {.async.} =
  if gTurnDelayMs > 0:
    await sleepAsync(milliseconds(gTurnDelayMs))

proc ownCellState(row: int, col: int): int32 =
  let shipIndex = gShipIndexBoard[row][col]
  if shipIndex >= 0:
    if gShips[shipIndex].sunk:
      return ShotSunk
    if gIncomingHit[row][col]:
      return ShotHit
    return OwnShip
  if gIncomingMiss[row][col]:
    return ShotMiss
  OwnWater

proc enemyCellState(row: int, col: int): int32 =
  gEnemyState[row][col]

proc fleetStatus(): seq[ShipStatus] =
  for ship in gShips:
    result.add(
      ShipStatus(name: ship.name, length: ship.length, hits: ship.hits, sunk: ship.sunk)
    )

proc ownCells(): seq[PublicCell] =
  for row in 0 ..< int(gBoardSize):
    for col in 0 ..< int(gBoardSize):
      result.add(
        PublicCell(row: int32(row), col: int32(col), stateCode: ownCellState(row, col))
      )

proc enemyCells(): seq[PublicCell] =
  for row in 0 ..< int(gBoardSize):
    for col in 0 ..< int(gBoardSize):
      result.add(
        PublicCell(
          row: int32(row), col: int32(col), stateCode: enemyCellState(row, col)
        )
      )

proc buildAutoPlaceResult(): AutoPlaceFleetRequest =
  AutoPlaceFleetRequest(
    captainName: gCaptainName,
    success: true,
    shipCount: int32(gShips.len),
    ownCells: ownCells(),
    fleet: fleetStatus(),
  )

proc buildPublicBoardResult(): GetPublicBoardRequest =
  GetPublicBoardRequest(
    captainName: gCaptainName,
    boardSize: gBoardSize,
    aiMode: gAiMode,
    turnDelayMs: gTurnDelayMs,
    ownCells: ownCells(),
    enemyCells: enemyCells(),
    fleet: fleetStatus(),
    replayTail: replayTail(),
    fleetPlaced: gFleetPlaced,
    linked: gLinked,
    started: gStarted,
    gameOver: gGameOver,
    hasWon: gHasWon,
    opponentCtx: uint32(gOpponentCtx),
    totalShotsFired: gShotsFired,
    totalShotsReceived: gShotsReceived,
  )

proc canPlaceShip(
    startRow: int, startCol: int, horizontal: bool, shipLen: int32
): bool =
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
    if row < 0 or col < 0 or row >= int(gBoardSize) or col >= int(gBoardSize):
      return false
    if gShipIndexBoard[row][col] >= 0:
      return false
  true

proc placeFleet(): Result[void, string] =
  gShips = @[]
  initBoardState(gBoardSize)

  for (shipName, shipLen) in FleetTemplates:
    var placed = false
    for _ in 0 ..< 256:
      let horizontal = nextRand(2) == 0
      let maxRow =
        if horizontal:
          int(gBoardSize)
        else:
          int(gBoardSize - shipLen + 1)
      let maxCol =
        if horizontal:
          int(gBoardSize - shipLen + 1)
        else:
          int(gBoardSize)
      let startRow = nextRand(maxRow)
      let startCol = nextRand(maxCol)
      if not canPlaceShip(startRow, startCol, horizontal, shipLen):
        continue

      let shipIndex = gShips.len
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
        gShipIndexBoard[row][col] = shipIndex
        cells.add((row, col))

      gShips.add(
        Ship(name: shipName, length: shipLen, hits: 0, sunk: false, cells: cells)
      )
      placed = true
      break

    if not placed:
      return err("failed to place fleet for " & shipName)

  gFleetPlaced = true
  ok()

proc chooseShot(): tuple[row: int32, col: int32, reasoning: string] =
  var candidates: seq[(int32, int32)] = @[]

  if gAiMode == "hunt":
    for row in 0 ..< int(gBoardSize):
      for col in 0 ..< int(gBoardSize):
        if gEnemyState[row][col] != ShotHit:
          continue
        for (deltaRow, deltaCol) in [
          (-1'i32, 0'i32), (1'i32, 0'i32), (0'i32, -1'i32), (0'i32, 1'i32)
        ]:
          let nextRow = int32(row) + deltaRow
          let nextCol = int32(col) + deltaCol
          if not inBounds(nextRow, nextCol):
            continue
          if gEnemyState[int(nextRow)][int(nextCol)] != EnemyUnknown:
            continue
          var seen = false
          for candidate in candidates:
            if candidate[0] == nextRow and candidate[1] == nextCol:
              seen = true
              break
          if not seen:
            candidates.add((nextRow, nextCol))

    if candidates.len > 0:
      let pick = candidates[nextRand(candidates.len)]
      return (pick[0], pick[1], "finish-contact")

  # Fallback: hunt found no adjacent targets, or mode is sweep/random.
  # Collect all unknown cells and pick one according to mode.
  candidates.setLen(0)
  for row in 0 ..< int(gBoardSize):
    for col in 0 ..< int(gBoardSize):
      if gEnemyState[row][col] == EnemyUnknown:
        candidates.add((int32(row), int32(col)))

  if candidates.len == 0:
    return (-1'i32, -1'i32, "no-target")

  if gAiMode == "sweep":
    # Deterministic top-left-to-bottom-right scan
    return (candidates[0][0], candidates[0][1], "sweep")

  let pick = candidates[nextRand(candidates.len)]
  let reasoning =
    if gAiMode == "hunt": "search"
    elif gAiMode == "random": "random-search"
    else: "search"
  (pick[0], pick[1], reasoning)

proc requireInitialized(): Result[void, string] =
  if not gInitialized:
    return err("captain not initialized")
  ok()

proc requireActiveGame(): Result[void, string] =
  let initializedRes = requireInitialized()
  if initializedRes.isErr():
    return initializedRes
  if not gFleetPlaced:
    return err("fleet not placed")
  if gGameOver:
    return err("game already finished")
  ok()

proc requireLinkedGame(): Result[void, string] =
  let activeRes = requireActiveGame()
  if activeRes.isErr():
    return activeRes
  if not gLinked:
    return err("opponent not linked")
  ok()

proc clearPendingShot() =
  gPendingShot = false
  gPendingExchangeId = 0
  gPendingTurn = 0
  gPendingRow = -1
  gPendingCol = -1

proc dropPeerLink() =
  if gPeerListenerInstalled:
    VolleyEvent.dropListener(gOpponentCtx, gPeerVolleyHandle)
  gPeerListenerInstalled = false
  gPeerVolleyHandle = VolleyEventListener(id: 0'u64)
  gOpponentCtx = BrokerContext(0'u32)
  gLinked = false
  gStarted = false
  gGameOver = false
  gHasWon = false
  clearPendingShot()

proc planNextShotInternal(): Result[(int32, int32, int32, int32, string), string] =
  let activeRes = requireLinkedGame()
  if activeRes.isErr():
    return err(activeRes.error())
  if gPendingShot:
    return err("pending shot must be resolved before planning another")

  let shot = chooseShot()
  if shot.row < 0 or shot.col < 0:
    return err("no valid target remaining")

  gPendingShot = true
  gPendingExchangeId = gNextExchangeId + 1
  gNextExchangeId = gPendingExchangeId
  gPendingTurn = gShotsFired + 1
  gPendingRow = shot.row
  gPendingCol = shot.col
  gShotsFired = gPendingTurn

  ok((gPendingExchangeId, gPendingTurn, shot.row, shot.col, shot.reasoning))

proc receiveShotInternal(
    exchangeId: int32, row: int32, col: int32
): Future[Result[(bool, bool, string, bool, int32), string]] {.async.} =
  let activeRes = requireLinkedGame()
  if activeRes.isErr():
    return err(activeRes.error())
  if not inBounds(row, col):
    return err("incoming shot out of bounds")

  let rowIndex = int(row)
  let colIndex = int(col)
  if gIncomingHit[rowIndex][colIndex] or gIncomingMiss[rowIndex][colIndex]:
    return err("incoming shot already resolved at " & toCoordLabel(row, col))

  gStarted = true
  gShotsReceived.inc()

  var hit = false
  var sunk = false
  var shipName = ""

  let shipIndex = gShipIndexBoard[rowIndex][colIndex]
  if shipIndex >= 0:
    hit = true
    gIncomingHit[rowIndex][colIndex] = true
    gShips[shipIndex].hits.inc()
    shipName = gShips[shipIndex].name
    if gShips[shipIndex].hits >= gShips[shipIndex].length:
      gShips[shipIndex].sunk = true
      sunk = true
  else:
    gIncomingMiss[rowIndex][colIndex] = true

  let turnNumber = gShotsReceived
  let lost = allShipsSunk()
  if lost:
    gGameOver = true
    gHasWon = false

  let message =
    if not hit:
      gCaptainName & " reports miss at " & toCoordLabel(row, col)
    elif sunk:
      gCaptainName & " loses " & shipName & " at " & toCoordLabel(row, col)
    else:
      gCaptainName & " takes a hit at " & toCoordLabel(row, col)

  appendReplay("defense", turnNumber, message)
  await ShotResolved.emit(
    gProviderCtx,
    ShotResolved(
      captainName: gCaptainName,
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
  await emitBoardChanged(turnNumber)

  if lost:
    await emitMatchEnded("lost", turnNumber, gCaptainName & " has been destroyed")

  return ok((hit, sunk, shipName, lost, turnNumber))

proc observeOutcomeInternal(
    exchangeId: int32,
    row: int32,
    col: int32,
    hit: bool,
    sunk: bool,
    shipName: string,
    gameOver: bool,
): Future[Result[bool, string]] {.async.} =
  # Guard: allow a pending shot to resolve even if the game state has
  # transitioned (e.g. opponent's final shot set gGameOver before our
  # reply arrived).  Only reject if there is genuinely no pending shot.
  if not gPendingShot:
    let activeRes = requireLinkedGame()
    if activeRes.isErr():
      return err(activeRes.error())
    return err("no pending shot to observe")
  if exchangeId != gPendingExchangeId:
    return err("reply exchange id does not match pending shot")
  if row != gPendingRow or col != gPendingCol:
    return err("shot outcome does not match pending coordinate")

  gStarted = true

  if hit:
    gEnemyState[int(row)][int(col)] = if sunk: ShotSunk else: ShotHit
  else:
    gEnemyState[int(row)][int(col)] = ShotMiss

  let turnNumber = gPendingTurn
  let message =
    if not hit:
      gCaptainName & " confirms miss at " & toCoordLabel(row, col)
    elif sunk:
      gCaptainName & " sinks " & shipName & " at " & toCoordLabel(row, col)
    else:
      gCaptainName & " scores a hit at " & toCoordLabel(row, col)

  appendReplay("attack", turnNumber, message)
  await ShotResolved.emit(
    gProviderCtx,
    ShotResolved(
      captainName: gCaptainName,
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
    gGameOver = true
    gHasWon = true
    await emitMatchEnded("won", turnNumber, gCaptainName & " wins the duel")

  clearPendingShot()
  await emitBoardChanged(turnNumber)
  ok(not gameOver)

proc fireNextVolley(trigger: string): Future[Result[void, string]] {.async.}

proc handlePeerVolley(event: VolleyEvent): Future[void] {.async.} =
  if gGameOver:
    return

  case event.stage
  of "fire":
    gStarted = true
    await emitRemark(
      "contact",
      max(event.exchangeId, gShotsReceived + 1),
      gCaptainName & " receives torpedo at " & toCoordLabel(event.row, event.col),
    )
    await applyTurnDelay()
    let receiveRes = await receiveShotInternal(event.exchangeId, event.row, event.col)
    if receiveRes.isErr():
      await emitRemark("error", event.exchangeId, receiveRes.error())
      return

    let (hit, sunk, shipName, ended, _) = receiveRes.get()
    let replyMessage =
      if not hit:
        gCaptainName & " replies miss"
      elif sunk:
        gCaptainName & " replies sunk " & shipName
      else:
        gCaptainName & " replies hit"

    await emitVolley(
      event.exchangeId, "reply", event.row, event.col, "", hit, sunk, shipName, ended,
      replyMessage,
    )
    if not ended:
      let counterRes = await fireNextVolley("counter")
      if counterRes.isErr():
        await emitRemark("error", event.exchangeId, counterRes.error())
  of "reply":
    let observeRes = await observeOutcomeInternal(
      event.exchangeId, event.row, event.col, event.hit, event.sunk, event.shipName,
      event.gameOver,
    )
    if observeRes.isErr():
      await emitRemark("error", event.exchangeId, observeRes.error())
      return
    discard observeRes.get()
  else:
    discard

proc fireNextVolley(trigger: string): Future[Result[void, string]] {.async.} =
  let planRes = planNextShotInternal()
  if planRes.isErr():
    return err(planRes.error())

  let (exchangeId, turnNumber, row, col, reasoning) = planRes.get()
  gStarted = true
  await applyTurnDelay()
  await emitRemark(
    "target",
    turnNumber,
    gCaptainName & " targets " & toCoordLabel(row, col) & " [" & trigger & "]",
  )
  await emitVolley(
    exchangeId,
    "fire",
    row,
    col,
    reasoning,
    false,
    false,
    "",
    false,
    gCaptainName & " launches toward " & toCoordLabel(row, col),
  )
  ok()

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  gProviderCtx = ctx
  resetState()

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

      dropPeerLink()
      resetState()
      gProviderCtx = ctx
      gCaptainName = if captainName.strip().len == 0: "Captain" else: captainName
      gBoardSize = boardSize
      gAiMode = normalizeAiMode(aiMode)
      gSeed = seed
      gTurnDelayMs = turnDelayMs
      gRngState = uint64(seed)
      if gRngState == 0'u64:
        gRngState = 0xCAFEBABE12345678'u64
      initBoardState(gBoardSize)
      gInitialized = true

      await emitRemark(
        "init",
        0,
        gCaptainName & " ready on " & $gBoardSize & "x" & $gBoardSize & " board using " &
          gAiMode & " AI with " & $gTurnDelayMs & "ms pacing",
      )

      return ok(
        InitializeCaptainRequest(
          captainName: gCaptainName,
          boardSize: gBoardSize,
          aiMode: gAiMode,
          seed: gSeed,
          turnDelayMs: gTurnDelayMs,
          initialized: true,
        )
      ),
  )
  if initializeProviderRes.isErr():
    return err(
      "failed to register InitializeCaptainRequest provider: " &
        initializeProviderRes.error()
    )

  let shutdownProviderRes = ShutdownRequest.setProvider(
    ctx,
    proc(): Future[Result[ShutdownRequest, string]] {.closure, async.} =
      dropPeerLink()
      resetState()
      gProviderCtx = ctx
      return ok(ShutdownRequest(status: 0)),
  )
  if shutdownProviderRes.isErr():
    return
      err("failed to register ShutdownRequest provider: " & shutdownProviderRes.error())

  let autoPlaceProviderRes = AutoPlaceFleetRequest.setProvider(
    ctx,
    proc(): Future[Result[AutoPlaceFleetRequest, string]] {.closure, async.} =
      let activeRes = requireInitialized()
      if activeRes.isErr():
        return err(activeRes.error())

      let placeRes = placeFleet()
      if placeRes.isErr():
        return err(placeRes.error())

      await emitRemark("setup", 0, gCaptainName & " deployed " & $gShips.len & " ships")
      await emitBoardChanged(0)

      return ok(buildAutoPlaceResult()),
  )
  if autoPlaceProviderRes.isErr():
    return err(
      "failed to register AutoPlaceFleetRequest provider: " &
        autoPlaceProviderRes.error()
    )

  let linkOpponentProviderRes = LinkOpponentRequest.setProvider(
    ctx,
    proc(
        opponentCtx: uint32
    ): Future[Result[LinkOpponentRequest, string]] {.closure, async.} =
      let activeRes = requireActiveGame()
      if activeRes.isErr():
        return err(activeRes.error())
      if opponentCtx == 0'u32:
        return err("opponent context must be non-zero")
      if BrokerContext(opponentCtx) == gProviderCtx:
        return err("opponent context must differ from local context")

      dropPeerLink()
      let peerVolleyHandler: VolleyEventListenerProc = proc(
          event: VolleyEvent
      ): Future[void] {.closure, async: (raises: []), gcsafe.} =
        try:
          await handlePeerVolley(event)
        except CatchableError as e:
          try:
            await emitRemark(
              "error", event.exchangeId,
              gCaptainName & " peer handler failed: " & e.msg,
            )
          except CatchableError:
            discard
      let listenRes = VolleyEvent.listen(BrokerContext(opponentCtx), peerVolleyHandler)
      if listenRes.isErr():
        return err("failed to link opponent listener: " & listenRes.error())

      gOpponentCtx = BrokerContext(opponentCtx)
      gPeerVolleyHandle = listenRes.get()
      gPeerListenerInstalled = true
      gLinked = true

      await emitRemark(
        "link", 0, gCaptainName & " linked to opponent context " & $opponentCtx
      )

      return ok(LinkOpponentRequest(accepted: true, opponentCtx: opponentCtx)),
  )
  if linkOpponentProviderRes.isErr():
    return err(
      "failed to register LinkOpponentRequest provider: " &
        linkOpponentProviderRes.error()
    )

  let startGameProviderRes = StartGameRequest.setProvider(
    ctx,
    proc(): Future[Result[StartGameRequest, string]] {.closure, async.} =
      let activeRes = requireLinkedGame()
      if activeRes.isErr():
        return err(activeRes.error())
      if gStarted:
        return err("game already started")

      await emitRemark("start", 0, gCaptainName & " begins the duel")
      let fireRes = await fireNextVolley("opening")
      if fireRes.isErr():
        return err(fireRes.error())

      return ok(StartGameRequest(accepted: true, started: true)),
  )
  if startGameProviderRes.isErr():
    return err(
      "failed to register StartGameRequest provider: " & startGameProviderRes.error()
    )

  let getPublicBoardProviderRes = GetPublicBoardRequest.setProvider(
    ctx,
    proc(): Future[Result[GetPublicBoardRequest, string]] {.closure, async.} =
      let initializedRes = requireInitialized()
      if initializedRes.isErr():
        return err(initializedRes.error())

      return ok(buildPublicBoardResult()),
  )
  if getPublicBoardProviderRes.isErr():
    return err(
      "failed to register GetPublicBoardRequest provider: " &
        getPublicBoardProviderRes.error()
    )

  ok()

when defined(BrokerFfiApi):
  registerBrokerLibrary:
    name:
      "torpedolib"
    initializeRequest:
      InitializeCaptainRequest
    shutdownRequest:
      ShutdownRequest

{.pop.}
