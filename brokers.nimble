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

proc findPythonExe(): string =
  result = findExe("python3")
  if result.len == 0:
    result = findExe("python")
  if result.len == 0:
    quit "Python interpreter not found. Install python3 or add it to PATH."

proc buildFfiExampleFlags(generatePy = false): string =
  result =
    "-d:BrokerFfiApi --threads:on --app:lib --nimMainPrefix:mylib --path:src --outdir:examples/ffiapi/nimlib/build"
  if existsEnv("MM"):
    result.add(" --mm:" & getEnv("MM"))
  if generatePy or existsEnv("GEN_PY"):
    result.add(" -d:BrokerFfiApiGenPy")

proc buildFfiExampleLibrary(generatePy = false) =
  exec "nim c " & buildFfiExampleFlags(generatePy) & " examples/ffiapi/nimlib/mylib.nim"

proc ffiExamplesBuildDir(): string =
  "examples/ffiapi/cmake-build"

proc buildFfiCmakeTarget(target = "") =
  let cmakeDir = "examples/ffiapi"
  let buildDir = ffiExamplesBuildDir()
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc ffiExampleExecutablePath(exampleDir: string): string =
  when defined(windows):
    joinPath(exampleDir, "build", "example.exe")
  else:
    joinPath(exampleDir, "build", "example")

proc test(env, path: string) =
  let outputPath = joinPath("build", path & "_" & compileVariantSuffix(env))
  exec "nim c " & env & " -r --path:src --out:" & quoteArg(outputPath) & " test/" & path &
    ".nim"

