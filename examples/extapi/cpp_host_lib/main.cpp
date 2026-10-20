// EXTAPI example — scenario 1b: lib mode. This C++ application hosts the Nim
// library `storagelib` and implements the `notes` plugin that the library
// consumes — in-process, with the C3 Builder (closures, provides exactly what
// is set). Then it calls the library's own (API) request, whose Nim provider
// calls back into this app through EXTAPI.

#include "notes_ext.hpp"
#include "storagelib.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <string>

extern "C" const broker_ext_host* storagelib_extHost(void);

static int failures = 0;

static void expect(bool cond, const char* what) {
  std::printf("  %s  %s\n", cond ? "ok  " : "FAIL", what);
  if (!cond) ++failures;
}

int main() {
  std::puts("== scenario 1b: lib mode, plugin implemented by the host app (C++)");
  storagelib::Storagelib lib;
  auto created = lib.createContext();
  expect(created.isOk(), "storagelib createContext");
  if (!created.isOk()) return 1;

  const broker_ext_host* host = storagelib_extHost();
  expect(host != nullptr, "storagelib_extHost()");

  std::atomic<int> stored{0};
  auto port = notes_ext::Builder{}
                  .noteStored([&](std::string text, notes_ext::Responder<notes_ext::NoteStored> r) {
                    stored.fetch_add(1);
                    r.ok(notes_ext::NoteStored{"note-" + std::to_string(text.size())});
                  })
                  .open(host, lib.ctx());
  expect(port.isOk(), "notes Builder.open (provides note_stored)");

  auto saved = lib.saveNote("hello");
  expect(saved.isOk(), "SaveNote via the library's (API)");
  if (!saved.isOk()) std::printf("        error: %s\n", saved.error().c_str());
  if (saved.isOk()) {
    expect(saved.value().id == "note-5", "id produced by the app's plugin");
    expect(saved.value().via == "notes plugin", "Nim provider routed through EXTAPI");
  }
  expect(stored.load() == 1, "plugin closure invoked once");

  port.value().close();
  auto after = lib.saveNote("again");
  expect(!after.isOk(), "after close: no provider");

  lib.shutdown();
  if (failures > 0) {
    std::printf("cpp_host_lib: %d check(s) failed\n", failures);
    return 1;
  }
  std::puts("cpp_host_lib: all checks passed");
  return 0;
}
