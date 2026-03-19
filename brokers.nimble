import std/[os, strutils]

# Package
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "Type-safe, thread-local, decoupled messaging patterns for Nim"
license = "MIT"
srcDir = "src"

# Dependencies
requires "nim >= 2.0.0"
requires "chronos >= 4.0.0"
requires "results >= 0.5.0"
requires "chronicles >= 0.10.0"
requires "testutils >= 0.5.0"
requires "https://github.com/status-im/nim-async-channels"

proc test(env, path: string) =
  exec "nim c " & env & " -r --path:src --outdir:build test/" & path & ".nim"

proc quoteArg(arg: string): string =
  if defined(windows):
    result = '"' & arg.replace("\"", "\"\"") & '"'
  else:
    result = '"' & arg.replace("\"", "\\\"") & '"'

proc isExcludedNimPath(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized == "nimbledeps" or normalized == "vendor" or
    normalized.startsWith("nimbledeps/") or normalized.startsWith("vendor/") or
    normalized.startsWith("./nimbledeps/") or normalized.startsWith("./vendor/")

proc isNphFile(path: string): bool =
  path.endsWith(".nim") or path.endsWith(".nimble")

proc addUniqueNimFiles(files: var seq[string], output: string) =
  for line in output.splitLines():
    let path = line.strip()
    if path.len > 0 and isNphFile(path) and not isExcludedNimPath(path) and
        path notin files:
      files.add(path)

proc changedNimFiles(): seq[string] =
  for command in [
    "git diff --name-only --diff-filter=ACMR --",
    "git diff --cached --name-only --diff-filter=ACMR --",
    "git ls-files --others --exclude-standard -- '*.nim' '*.nimble'",
  ]:
    let (output, exitCode) = gorgeEx(command)
    if exitCode != 0:
      quit "Unable to determine modified files from git"

    result.addUniqueNimFiles(output)

proc allNimFiles(): seq[string] =
  for path in walkDirRec("."):
    if isNphFile(path) and not isExcludedNimPath(path):
      result.add(path)

proc installNphIfNeeded() =
  if findExe("nph").len == 0:
    echo "Installing nph formatter"
    exec "nimble install -y nph"

proc runNph(files: seq[string], emptyMessage: string) =
  installNphIfNeeded()

  if files.len == 0:
    echo emptyMessage
  else:
    for file in files:
      exec "nph " & quoteArg(file)

task test, "Run all tests":
  let tests = ["test_event_broker", "test_request_broker", "test_multi_request_broker"]
  for f in tests:
    for opt in ["--mm:orc", "--mm:refc", "-d:release -d:gcAssert -d:sysAssert"]:
      test opt, f

  let mtTests = ["test_multi_thread_request_broker", "test_multi_thread_event_broker"]
  for f in mtTests:
    for opt in [
      "--mm:orc --threads:on", "--mm:refc --threads:on",
      "-d:release --mm:orc --threads:on",
      "-d:release --mm:refc --threads:on --verbosity:3",
    ]:
      test opt, f

task perftest, "Run performance and stress tests":
  let mtTests =
    ["perf_test_multi_thread_request_broker", "perf_test_multi_thread_event_broker"]
  for f in mtTests:
    for opt in [
      "--mm:orc --threads:on", "--mm:refc --threads:on",
      "-d:release --mm:orc --threads:on", "-d:release --mm:refc --threads:on",
    ]:
      test opt, f

task nph, "Install nph if needed and format modified Nim files":
  runNph(changedNimFiles(), "No modified .nim or .nimble files to format")

task nphall, "Install nph if needed and format all Nim files in the project":
  runNph(allNimFiles(), "No .nim or .nimble files found to format")
