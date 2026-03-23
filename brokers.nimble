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

proc quoteArg(arg: string): string =
  if defined(windows):
    result = '"' & arg.replace("\"", "\"\"") & '"'
  else:
    result = '"' & arg.replace("\"", "\\\"") & '"'

proc compileVariantSuffix(env: string): string =
  let normalized = env.toLowerAscii()
  let memoryManager = if normalized.contains("--mm:refc"): "refc" else: "orc"
  let buildMode = if normalized.contains("-d:release"): "release" else: "debug"

  memoryManager & "_" & buildMode

proc test(env, path: string) =
  let outputPath = joinPath("build", path & "_" & compileVariantSuffix(env))
  exec "nim c " & env & " -r --path:src --out:" & quoteArg(outputPath) & " test/" & path &
    ".nim"

proc isExcludedNimPath(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized == "nimbledeps" or normalized == "vendor" or normalized == "doc" or
    normalized.startsWith("nimbledeps/") or normalized.startsWith("vendor/") or
    normalized.startsWith("doc/") or normalized.startsWith("./nimbledeps/") or
    normalized.startsWith("./vendor/") or normalized.startsWith("./doc/")

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
    for opt in [
      "--mm:orc", "--mm:refc", "-d:release -d:gcAssert -d:sysAssert --mm:orc",
      "-d:release -d:gcAssert -d:sysAssert --mm:refc",
    ]:
      test opt, f

  let mtTests = ["test_multi_thread_request_broker", "test_multi_thread_event_broker"]
  for f in mtTests:
    for opt in [
      "--mm:orc --threads:on", "--mm:refc --threads:on",
      "-d:release --mm:orc --threads:on", "-d:release --mm:refc --threads:on",
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

task testApi, "Run FFI API broker tests":
  let apiTests = ["test_api_request_broker", "test_api_event_broker"]
  for f in apiTests:
    for opt in [
      "-d:BrokerFfiApi --mm:orc --threads:on", "-d:BrokerFfiApi --mm:refc --threads:on",
      "-d:BrokerFfiApi -d:release --mm:orc --threads:on",
      "-d:BrokerFfiApi -d:release --mm:refc --threads:on",
    ]:
      test opt, f

task buildFfiExample, "Build FFI API example library":
  exec "nim c -d:BrokerFfiApi --threads:on --app:lib --nimMainPrefix:mylib --path:src --outdir:examples/ffiapi/nimlib/build examples/ffiapi/nimlib/mylib.nim"

task buildFfiExampleC, "Build FFI API example — pure C application":
  let libDir = "examples/ffiapi/nimlib/build"
  let appDir = "examples/ffiapi/example"
  let buildDir = appDir & "/build"
  mkDir(buildDir)
  exec "cc -std=c11 -I" & libDir & " -L" & libDir &
    " -lmylib -Wl,-rpath,@loader_path/../../nimlib/build -o " & buildDir & "/example " &
    appDir & "/main.c"

task buildFfiExampleCpp, "Build FFI API example — modern C++ application":
  let libDir = "examples/ffiapi/nimlib/build"
  let appDir = "examples/ffiapi/cpp_example"
  let buildDir = appDir & "/build"
  mkDir(buildDir)
  exec "c++ -std=c++17 -I" & libDir & " -L" & libDir &
    " -lmylib -Wl,-rpath,@loader_path/../../nimlib/build -o " & buildDir & "/example " &
    appDir & "/main.cpp"

task nph, "Install nph if needed and format modified Nim files":
  runNph(changedNimFiles(), "No modified .nim or .nimble files to format")

task nphall, "Install nph if needed and format all Nim files in the project":
  runNph(allNimFiles(), "No .nim or .nimble files found to format")
