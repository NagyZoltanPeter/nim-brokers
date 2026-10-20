"""EXTAPI example — scenario 1b in Python: this application hosts the Nim
library `storagelib` and implements the `notes` plugin that the library
consumes, in-process. Then it calls the library's own (API) request, whose Nim
provider calls back into this app through EXTAPI.

Shows both wiring styles of the generated notes_ext.py:
  * Builder with a plain function (replies inline on the host's thread)
  * a `Notes` subclass with an `async def` running on an asyncio loop

    python3 main.py   # after `nimble runExtExamplePy` built nimlib/build/
"""

import asyncio
import ctypes
import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.environ.get("EXTAPI_LIB_DIR", os.path.join(HERE, "..", "nimlib", "build")))

import notes_ext  # noqa: E402  (generated next to libstoragelib)
import storagelib  # noqa: E402

failures = 0


def expect(cond: bool, what: str) -> None:
    global failures
    print(f"  {'ok  ' if cond else 'FAIL'}  {what}")
    if not cond:
        failures += 1


class AsyncNotes(notes_ext.Notes):
    def __init__(self) -> None:
        self.calls = 0

    async def note_stored(self, text: str) -> notes_ext.NoteStored:
        self.calls += 1
        await asyncio.sleep(0.01)
        return notes_ext.NoteStored(id=f"async-{len(text)}")


def main() -> int:
    print("== scenario 1b: lib mode, plugin implemented by the host app (Python)")
    lib = storagelib.Storagelib()
    expect(lib.create_context().is_ok(), "storagelib create_context")

    ext_host = storagelib._LIB.storagelib_extHost
    ext_host.restype = ctypes.c_void_p
    host = ext_host()
    expect(bool(host), "storagelib_extHost()")

    # 1. Builder + plain function.
    stored = []

    def note_stored(text: str) -> notes_ext.NoteStored:
        stored.append(text)
        return notes_ext.NoteStored(id=f"note-{len(text)}")

    port = notes_ext.Builder().note_stored(note_stored).open(host, lib.ctx)
    r = lib.save_note("hello")
    expect(r.is_ok(), "SaveNote via the library's (API)")
    if r.is_ok():
        expect(r.value.id == "note-5", "id produced by the app's plugin (sync)")
        expect(r.value.via == "notes plugin", "Nim provider routed through EXTAPI")
    else:
        print(f"        error: {r.error}")
    expect(stored == ["hello"], "plugin function invoked once")
    port.close()
    expect(lib.save_note("again").is_err(), "after close: no provider")

    # 2. Subclass with an async method on a loop thread.
    loop = asyncio.new_event_loop()
    t = threading.Thread(target=loop.run_forever, daemon=True)
    t.start()
    impl = AsyncNotes()
    port = notes_ext.Port.open(host, lib.ctx, impl, loop)
    expect(port.provide_all() == notes_ext.OK, "Port.open + provide_all")
    r = lib.save_note("hey")
    expect(r.is_ok() and r.value.id == "async-3", "id produced by the async method")
    expect(impl.calls == 1, "async method invoked once")
    port.close()
    loop.call_soon_threadsafe(loop.stop)
    t.join()

    lib.shutdown()
    if failures:
        print(f"python_host_lib: {failures} check(s) failed")
        return 1
    print("python_host_lib: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
