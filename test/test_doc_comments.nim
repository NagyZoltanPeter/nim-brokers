{.used.}

## Issue #50: `##` doc comments must be accepted (and preserved) in every
## broker macro body. This module is primarily a compile-level test — each
## macro form below declares doc comments in all the positions users would
## naturally write them (above the `type`, trailing on object fields, as the
## first line inside the object, above and under the `proc` signatures, at
## interface level). The runtime tests prove behavior is unchanged.
##
## The (mt) and (API) forms are covered by test_doc_comments_api.nim (they
## need --threads:on / -d:BrokerFfiApi).

import testutils/unittests
import chronos

import brokers/event_broker
import brokers/request_broker
import brokers/multi_request_broker
import brokers/signal_broker
import brokers/broker_interface

## ---------------------------------------------------------------------------
## EventBroker
## ---------------------------------------------------------------------------

EventBroker:
  ## Fired when a device row changes.
  ## Second doc line.
  type DocDeviceUpdated = object
    deviceId: string ## Stable device identifier.
    online: bool ## Current link state.

EventBroker:
  type DocPulse = object
    ## Trailing doc on the object head.
    ## Doc as the first line inside the object.
    seqNo: int

## ---------------------------------------------------------------------------
## RequestBroker — legacy `signature*` form
## ---------------------------------------------------------------------------

RequestBroker:
  ## Health snapshot of the node.
  type DocHealth = object
    ok*: bool ## True when all subsystems run.

  ## Doc above the signature proc.
  proc signature*(): Future[Result[DocHealth, string]] {.async.}

RequestBroker(sync):
  ## Sync config snapshot.
  type DocCfgSnap = object
    key*: string

  proc signature*(): Result[DocCfgSnap, string]

## ---------------------------------------------------------------------------
## RequestBroker — proc sugar (POD + object forms, both signature slots)
## ---------------------------------------------------------------------------

RequestBroker:
  ## Returns the running node version.
  proc GetDocVersion(): Future[Result[string, string]] {.async.}

RequestBroker:
  ## Broker-level doc above the payload type.
  type DocLookup = object
    hit*: bool ## Whether the key was found.

  ## Zero-arg lookup doc.
  proc docLookup(): Future[Result[DocLookup, string]] {.async.}
  ## Arg-based lookup doc.
  proc docLookup(key: int): Future[Result[DocLookup, string]] {.async.}

RequestBroker:
  proc GetDocTag(): Future[Result[string, string]] {.async.}
    ## Doc indented under the signature.

## ---------------------------------------------------------------------------
## MultiRequestBroker
## ---------------------------------------------------------------------------

MultiRequestBroker:
  ## Collects peer info from every registered provider.
  type DocPeerInfo = object
    id*: string ## Peer identity.

  ## Doc above the multi signature.
  proc signature*(): Future[Result[DocPeerInfo, string]] {.async.}

## ---------------------------------------------------------------------------
## SignalBroker
## ---------------------------------------------------------------------------

SignalBroker:
  ## One-way telemetry pulse.
  type DocTelemetryTick = object
    seqNo: int ## Monotonic counter.

## ---------------------------------------------------------------------------
## BrokerInterface (plain) — interface-level and sub-block docs
## ---------------------------------------------------------------------------

BrokerInterface IDocHealth:
  ## Facade for health queries.
  EventBroker:
    ## Emitted on status transitions.
    type DocStatusChanged = object
      healthy: bool ## New state.

  RequestBroker:
    ## Query liveness.
    proc getDocLive(): Future[Result[bool, string]] {.async.}

  SignalBroker:
    ## Ask the implementation to refresh.
    type DocRefresh = void

## ---------------------------------------------------------------------------
## Runtime: behavior is unchanged by the doc comments
## ---------------------------------------------------------------------------

suite "doc comments in broker macros (#50)":
  asyncTest "EventBroker with docs emits and delivers normally":
    var seen: seq[string] = @[]
    let handle = DocDeviceUpdated
      .listen(
        proc(ev: DocDeviceUpdated): Future[void] {.async: (raises: []), gcsafe.} =
          seen.add(ev.deviceId)
      )
      .get()
    DocDeviceUpdated.emit(DocDeviceUpdated(deviceId: "dev-1", online: true))
    await sleepAsync(1.milliseconds)
    check seen == @["dev-1"]
    await DocDeviceUpdated.dropListener(handle)

  test "RequestBroker (legacy) with docs answers requests normally":
    DocHealth
      .setProvider(
        proc(): Future[Result[DocHealth, string]] {.async.} =
          ok(DocHealth(ok: true))
      )
      .get()
    let r = waitFor DocHealth.request()
    check r.isOk()
    check r.value.ok

  test "RequestBroker (sugar) with docs on both slots dispatches normally":
    DocLookup
      .setProvider(
        proc(): Future[Result[DocLookup, string]] {.async.} =
          ok(DocLookup(hit: false))
      )
      .get()
    DocLookup
      .setProvider(
        proc(key: int): Future[Result[DocLookup, string]] {.async.} =
          ok(DocLookup(hit: key == 7))
      )
      .get()
    check not (waitFor DocLookup.request()).value.hit
    check (waitFor DocLookup.request(7)).value.hit

  test "sync sugar with docs answers normally":
    DocCfgSnap
      .setProvider(
        proc(): Result[DocCfgSnap, string] =
          ok(DocCfgSnap(key: "k"))
      )
      .get()
    check DocCfgSnap.request().value.key == "k"

  test "BrokerInterface tunneling proc with docs routes through the broker":
    GetDocLive
      .setProvider(
        proc(): Future[Result[bool, string]] {.async.} =
          ok(true)
      )
      .get()
    let iface = IDocHealth(brokerCtx: DefaultBrokerContext)
    let r = waitFor iface.getDocLive()
    check r.isOk()
    check r.value
