#!/usr/bin/env python3
"""Persistence — Python wrapper example.

Exercises the two-layer interface (IPersistence -> IBackend) with
per-instance routing and per-subscription event delivery, replicating
the C++ Scenario B.
"""

import os
import sys
import time
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_BUILD_DIR = os.environ.get("PERSISTENCE_BUILD_DIR", "build")
sys.path.insert(0, str(ROOT / "nimlib" / _BUILD_DIR))

from persistence import Persistence, Backend  # noqa: E402

KIND_MEMORY = 0
KIND_FILE = 1


def wait_for(pred, timeout=2.0):
    deadline = time.monotonic() + timeout
    while not pred() and time.monotonic() < deadline:
        time.sleep(0.005)
    return pred()


def roundtrip(lib, be, key, val):
    """Store then read a key; return the value delivered via event."""
    lock = threading.Lock()
    result = {"value": None, "found": False, "count": 0}

    def on_read(_owner, k, v, found):
        if k == key:
            with lock:
                result["value"] = v
                result["found"] = found
                result["count"] += 1

    h = be.on_read_completed(on_read)
    assert h != 0

    r = be.store(key, val)
    assert r.is_ok(), r.error

    before = result["count"]
    r = be.read(key)
    assert r.is_ok(), r.error

    assert wait_for(lambda: result["count"] > before), "read event timed out"
    be.off_read_completed(h)

    with lock:
        assert result["found"], "expected key to be found"
        return result["value"]


def scenario_two_contexts():
    """A: Two independent IPersistence contexts (File + Memory)."""
    print("  [A] two IPersistence contexts (File + Memory)")

    with Persistence() as p_file:
        assert p_file.create_context().is_ok()
        assert p_file.initialize_request("cfg").is_ok()
        bf = p_file.make_backend(KIND_FILE)
        assert bf.is_ok(), bf.error
        bf = bf.value
        assert bf.valid()
        assert roundtrip(p_file, bf, "alpha", "file-payload") == "file-payload"

        with Persistence() as p_mem:
            assert p_mem.create_context().is_ok()
            assert p_mem.initialize_request("cfg").is_ok()
            bm = p_mem.make_backend(KIND_MEMORY)
            assert bm.is_ok(), bm.error
            bm = bm.value
            assert bm.valid()
            assert roundtrip(p_mem, bm, "alpha", "memory-payload") == "memory-payload"

            assert (bf.ctx & 0xFFFF) != (bm.ctx & 0xFFFF)


def scenario_mixed_one_context():
    """B: One IPersistence context with File + Memory backends coexisting."""
    print("  [B] one IPersistence context, File + Memory backends coexisting")

    with Persistence() as p:
        assert p.create_context().is_ok()
        assert p.initialize_request("cfg").is_ok()

        created = {"count": 0}

        def on_created(_owner, handle, kind):
            created["count"] += 1

        ch = p.on_backend_created(on_created)

        bf = p.make_backend(KIND_FILE)
        assert bf.is_ok(), bf.error
        bf = bf.value

        bm = p.make_backend(KIND_MEMORY)
        assert bm.is_ok(), bm.error
        bm = bm.value

        assert wait_for(lambda: created["count"] == 2), "BackendCreated events"
        p.off_backend_created(ch)

        # Routing invariant: both backends share classCtx, differ in instanceCtx.
        assert (bf.ctx & 0xFFFF) == (p.ctx & 0xFFFF)
        assert (bm.ctx & 0xFFFF) == (p.ctx & 0xFFFF)
        assert (bf.ctx >> 16) != (bm.ctx >> 16)
        assert bf.ctx != bm.ctx

        # Per-instance request routing + per-subscription event delivery.
        assert roundtrip(p, bf, "x", "FILE-X") == "FILE-X"
        assert roundtrip(p, bm, "x", "MEM-X") == "MEM-X"

        # State check: both backends listed and alive.
        st = p.list_backends()
        assert st.is_ok(), st.error
        items = st.value.backends
        assert len(items) == 2
        for it in items:
            assert it.alive

        # Targeted teardown: terminate the File backend.
        r = p.terminate_backend(bf.ctx)
        assert r.is_ok(), r.error
        st = p.list_backends()
        assert st.is_ok(), st.error
        file_dead = False
        mem_alive = False
        for it in st.value.backends:
            if it.handle == bf.ctx:
                file_dead = not it.alive
            if it.handle == bm.ctx:
                mem_alive = it.alive
        assert file_dead, "File backend should be terminated"
        assert mem_alive, "Memory backend should still be alive"

        # Terminated backend rejects requests; sibling keeps working.
        assert be_store_err(bf, "y", "z"), "terminated backend must reject requests"
        assert roundtrip(p, bm, "y", "MEM-Y") == "MEM-Y"

        bf.close()


def be_store_err(be, key, val):
    return be.store(key, val).is_err()


def scenario_concurrent_load():
    """C: Two contexts running concurrently, 30 roundtrips each."""
    N = 30
    print(f"  [C] two IPersistence contexts running concurrently, {N} roundtrips each under load")

    ok_counts = {"file": 0, "mem": 0}

    def run_lib(kind, tag, count_key):
        with Persistence() as p:
            if not p.create_context().is_ok():
                return
            p.initialize_request("cfg")
            be_r = p.make_backend(kind)
            if not be_r.is_ok():
                return
            be = be_r.value

            results = {}
            lock = threading.Lock()

            def on_read(_owner, k, v, found):
                with lock:
                    results[k] = v

            h = be.on_read_completed(on_read)
            local = 0

            for i in range(N):
                key = f"{tag}_{i}"
                val = f"{tag}_val_{i}"
                if not be.store(key, val).is_ok():
                    continue
                if not be.read(key).is_ok():
                    continue
                got = wait_for(
                    lambda k=key: k in results,
                    timeout=3.0,
                )
                if got:
                    with lock:
                        if results.get(key) == val:
                            local += 1

            be.off_read_completed(h)
            ok_counts[count_key] = local
            # No barrier: each context's teardown must be isolated from the
            # sibling context still delivering events.

    t_file = threading.Thread(target=run_lib, args=(KIND_FILE, "fileLib", "file"))
    t_mem = threading.Thread(target=run_lib, args=(KIND_MEMORY, "memLib", "mem"))
    t_file.start()
    t_mem.start()
    t_file.join()
    t_mem.join()

    print(f"      File lib: {ok_counts['file']}/{N}  Memory lib: {ok_counts['mem']}/{N} roundtrips OK")
    assert ok_counts["file"] == N, f"File roundtrips: {ok_counts['file']}/{N}"
    assert ok_counts["mem"] == N, f"Memory roundtrips: {ok_counts['mem']}/{N}"


def main() -> int:
    print(f"persistence version: {Persistence.version()}")
    scenario_two_contexts()
    scenario_mixed_one_context()
    scenario_concurrent_load()
    print("persistence python example: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
