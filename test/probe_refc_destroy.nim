## Measures how a conservative stack scan affects observing a released
## instance, and fixes the tolerance used by `test/test_broker_lifecycle.nim`.
##
## That test asserts a *semantic*: an instance held alive only by a closure
## registered in a global table becomes collectable once the registration is
## removed. Half of it — that the registration was dropped — is exactly
## observable everywhere. The other half — that the instance was freed — is
## observed through `=destroy` firing after `GC_fullCollect()`, and `--mm:refc`
## does not guarantee that: refc sweeps conservatively, so any pointer-shaped
## value still sitting in the C stack or in a callee-saved register roots the
## object, the destructor does not run, and the test reports a leak that is not
## there.
##
## The question that decides how to test it is not *whether* that happens but
## whether it **scales**. A conservative false root can only pin an instance
## whose address is still lying in a stale stack slot; a tight create/register/
## deregister loop overwrites the previous iteration's frame. So a false root
## should stay bounded by a small constant however large the loop, while a
## genuine retention scales with it. This probe measures the survivor count at
## several loop lengths so the two can be told apart by their slope.
##
## Measured on Linux amd64 (Nim 2.2.4, 2.2.10 and 2.2.12, identically):
##
##   --mm:refc -d:release  -> exactly 1 survivor, flat from N=1 to N=500
##   --mm:refc (debug)     -> 0 at every N
##   --mm:orc, either mode -> 0 at every N
##
## The single refc survivor is also transient: it is reclaimed as soon as later
## work overwrites its slot.
##
## This probe is stdlib-only — no brokers, no chronos — so a verdict here is a
## statement about the toolchain and platform, never about broker code. ORC is
## the control: it is precise, so an ORC verdict of RETAINED would mean the
## registration really is leaking and the problem is ours.
##
## Exit codes (so a driver can tabulate without parsing prose):
##   0  — no survivors at any N
##   10 — survivors present but BOUNDED (<= SurvivorLimit at the largest N):
##        the conservative-scan artifact, benign
##   20 — survivors SCALE with N => a real reference is still held (a bug)
##   2  — the registration failed to pin the instances at all (probe invalid)

import std/tables

const
  Lengths = [1, 10, 100, 500]
  SurvivorLimit = 5 ## Same tolerance `test_broker_lifecycle` applies. Measured at 1.

var gAlive = 0

type Mark = object

proc `=destroy`(m: var Mark) =
  dec gAlive

type Impl = ref object
  mark: Mark
  payload: string

var gProviders: Table[int, proc(): int {.closure, gcsafe, raises: [].}]

proc create(id: int): Impl =
  inc gAlive
  let self = Impl(payload: "instance-" & $id)
  # The closure captures `self`; this registration is the only thing that
  # keeps the instance reachable once the creating scope returns.
  gProviders[id] = proc(): int {.closure, gcsafe, raises: [].} =
    self.payload.len
  self

# Shape 1: register, exercise, de-register, all within one scope — the
# `close()` path.
proc createUseDeregister(id: int) {.noinline.} =
  let g = create(id)
  doAssert gProviders[id]() > 0 # exercise the closure, as a real call would
  doAssert g.payload.len > 0
  gProviders.del(id)

# Shape 2: register and leave it registered; the instances must stay pinned
# until the registrations are cleared afterwards — the `clearProvider` path.
proc createRegisterOnly(id: int) {.noinline.} =
  let g = create(id)
  doAssert g.payload.len > 0

const Shape2Base = 1_000_000

proc aliveSince(base: int): int =
  GC_fullCollect()
  gAlive - base

proc main() =
  var worst = 0

  for n in Lengths:
    block shape1:
      let base = gAlive
      for i in 0 ..< n:
        createUseDeregister(i)
      let survivors = aliveSince(base)
      echo "shape1/deregister  N=", n, " survivors=", survivors
      if survivors > SurvivorLimit:
        worst = max(worst, 20)
      elif survivors > 0:
        worst = max(worst, 10)

    block shape2:
      let base = gAlive
      for i in 0 ..< n:
        createRegisterOnly(Shape2Base + i)
      # Everything must be pinned by its registration at this point. A false
      # root can only add to the count, never subtract — but a straggler from
      # the previous shape may be reclaimed while this one runs, so the bound
      # carries the same tolerance.
      let pinned = aliveSince(base)
      if pinned < n - SurvivorLimit:
        echo "shape2: registrations did not pin the instances (pinned=",
          pinned, " of ", n, ")"
        quit(2)
      for i in 0 ..< n:
        gProviders.del(Shape2Base + i)
      let survivors = aliveSince(base)
      echo "shape2/clear       N=", n, " pinned=", pinned, " survivors=", survivors
      if survivors > SurvivorLimit:
        worst = max(worst, 20)
      elif survivors > 0:
        worst = max(worst, 10)

  let verdict =
    if worst == 0:
      "CLEAN (no survivors at any N)"
    elif worst == 10:
      "BOUNDED (survivors <= " & $SurvivorLimit &
        " at every N — conservative-scan artifact)"
    else:
      "RETAINED (survivors exceed the bound — a real reference is held)"
  echo "VERDICT ", verdict
  quit(worst)

main()
