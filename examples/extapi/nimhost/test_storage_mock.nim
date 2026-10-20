{.used.}

## EXTAPI example — scenario 3: mocking. EXTAPI brokers are ordinary MT
## brokers on the Nim side, so tests mock them with the usual
## `withMockProvider`, closures with captured state included — with no plugin
## at all, and with a real plugin (EXT_PLUGIN=<path>) attached.

import std/[os, strutils]
import chronos
import testutils/unittests
import ./storage_api

proc text(b: seq[byte]): string =
  for x in b:
    result.add(char(x))

proc localFetch(key: string): Future[Result[FetchBlob, string]] {.async.} =
  var d: seq[byte]
  for c in "nim:" & key:
    d.add(byte(c))
  return ok(FetchBlob(data: d))

suite "EXTAPI example — mocking":
  test "mock without any plugin":
    let ctx = NewBrokerContext()
    var calls: seq[string] # captured by the mock closure
    proc mock(key: string): Future[Result[FetchBlob, string]] {.async.} =
      calls.add(key)
      return ok(FetchBlob(data: @[byte 42]))

    check FetchBlob.setProvider(ctx, localFetch).isOk
    FetchBlob.withMockProvider(ctx, mock):
      check (waitFor FetchBlob.request(ctx, "k")).get(FetchBlob()).data == @[byte 42]
    check calls == @["k"]
    check (waitFor FetchBlob.request(ctx, "k")).get(FetchBlob()).data.text == "nim:k"

  test "mock while a real plugin is attached":
    let pluginPath = getEnv("EXT_PLUGIN")
    if pluginPath.len == 0:
      skip()
    else:
      check ExtHost.start().isOk
      check ExtHost.loadPlugin(pluginPath).isOk # opens on DefaultBrokerContext
      let ctx = DefaultBrokerContext
      check FetchBlob.setProvider(ctx, FetchBlob.extProvider(ctx)).isOk
      let real = (waitFor FetchBlob.request(ctx, "k")).get(FetchBlob()).data.text
      check real.endsWith(":k") and not real.startsWith("nim:")
      var hits = 0
      proc mock(key: string): Future[Result[FetchBlob, string]] {.async.} =
        inc hits
        return ok(FetchBlob(data: @[byte 7]))

      FetchBlob.withMockProvider(ctx, mock):
        check (waitFor FetchBlob.request(ctx, "k")).get(FetchBlob()).data == @[byte 7]
      check hits == 1
      check (waitFor FetchBlob.request(ctx, "k")).get(FetchBlob()).data.text == real
      # Events can be driven from Nim too: no plugin needed to test listeners.
      var seen = 0
      proc onEvicted(e: BlobEvicted): Future[void] {.async: (raises: []).} =
        inc seen

      check BlobEvicted.listen(ctx, onEvicted).isOk
      BlobEvicted.emit(ctx, BlobEvicted(key: "x", reason: "test"))
      var waited = 0
      while seen == 0 and waited < 2000:
        waitFor sleepAsync(chronos.milliseconds(5))
        waited += 5
      check seen == 1
      doAssert ExtHost.stop().isOk
