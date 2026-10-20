## Regression test: a `registerBrokerLibrary` shared library runs its module
## initialiser exactly once.
##
## Nim's `--app:lib` codegen already runs `<prefix>NimMain` from the loader
## (`NimMainInit`, an `__attribute__((constructor))`, on POSIX; `DllMain` on
## Windows). `<lib>_initialize` used to call `<prefix>NimMain` again on POSIX,
## re-running every module's top-level code (broker/plugin registration,
## counters, system init) a second time. See doc/FFI_API.md
## § "Module initialisation".
##
## The library under test (`test/initoncelib/initoncelib.nim`) is built by the
## `testApi` task and its path passed in via `-d:initOnceLib=<path>`; add
## `-d:initOnceNoMain` when the library was built with `--noMain`.

import std/dynlib
import testutils/unittests

const initOnceLib {.strdefine.} = ""

type
  VoidFn = proc() {.cdecl, gcsafe, raises: [].}
  CountFn = proc(): cint {.cdecl, gcsafe, raises: [].}
  CreateCtxFn = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  ShutdownFn = proc(ctx: uint32): int32 {.cdecl, gcsafe, raises: [].}

suite "FFI library module initialisation":
  test "module init runs once across load, _initialize and _createContext":
    doAssert initOnceLib.len > 0, "build with -d:initOnceLib=<path to library>"
    let lib = loadLib(initOnceLib)
    doAssert lib != nil, "cannot load " & initOnceLib

    let runs = cast[CountFn](lib.checkedSymAddr("initoncelib_moduleInitRuns"))
    let initialize = cast[VoidFn](lib.checkedSymAddr("initoncelib_initialize"))
    let createContext =
      cast[CreateCtxFn](lib.checkedSymAddr("initoncelib_createContext"))
    let shutdown = cast[ShutdownFn](lib.checkedSymAddr("initoncelib_shutdown"))

    when defined(initOnceNoMain):
      # Built with `--noMain`: no loader hook, `_initialize` runs NimMain.
      check runs() == 0
    else:
      # The loader hook has already run the module initialiser.
      check runs() == 1

    initialize()
    check runs() == 1

    initialize() # idempotent
    check runs() == 1

    let ctx = createContext()
    check ctx != 0'u32
    check runs() == 1

    check shutdown(ctx) == 0
    check runs() == 1
    # No unloadLib: a Nim runtime is not designed to be unloaded.