proc isExcludedNimPath(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized == "nimbledeps" or normalized == "vendor" or normalized == "doc" or
    normalized == "build" or normalized == ".venv" or normalized == ".git" or
    normalized.startsWith("nimbledeps/") or normalized.startsWith("vendor/") or
    normalized.startsWith("doc/") or normalized.startsWith("build/") or
    normalized.startsWith(".venv/") or normalized.startsWith(".git/") or
    normalized.startsWith("./nimbledeps/") or normalized.startsWith("./vendor/") or
    normalized.startsWith("./doc/") or normalized.startsWith("./build/") or
    normalized.startsWith("./.venv/") or normalized.startsWith("./.git/")

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

proc collectNimFiles(dir: string, files: var seq[string]) =
  for kind, path in walkDir(dir, relative = true):
    let fullPath =
      if dir == ".":
        path
      else:
        joinPath(dir, path)
    let normalized = fullPath.replace('\\', '/')
    case kind
    of pcDir:
      if not isExcludedNimPath(normalized):
        collectNimFiles(normalized, files)
    of pcFile, pcLinkToFile:
      if isNphFile(normalized) and not isExcludedNimPath(normalized):
        files.add(normalized)
    else:
      discard

proc allNimFiles(): seq[string] =
  collectNimFiles(".", result)

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
  let apiTests =
    ["test_api_request_broker", "test_api_event_broker", "test_api_library_init"]
  for f in apiTests:
    for opt in [
      "-d:BrokerFfiApi --mm:orc --threads:on", "-d:BrokerFfiApi --mm:refc --threads:on",
      "-d:BrokerFfiApi -d:release --mm:orc --threads:on",
      "-d:BrokerFfiApi -d:release --mm:refc --threads:on",
    ]:
      let extraOpt =
        if f == "test_api_library_init": " --nimMainPrefix:apitestlib" else: ""
      test opt & extraOpt, f

task buildFfiExample, "Build FFI API example library":
  buildFfiExampleLibrary()

task buildFfiExamplePy, "Build FFI API example library with generated Python wrapper":
  buildFfiExampleLibrary(true)

task buildFfiExamples, "Build FFI API examples — C and C++ applications (via CMake)":
  buildFfiCmakeTarget()

task buildFfiExampleC, "Build FFI API example — pure C application (via CMake)":
  buildFfiCmakeTarget("example_c")

task buildFfiExampleCpp, "Build FFI API example — modern C++ application (via CMake)":
  buildFfiCmakeTarget("example_cpp")

task runFfiExampleC, "Build and run the pure C FFI example application":
  buildFfiExampleLibrary()
  buildFfiCmakeTarget("example_c")
  exec quoteArg(ffiExampleExecutablePath("examples/ffiapi/example"))

task runFfiExampleCpp, "Build and run the modern C++ FFI example application":
  buildFfiExampleLibrary()
  buildFfiCmakeTarget("example_cpp")
  exec quoteArg(ffiExampleExecutablePath("examples/ffiapi/cpp_example"))

task runFfiExamplePy, "Build and run the Python wrapper example application":
  buildFfiExampleLibrary(true)
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("examples/ffiapi/python_example/main.py")

proc buildPyTestLibrary(mm: string = "orc", release: bool = false) =
  var flags =
    "-d:BrokerFfiApi -d:BrokerFfiApiGenPy --threads:on --app:lib --mm:" & mm &
    " --nimMainPrefix:pytestlib --path:src --outdir:test/pytestlib/build"
  if release:
    flags.add(" -d:release")
  exec "nim c " & flags & " test/pytestlib/pytestlib.nim"

proc soElfBits(soPath: string): int =
  ## Returns 32 or 64 for the ELF class of soPath, or 0 if it cannot be
  ## determined (e.g. non-Linux, file tool absent).
  let (info, rc) = gorgeEx("file " & quoteArg(soPath))
  if rc != 0:
    return 0
  if "ELF 64-bit" in info:
    return 64
  if "ELF 32-bit" in info:
    return 32
  return 0

proc pythonExeBits(exe: string): int =
  ## Returns 32 or 64 for the pointer width of the given Python interpreter,
  ## or 0 on failure.
  let (output, rc) =
    gorgeEx(exe & " -c \"import struct; print(struct.calcsize('P') * 8)\"")
  if rc != 0:
    return 0
  try:
    return parseInt(output.strip())
  except ValueError:
    return 0

proc findPythonForBits(wantBits: int): string =
  ## Return the path of the first Python interpreter whose pointer width equals
  ## wantBits (32 or 64).  Returns "" when none is found.
  ## Checks the obvious names/paths in order; extend the list as needed.
  let candidates = [
    findExe("python3"),
    findExe("python"),
    "/usr/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python",
    "/usr/local/bin/python",
  ]
  for c in candidates:
    if c.len > 0 and pythonExeBits(c) == wantBits:
      return c
  return ""

task buildPyTestLib, "Build the Python binding test library":
  buildPyTestLibrary()

task testFfiApi,
  "Build and run the Python FFI API binding tests (orc/refc × debug/release)":
  for mm in ["orc", "refc"]:
    for release in [false, true]:
      let mode = if release: "release" else: "debug"
      echo "\n=== testFfiApi (mm:" & mm & " " & mode & ") ==="
      buildPyTestLibrary(mm, release)
      let bits = soElfBits("test/pytestlib/build/libpytestlib.so")
      # When ELF inspection is unavailable (bits == 0) fall back to the default
      # Python and let ctypes report any mismatch itself.
      let python =
        if bits == 0:
          findPythonExe()
        else:
          findPythonForBits(bits)
      if python.len == 0:
        echo "Skipping Python tests: no " & $bits &
          "-bit Python interpreter found to match the compiled .so."
        continue
      exec quoteArg(python) & " -m unittest discover -s test/pytestlib -p " &
        quoteArg("test_*.py") & " -v"

task nph, "Install nph if needed and format modified Nim files":
  runNph(changedNimFiles(), "No modified .nim or .nimble files to format")

task nphall, "Install nph if needed and format all Nim files in the project":
  runNph(allNimFiles(), "No .nim or .nimble files found to format")
