## Minimal probe for the refc destroy-observability hazard that forces the
## skip guard in `test/test_broker_lifecycle.nim`.
##
## That test asserts a *semantic*: an instance held alive only by a closure
## registered in a global table becomes collectable once the registration is
## removed. It observes the semantic through `=destroy` on a marker field
## firing after `GC_fullCollect()` — and that observation is not something
## `--mm:refc` guarantees. refc sweeps conservatively: any pointer-shaped
## value still sitting in the C stack or in a callee-saved register roots the
## object, so the destructor does not run and the test reports a leak that
## is not there.
##
## This probe isolates the pattern from nim-brokers entirely — no brokers, no
## chronos, stdlib only — so a failure here is a statement about the toolchain
## and platform, never about broker code. ORC is the control: it is precise,
## so if ORC ever reports a retained instance the registration really is
## leaking and the problem is ours.
##
## Exit codes (so a driver can tabulate without parsing prose):
##   0  — instance released as expected
##   1  — retained after de-registration (the hazard)
##   2  — registration failed to pin the instance at all
##   3  — retained after the registration was cleared
##
## Observed so far: fails under `--mm:refc -d:release` on Linux across every
## 2.2.x tried (2.2.4 … 2.2.12); passes on macOS arm64, under refc debug, and
## under ORC everywhere. See doc/LIMITATION.md §1.2.

import std/tables

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

proc deregister(id: int) =
  gProviders.del(id)

proc scopeWithDeregister() =
  let g = create(1)
  doAssert gAlive == 1
  doAssert gProviders[1]() > 0 # exercise the closure, as a real call would
  doAssert g.payload.len > 0
  deregister(1)

proc scopeWithoutDeregister() =
  let g = create(2)
  doAssert g.payload.len > 0

proc main() =
  scopeWithDeregister()
  GC_fullCollect()
  echo "after deregister + collect: gAlive = ", gAlive
  if gAlive != 0:
    echo "probeRefcDestroy: RETAINED (destructor did not run)"
    quit(1)

  scopeWithoutDeregister()
  GC_fullCollect()
  echo "still registered: gAlive = ", gAlive
  if gAlive != 1:
    echo "probeRefcDestroy: registration did not pin the instance"
    quit(2)

  deregister(2)
  GC_fullCollect()
  echo "after clearing registration: gAlive = ", gAlive
  if gAlive != 0:
    echo "probeRefcDestroy: RETAINED after clearing the registration"
    quit(3)

  echo "probeRefcDestroy: OK (instance released in both shapes)"

main()
