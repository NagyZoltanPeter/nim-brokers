## EXTAPI example — lib mode (scenario 1b). A Nim *library* that publishes an
## `(API)` request and consumes an EXTAPI plugin (`notes`) that its *host
## application* implements in-process: the app gets the host table through
## `storagelib_extHost()` and wires the plugin with the generated
## `notes_ext.hpp` (C++) / `notes_ext_rs` (Rust).

import chronos, results
import brokers/[request_broker, broker_context, api_library, ext_plugin]

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

# --- consumed: implemented by the host application ---------------------------

RequestBroker(EXTAPI[notes]):
  ## Persist a note; the host app returns its id.
  type NoteStored = object
    id*: string

  proc signature*(text: string): Future[Result[NoteStored, string]] {.async.}

registerExtPlugin(notes, version = "1.0.0")
exportExtHost("storagelib")

# --- published: the library's own API ----------------------------------------

RequestBroker(API):
  ## Save a note through whatever implements `notes` (the host app's plugin).
  type SaveNote = object
    id*: string
    via*: string

  proc signature*(text: string): Future[Result[SaveNote, string]] {.async.}

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc saveProv(text: string): Future[Result[SaveNote, string]] {.async.} =
    # An (API) provider on the processing thread calling an EXTAPI broker.
    let r = await NoteStored.request(ctx, text)
    if r.isErr:
      return err("notes plugin: " & r.error)
    return ok(SaveNote(id: r.value.id, via: "notes plugin"))

  ?SaveNote.setProvider(ctx, saveProv)
  ok()

registerBrokerLibrary:
  name:
    "storagelib"
  version:
    "1.0.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
