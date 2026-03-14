# Package
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Type-safe, thread-local, decoupled messaging patterns for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"
requires "chronos >= 4.0.0"
requires "results >= 0.5.0"
requires "chronicles >= 0.10.0"
requires "testutils >= 0.5.0"
requires "https://github.com/status-im/nim-async-channels"

proc test(env, path: string) =
  exec "nim c " & env & " -r --path:src --outdir:build test/" & path & ".nim"

task test, "Run all tests":
  let tests = ["test_event_broker", "test_request_broker", "test_multi_request_broker"]
  for f in tests:
    for opt in ["--mm:orc", "--mm:refc", "-d:release -d:gcAssert -d:sysAssert"]:
      test opt, f

  let mtTests = ["test_multi_thread_request_broker"]
  for f in mtTests:
    for opt in ["--mm:orc --threads:on", "--mm:refc --threads:on"]:
      test opt, f