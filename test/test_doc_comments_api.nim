{.used.}

## Issue #50, API lane: `##` doc comments written in `(API)` broker
## declarations must flow into every generated wrapper artifact — the C
## header, the C++ header, the Python / Rust / Go wrappers (enabled via
## this file's .nim.cfg), and the CDDL schema (file + `_getSchema`).
##
## The `(mt)` forms are declared here too (this binary compiles with
## --threads:on) as compile-level acceptance coverage.

import std/[json, os, strutils]
import testutils/unittests
import brokers/[event_broker, request_broker, signal_broker, broker_context]
import brokers/api_library
import brokers/internal/api_outdir

## ---------------------------------------------------------------------------
## (mt) forms — compile-level doc acceptance
## ---------------------------------------------------------------------------

EventBroker(mt):
  ## MT event carrying a doc comment.
  type DocMtEvent = object
    tick: int64 ## Monotonic tick.

RequestBroker(mt):
  ## MT request carrying a doc comment.
  type DocMtReq = object
    n*: int32 ## Payload field doc.

  ## Doc above the MT signature.
  proc signature*(): Future[Result[DocMtReq, string]] {.async.}

SignalBroker(mt):
  ## MT signal carrying a doc comment.
  type DocMtSig = object
    level: int32 ## Severity level.

## ---------------------------------------------------------------------------
## Inline (API) library with doc comments everywhere
## ---------------------------------------------------------------------------

RequestBroker(API):
  type DocInitReq = object
    initialized*: bool

  proc signature*(): Future[Result[DocInitReq, string]] {.async.}

RequestBroker(API):
  type DocShutReq = object
    status*: int32

  proc signature*(): Future[Result[DocShutReq, string]] {.async.}

RequestBroker(API):
  ## Health snapshot over the wire.
  type DocApiHealth = object
    ok*: bool ## True when all subsystems run.
    code*: int32 ## Machine-readable status code.

  ## Query api liveness.
  proc signature*(): Future[Result[DocApiHealth, string]] {.async.}

RequestBroker(API):
  ## Send a ping to a named target.
  proc SendDocPing(target: string): Future[Result[bool, string]] {.async.}

EventBroker(API):
  ## Emitted periodically while the library runs.
  type DocApiHeartbeat = object
    seqNo*: int64 ## Monotonic heartbeat counter.

SignalBroker(API):
  ## One-way nudge consumed by the library.
  type DocApiNudge = object
    reason*: string ## Why the nudge was sent.

registerBrokerLibrary:
  ## Doc comments are also legal inside the library block.
  name:
    "cbdoc"
  version:
    "0.1.0"
  initializeRequest:
    DocInitReq
  shutdownRequest:
    DocShutReq

## ---------------------------------------------------------------------------
## Generated-artifact assertions
## ---------------------------------------------------------------------------

const genDir =
  detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")

proc genFile(name: string): string =
  ## Read a generated artifact from the codegen output directory.
  readFile(
    if genDir.len > 0:
      genDir / name
    else:
      name
  )

proc takeStr(buf: pointer, len: int32): string =
  if buf.isNil or len <= 0:
    return ""
  result = newString(len.int)
  copyMem(addr result[0], buf, len.int)
  cbdoc_freeBuffer(buf)

suite "doc comments in generated FFI artifacts (#50)":
  test "CDDL carries ';' doc comments (file and _getSchema)":
    let cddl = genFile("cbdoc.cddl")
    check "; Health snapshot over the wire." in cddl
    check "; True when all subsystems run." in cddl
    check "; Machine-readable status code." in cddl
    check "; Query api liveness." in cddl
    check "; Send a ping to a named target." in cddl
    check "; Emitted periodically while the library runs." in cddl
    check "; One-way nudge consumed by the library." in cddl

    var buf: pointer = nil
    var len: int32 = 0
    check cbdoc_getSchema(addr buf, addr len) == 0'i32
    let schemaJson = takeStr(buf, len)
    check "Health snapshot over the wire." in schemaJson

  test "_getSchema descriptor carries structured doc fields":
    var buf: pointer = nil
    var len: int32 = 0
    check cbdoc_getSchema(addr buf, addr len) == 0'i32
    let info = parseJson(takeStr(buf, len))

    var seenHealth = false
    for r in info["requests"]:
      if r["apiName"].getStr() == "doc_api_health":
        seenHealth = true
        check r["doc"].getStr() == "Query api liveness."
    check seenHealth

    var seenHeartbeat = false
    for e in info["events"]:
      if e["apiName"].getStr() == "doc_api_heartbeat":
        seenHeartbeat = true
        check e["doc"].getStr() == "Emitted periodically while the library runs."
    check seenHeartbeat

    var seenNudge = false
    for s in info["signals"]:
      if s["apiName"].getStr() == "doc_api_nudge":
        seenNudge = true
        check s["doc"].getStr() == "One-way nudge consumed by the library."
    check seenNudge

    var seenType = false
    for t in info["types"]:
      if t["name"].getStr() == "DocApiHealth":
        seenType = true
        check t["doc"].getStr() == "Health snapshot over the wire."
        var seenField = false
        for f in t["fields"]:
          if f["name"].getStr() == "ok":
            seenField = true
            check f["doc"].getStr() == "True when all subsystems run."
        check seenField
    check seenType

  test "C header documents apiNames with the captured doc text":
    let h = genFile("cbdoc.h")
    check "\"doc_api_health\"" in h
    check "Query api liveness." in h
    check "Send a ping to a named target." in h
    check "Emitted periodically while the library runs." in h
    check "One-way nudge consumed by the library." in h

  test "C++ header carries /** */ docs on structs, fields and methods":
    let hpp = genFile("cbdoc.hpp")
    check "Health snapshot over the wire." in hpp
    check "True when all subsystems run." in hpp
    check "Query api liveness." in hpp
    check "Send a ping to a named target." in hpp
    check "Emitted periodically while the library runs." in hpp
    check "One-way nudge consumed by the library." in hpp
    check "/**" in hpp

  test "Python wrapper carries docstrings and field comments":
    let py = genFile("cbdoc.py")
    check "\"\"\"Health snapshot over the wire.\"\"\"" in py
    check "# True when all subsystems run." in py
    check "\"\"\"Query api liveness.\"\"\"" in py
    check "\"\"\"Send a ping to a named target.\"\"\"" in py
    check "Emitted periodically while the library runs." in py
    check "\"\"\"One-way nudge consumed by the library.\"\"\"" in py

  test "Rust wrapper carries /// docs":
    let rs = genFile("cbdoc_rs" / "src" / "lib.rs")
    check "/// Health snapshot over the wire." in rs
    check "/// True when all subsystems run." in rs
    check "/// Query api liveness." in rs
    check "/// Send a ping to a named target." in rs
    check "/// Emitted periodically while the library runs." in rs
    check "/// One-way nudge consumed by the library." in rs

  test "Go wrapper carries // docs":
    let g = genFile("cbdoc_go" / "cbdoc.go")
    check "// Health snapshot over the wire." in g
    check "// True when all subsystems run." in g
    check "// Query api liveness." in g
    check "// Send a ping to a named target." in g
    check "// Emitted periodically while the library runs." in g
    check "// One-way nudge consumed by the library." in g
