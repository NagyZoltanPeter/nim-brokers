import std/[os, strutils]

# Package
version = "3.0.0"
author = "Nagy Zoltan Peter"
description =
  "Type-safe, decoupled messaging patterns for Nim / single thread, cross-thread and FFI API support!"
license = "MIT"
skipDirs = @["tests", "examples", "tools"]

# Dependencies
requires "nim >= 2.2.4"
requires "chronos >= 4.0.0"
requires "results >= 0.5.0"
requires "chronicles >= 0.10.0"
requires "testutils >= 0.5.0"
requires "cbor_serialization >= 0.3.0"

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

proc nimMainPrefixFlag(prefix: string): string =
  ## Returns "--nimMainPrefix:<prefix>" on POSIX and "" on Windows.
  ##
  ## --nimMainPrefix is a POSIX-only concern.  On POSIX, dlopen with
  ## RTLD_GLOBAL merges all shared-object exports into a single flat namespace,
  ## so two Nim .so files that both define NimMain collide; the prefix renames
  ## them (e.g. fooNimMain, barNimMain) to prevent that.
  ##
  ## On Windows the PE loader resolves every import as "DLL!Symbol", giving
  ## each DLL its own isolated namespace — foo.dll!NimMain and bar.dll!NimMain
  ## never clash, so the prefix is unnecessary.
  ##
  ## Using --nimMainPrefix on Windows also triggers a Nim codegen bug:
  ## the C generator forward-declares the prefixed NimMain without
  ## __declspec(dllexport) and then defines it with N_LIB_EXPORT, which both
  ## clang and GCC reject as a hard error (err_attribute_dll_redeclaration).
  when defined(windows):
    result = ""
  else:
    result = " --nimMainPrefix:" & prefix

proc nimWindowsCcFlag(): string =
  ## On Windows we standardize FFI builds on clang. Nim's default cc on
  ## Windows is MinGW gcc (msvcrt.dll), but the C/C++ side is built by
  ## cmake via Visual Studio + MSVC by default (ucrt.dll). Mixing two CRTs
  ## across the DLL boundary causes heap/stdio/TLS mismatches that surface
  ## as random crashes at process teardown. Forcing clang on the Nim side
  ## keeps both halves on a single CRT (MinGW msvcrt or release UCRT,
  ## depending on which clang the runner ships).
  when defined(windows): " --cc:clang" else: ""

proc nimWindowsImplibFlag(outDir, libName: string): string =
  ## Force lld to emit an import library at a known path next to the DLL.
  ##
  ## clang in gnu-driver mode (the only mode available when the runner
  ## ships MinGW-bundled clang under external/mingw-amd64/bin) defaults
  ## to ld.lld in gnu-mode, which does NOT auto-emit any import library.
  ## The cmake consumer then fails with "ninja: error: '<libName>.lib'
  ## missing and no known rule to make it" because our IMPORTED_IMPLIB
  ## cmake property points at that path.
  ##
  ## Passing `-Wl,--out-implib=<path>` makes lld write a gnu-format
  ## import library at the requested path. The file extension is purely
  ## conventional — we keep `.lib` so that the cmake IMPORTED_IMPLIB
  ## paths stay uniform across asan (MSVC-format .lib) and non-asan
  ## (gnu-format .lib) builds. Both formats are accepted by clang+lld
  ## consumers in gnu-driver mode.
  when defined(windows):
    " --passL:-Wl,--out-implib=" & outDir & "/" & libName & ".lib"
  else:
    ""

proc skipRefcOnWindows(opt, label: string): bool =
  ## Returns true (and prints a skip notice) when `opt` requests --mm:refc on
  ## Windows. See README → "Platform Support" + "Known Limitations" for the
  ## reasoning: chronos' Win32 RegisterWaitForSingleObject path fires its
  ## completion on a thread-pool thread that the refc stop-the-world GC
  ## cannot suspend, leading to use-after-free on
  ## ThreadSignalPtr/Channel-driven workloads. This affects every layer that
  ## relies on the cross-thread signal infrastructure: MT brokers, the FFI
  ## API runtime and all FFI tests. ORC's atomic refcounting has no STW
  ## phase, so the same code is safe under --mm:orc.
  when defined(windows):
    if "--mm:refc" in opt or "refc" == opt:
      echo "Skipping " & label & " (" & opt &
        ") on Windows: refc + chronos thread-pool callback is unsafe — use --mm:orc."
      return true
  false

proc cmakeWindowsConfigureExtras(): string =
  ## On Windows we drive cmake with Ninja + clang/clang++ + lld, pin the
  ## release UCRT and select RelWithDebInfo. The default Visual Studio
  ## generator ignores CMAKE_*_COMPILER for the toolset and pulls in MSVC
  ## link.exe + the debug UCRT for Debug configs — both incompatible with
  ## the clang-built Nim DLLs.
  when defined(windows):
    " -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++" &
      " -DCMAKE_LINKER_TYPE=LLD -DCMAKE_BUILD_TYPE=RelWithDebInfo" &
      " -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
  else:
    ""

# FFI build of mylib.nim, emitting into nimlib/build/. Drives the
# C++ example through the generated mylib.h / mylib.hpp.
proc buildFfiExampleFlags(
    generatePy = false, generateRust = false, generateGo = false
): string =
  result =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. --outdir:examples/ffiapi/nimlib/build"
  result.add(nimMainPrefixFlag("mylib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/ffiapi/nimlib/build", "mylib"))
  if existsEnv("MM"):
    result.add(" --mm:" & getEnv("MM"))
  else:
    result.add(" --mm:orc")
  if generatePy or existsEnv("GEN_PY"):
    result.add(" -d:BrokerFfiApiGenPy")
  if generateRust or existsEnv("GEN_RUST"):
    result.add(" -d:BrokerFfiApiGenRust")
  if generateGo or existsEnv("GEN_GO"):
    result.add(" -d:BrokerFfiApiGenGo")

proc buildFfiExampleLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  exec "nim c " & buildFfiExampleFlags(generatePy, generateRust, generateGo) &
    " examples/ffiapi/nimlib/mylib.nim"

proc buildTorpedoExampleFlags(
    generatePy = false, generateRust = false, generateGo = false
): string =
  result =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. --outdir:examples/torpedo/nimlib/build"
  result.add(nimMainPrefixFlag("torpedolib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/torpedo/nimlib/build", "torpedolib"))
  if existsEnv("MM"):
    result.add(" --mm:" & getEnv("MM"))
  else:
    result.add(" --mm:orc")
  if generatePy or existsEnv("GEN_PY"):
    result.add(" -d:BrokerFfiApiGenPy")
  if generateRust or existsEnv("GEN_RUST"):
    result.add(" -d:BrokerFfiApiGenRust")
  if generateGo or existsEnv("GEN_GO"):
    result.add(" -d:BrokerFfiApiGenGo")

proc buildTorpedoExampleLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  exec "nim c " & buildTorpedoExampleFlags(generatePy, generateRust, generateGo) &
    " examples/torpedo/nimlib/torpedolib.nim"

proc ffiExamplesBuildDir(): string =
  "examples/ffiapi/cmake-build"

proc buildFfiCmakeTarget(target = "") =
  let cmakeDir = "examples/ffiapi"
  let buildDir = ffiExamplesBuildDir()
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cmakeWindowsConfigureExtras()
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc ffiExampleExecutablePath(exampleDir: string): string =
  when defined(windows):
    joinPath(exampleDir, "build", "example.exe")
  else:
    joinPath(exampleDir, "build", "example")

proc torpedoCmakeBuildDir(): string =
  "examples/torpedo/cmake-build"

proc buildTorpedoCmakeTarget(target = "") =
  let cmakeDir = "examples/torpedo"
  let buildDir = torpedoCmakeBuildDir()
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cmakeWindowsConfigureExtras()
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc torpedoExecutablePath(): string =
  when defined(windows):
    joinPath("examples", "torpedo", "cpp_example", "build", "torpedo.exe")
  else:
    joinPath("examples", "torpedo", "cpp_example", "build", "torpedo")

proc test(env, path: string) =
  let outputPath =
    joinPath("build", path & "_" & compileVariantSuffix(env)).addFileExt(ExeExt)
  let label = path & " [" & env & "]"
  exec "nim c " & env & " --path:. --out:" & quoteArg(outputPath) & " test/" & path &
    ".nim"
  echo "=== RUN  " & label & " ==="
  # Use exec (live stdout+stderr) instead of gorgeEx so a SIGSEGV / runtime
  # abort that fires before the buffered output is flushed still surfaces
  # its Nim stack trace to the CI log. gorgeEx captured stdout only and
  # printed it after the binary exited, which loses any backtrace the Nim
  # runtime writes to stderr at crash time.
  exec quoteArg(outputPath)
  echo "=== PASS " & label & " ==="

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

task fetchVendor, "Initialize/update vendored third-party dependencies (git submodules)":
  ## Fetches the third-party C/C++ dependencies required by the FFI
  ## builds (currently jsoncons under vendor/jsoncons). Safe to run repeatedly.
  if not dirExists(".git"):
    quit "fetchVendor must be run from a git checkout (no .git directory found)."
  exec "git submodule update --init --recursive vendor"

task test, "Run all single and multi-threaded broker tests":
  let tests = ["test_event_broker", "test_request_broker", "test_multi_request_broker"]
  for f in tests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release -d:gcAssert -d:sysAssert --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release -d:gcAssert -d:sysAssert --mm:refc",
    ]:
      test opt, f

  let mtTests = [
    "test_multi_thread_request_broker", "test_multi_thread_event_broker",
    "test_multi_thread_broker_configs",
  ]
  for f in mtTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc --threads:on",
    ]:
      if skipRefcOnWindows(opt, f):
        continue
      test opt, f

task runFfiBenchEventStress,
  "Build benchlib  + the Part D-4/D-5 event dispatch stress drivers and run them":
  # Build the benchlib shared library into test/ffibench/build/.
  exec "nim c -d:BrokerFfiApi --threads:on --app:lib --path:. " &
    "--outdir:test/ffibench/build --mm:orc " &
    "--nimMainPrefix:benchlib test/ffibench/benchlib.nim"
  # Configure + build the five event-stress drivers via the existing CMake project.
  mkDir("test/ffibench/cmake-build")
  exec "cmake -S test/ffibench -B test/ffibench/cmake-build"
  exec "cmake --build test/ffibench/cmake-build " &
    "--target stress_event_mixed_audience " & "--target stress_event_no_foreign " &
    "--target stress_event_no_nim " & "--target stress_event_shutdown " &
    "--target stress_event_slow_callback"
  # Run each in sequence; non-zero exit propagates through `exec`.
  exec "test/ffibench/build/stress_event_mixed_audience"
  exec "test/ffibench/build/stress_event_no_foreign"
  exec "test/ffibench/build/stress_event_no_nim"
  exec "test/ffibench/build/stress_event_shutdown"
  exec "test/ffibench/build/stress_event_slow_callback"

proc runFfiBenchEventStressAsanFor(mm: string) =
  ## Build benchlib + the Part D-4/D-5 drivers with AddressSanitizer
  ## under the requested memory manager (`orc` or `refc`) and run all
  ## five drivers. The Nim library carries the sanitizer instrumentation
  ## via -fsanitize=address + -d:useMalloc; the CMake project picks up
  ## ASAN via -DASAN=ON. Pass = no driver exits non-zero AND no
  ## sanitizer report aborts the process.
  let buildDir = "test/ffibench/build_asan"
  let cmakeDir = "test/ffibench/cmake-build-asan"
  exec "nim c -d:BrokerFfiApi --threads:on --app:lib --path:. " & "--outdir:" & buildDir &
    " --mm:" & mm & " " & "--nimMainPrefix:benchlib -d:useMalloc " &
    "--passC:-fsanitize=address --passC:-fno-omit-frame-pointer " &
    "--passL:-fsanitize=address --debugger:native " & "test/ffibench/benchlib.nim"
  mkDir(cmakeDir)
  let absBuildDir = thisDir() & "/" & buildDir
  exec "cmake -S test/ffibench -B " & cmakeDir & " -DASAN=ON -DBENCH_DIR=" &
    quoteArg(absBuildDir)
  exec "cmake --build " & cmakeDir & " --target stress_event_mixed_audience " &
    "--target stress_event_no_foreign " & "--target stress_event_no_nim " &
    "--target stress_event_shutdown " & "--target stress_event_slow_callback"
  exec buildDir & "/stress_event_mixed_audience"
  exec buildDir & "/stress_event_no_foreign"
  exec buildDir & "/stress_event_no_nim"
  exec buildDir & "/stress_event_shutdown"
  exec buildDir & "/stress_event_slow_callback"

task runFfiBenchEventStressAsan,
  "Run the Part D-4/D-5 event dispatch stress drivers under AddressSanitizer (orc + refc)":
  runFfiBenchEventStressAsanFor("orc")
  runFfiBenchEventStressAsanFor("refc")

task runFfiBenchEvent,
  "Build benchlib (release/orc) + bench_event_driver and run it":
  ## Part D-6 — captures the per-emit cost across four scenarios:
  ##   (a) no foreign subs, no nim listeners — atomic-counter fast path
  ##   (b) 1 foreign subscriber             — full courier path
  ##   (c) M foreign subscribers            — encode-amortize-fanout
  ##   (d) K same-thread Nim listeners      — Lane 1 cost in isolation
  ## Output is CSV on stdout; numbers are captured in doc/bench_baseline.md.
  exec "nim c -d:release -d:BrokerFfiApi --threads:on --app:lib --path:. " &
    "--outdir:test/ffibench/build --mm:orc " &
    "--nimMainPrefix:benchlib test/ffibench/benchlib.nim"
  mkDir("test/ffibench/cmake-build")
  exec "cmake -S test/ffibench -B test/ffibench/cmake-build " &
    "-DCMAKE_BUILD_TYPE=Release"
  exec "cmake --build test/ffibench/cmake-build --target bench_event_driver"
  exec "test/ffibench/build/bench_event_driver"

task perftest, "Run performance and stress tests":
  let mtTests =
    ["perf_test_multi_thread_request_broker", "perf_test_multi_thread_event_broker"]
  for f in mtTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc --threads:on",
    ]:
      if skipRefcOnWindows(opt, f):
        continue
      test opt, f

task testApi, "Run codec unit tests + library init integration tests":
  # Codec round-trip tests (no FFI flags needed).
  let codecTests = ["test_api_codec"]
  for f in codecTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc",
    ]:
      test opt, f

  # Library-init integration tests need the FFI runtime.
  # Each test uses a different --nimMainPrefix to keep their generated
  # NimMain symbols distinct.
  let apiTests = [
    ("test_api_library_init", "apitest"),
    ("test_api_discovery", "apidisc"),
    ("typemappingtestlib/test_typemappingtestlib", "typemappingtestlib"),
  ]
  for (f, prefix) in apiTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:release --mm:refc --threads:on",
    ]:
      if skipRefcOnWindows(opt, f):
        continue
      let extraOpt = nimMainPrefixFlag(prefix)
      test opt & extraOpt, f

proc findCargoExe(): string =
  ## Returns the cargo invocation token. Resolving the symlink (rustup
  ## multi-call binary on most installs) loses the dispatch hint, so we
  ## return the bare name and rely on PATH lookup at exec time.
  if findExe("cargo").len == 0:
    quit "Cargo (Rust toolchain) not found. Install rustup or add cargo to PATH."
  result = "cargo"

task runFfiExampleRust, "Build the FFI API example library ":
  buildFfiExampleLibrary(generateRust = true)
  exec quoteArg(findCargoExe()) &
    " run --manifest-path examples/ffiapi/rust_example/Cargo.toml"

proc findGoExe(): string =
  ## Returns the `go` toolchain invocation token. Like cargo via rustup,
  ## we rely on PATH lookup at exec time so the user's installed Go is used.
  if findExe("go").len == 0:
    quit "Go toolchain not found. Install Go 1.21+ or add `go` to PATH."
  result = "go"

proc writeFfiGoModFor(buildDir: string) =
  ## The generated Go module is emitted into either `nimlib/build/mylib_go`
  ## or `nimlib/build/mylib_go`. Go can't conditionally pick a
  ## `replace` target by build tag, so we rewrite the example's go.mod
  ## per mode before invoking the Go toolchain.
  let modPath = "examples/ffiapi/go_example/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add("module github.com/status-im/nim-brokers/examples/ffiapi/go_example\n\n")
  contents.add("go 1.21\n\n")
  contents.add("require mylib v0.0.0\n")
  if buildDir == "build":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add("\nreplace mylib => ../nimlib/" & buildDir & "/mylib_go\n")
  writeFile(modPath, contents)
  # Sync go.sum + transitive deps for the cbor case.
  if buildDir == "build":
    withDir "examples/ffiapi/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"

task buildFfiExampleGo,
  "Build the FFI API example library  + generated Go wrapper":
  buildFfiExampleLibrary(generateGo = true)

task runFfiExampleGo,
  "Build the FFI API example library  + run the Go example":
  buildFfiExampleLibrary(generateGo = true)
  writeFfiGoModFor("build")
  withDir "examples/ffiapi/go_example":
    exec quoteArg(findGoExe()) & " run ."

# ---------------------------------------------------------------------------
# FFI build of mylib.nim + the same cpp_example/main.cpp.
# ---------------------------------------------------------------------------

task buildFfiExample,
  "Build FFI API example library (into nimlib/build)":
  buildFfiExampleLibrary()

task buildFfiExampleCpp,
  "Build FFI API example — C++ application against the library (via CMake)":
  buildFfiExampleLibrary()
  buildFfiCmakeTarget("example_cpp")

task runFfiExampleCpp,
  "Build and run the C++ FFI example application against the library":
  buildFfiExampleLibrary()
  buildFfiCmakeTarget("example_cpp")
  exec quoteArg(ffiExampleExecutablePath("examples/ffiapi/cpp_example"))

task runFfiExamplePy,
  "Build the FFI example library + Python wrapper and run the SAME python_example/main.py against it":
  buildFfiExampleLibrary(true)
  putEnv("MYLIB_BUILD_DIR", "build")
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("examples/ffiapi/python_example/main.py")

# FFI build of the typemapping test library: compiles
# test/typemappingtestlib/typemappingtestlib.nim with -d:BrokerFfiApi
# into build/ and drives test_typemappingtestlib.{cpp,py} against
# that build.
proc buildTypeMapTestLib(
    genPy: bool = false, genRust: bool = false, genGo: bool = false
) =
  let mm =
    if existsEnv("MM"):
      getEnv("MM")
    else:
      "orc"
  let release = existsEnv("RELEASE")
  var flags =
    "-d:BrokerFfiApi --threads:on --app:lib --mm:" & mm &
    " --path:. --outdir:test/typemappingtestlib/build"
  flags.add(nimMainPrefixFlag("typemappingtestlib"))
  flags.add(nimWindowsCcFlag())
  flags.add(
    nimWindowsImplibFlag("test/typemappingtestlib/build", "typemappingtestlib")
  )
  if release:
    flags.add(" -d:release")
  if genPy:
    flags.add(" -d:BrokerFfiApiGenPy")
  if genRust or existsEnv("GEN_RUST"):
    flags.add(" -d:BrokerFfiApiGenRust")
  if genGo or existsEnv("GEN_GO"):
    flags.add(" -d:BrokerFfiApiGenGo")
  exec "nim c " & flags & " test/typemappingtestlib/typemappingtestlib.nim"

task buildTypeMapTestLib, "Build the type-mapping parity test library":
  buildTypeMapTestLib()

proc typeMapTestLibCmakeDir(): string =
  "test/typemappingtestlib/cmake-build"

task runTypeMapTestLibCpp,
  "Build the parity library + run the C++ parity test against it":
  buildTypeMapTestLib()
  let cmakeDir = typeMapTestLibCmakeDir()
  let srcDir = "test/typemappingtestlib"
  exec "cmake -S " & quoteArg(srcDir) & " -B " & quoteArg(cmakeDir) &
    cmakeWindowsConfigureExtras()
  exec "cmake --build " & quoteArg(cmakeDir)
  exec quoteArg("test/typemappingtestlib/build/test_typemappingtestlib")

task runTypeMapTestLibRust,
  "Build the parity library + Rust wrapper and run the Rust parity test":
  buildTypeMapTestLib(genRust = true)
  exec quoteArg(findCargoExe()) &
    " run --manifest-path test/typemappingtestlib/rust_test/Cargo.toml"

proc writeTypeMapGoModFor(buildDir: string) =
  let modPath = "test/typemappingtestlib/go_test/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add(
    "module github.com/status-im/nim-brokers/test/typemappingtestlib/go_test\n\n"
  )
  contents.add("go 1.21\n\n")
  contents.add("require typemappingtestlib v0.0.0\n")
  if buildDir == "build":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add(
    "\nreplace typemappingtestlib => ../" & buildDir & "/typemappingtestlib_go\n"
  )
  writeFile(modPath, contents)
  if buildDir == "build":
    withDir "test/typemappingtestlib/go_test":
      exec quoteArg(findGoExe()) & " mod tidy"

task runTypeMapTestLibGo,
  "Build the parity library + Go wrapper and run the Go parity test":
  buildTypeMapTestLib(genGo = true)
  writeTypeMapGoModFor("build")
  withDir "test/typemappingtestlib/go_test":
    exec quoteArg(findGoExe()) & " run ."

task runTypeMapTestLibPy,
  "Build the parity library + Python wrapper and run the unified Python parity test against it":
  buildTypeMapTestLib(true)
  # The test_typemappingtestlib.py driver runs against the FFI
  # builds; selection is via TYPEMAP_BUILD_DIR which points at the
  # build output that holds the matching generated .py wrapper.
  putEnv("TYPEMAP_BUILD_DIR", "build")
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("test/typemappingtestlib/test_typemappingtestlib.py")

proc setAsanEnv() =
  putEnv("MallocNanoZone", "0")
  putEnv(
    "ASAN_OPTIONS",
    "detect_leaks=0:symbolize=1:print_stacktrace=1:halt_on_error=1:abort_on_error=0:strict_string_checks=1",
  )
  if not existsEnv("ASAN_SYMBOLIZER_PATH"):
    let llvmSym = findExe("llvm-symbolizer")
    if llvmSym.len > 0:
      putEnv("ASAN_SYMBOLIZER_PATH", llvmSym)
  when defined(linux):
    # The Nim .so links -shared-libasan, so the loader needs libclang_rt.asan-*.so
    # on LD_LIBRARY_PATH. The C++ test exe is linked with plain -fsanitize=address
    # (static asan on Linux) and otherwise can't satisfy the .so's runtime dep.
    let (so, rc) = gorgeEx("clang -print-file-name=libclang_rt.asan-x86_64.so")
    let trimmed = so.strip()
    if rc == 0 and trimmed.len > 0 and trimmed != "libclang_rt.asan-x86_64.so":
      let dir = parentDir(trimmed)
      let cur = getEnv("LD_LIBRARY_PATH")
      putEnv(
        "LD_LIBRARY_PATH",
        if cur.len == 0:
          dir
        else:
          dir & ":" & cur,
      )

proc asanCompileFlags(): string =
  result = "-fsanitize=address -fno-omit-frame-pointer -g"
  when defined(windows):
    # Windows ASAN symbolizes via PDB (CodeView), not DWARF.
    result.add(" -gcodeview")

proc asanLinkFlags(sharedLib: bool = false): string =
  result = "-fsanitize=address -g"
  when defined(linux):
    if sharedLib:
      result.add(" -shared-libasan")
  when defined(windows):
    # Tell lld to emit a PDB so ASAN frames carry function/line info.
    result.add(" -Wl,/debug")

proc testAsan(mm: string, path: string) =
  let outputPath = joinPath("build", path & "_asan_" & mm).addFileExt(ExeExt)
  let label = path & " [ASAN, clang, mm:" & mm & ", debug]"
  # -d:noSignalHandler: disable Nim's SIGSEGV handler so ASAN's signal handler
  # fires on memory faults. Without this, Nim prints its own traceback and
  # exits before ASAN can report the underlying heap error.
  let flags =
    "--cc:clang --debugger:native -d:nimUnittestOutputLevel:VERBOSE -d:noSignalHandler --threads:on --mm:" &
    mm & " --passC:" & quoteArg(asanCompileFlags()) & " --passL:" &
    quoteArg(asanLinkFlags()) & " --path:. --out:" & quoteArg(outputPath)
  exec "nim c " & flags & " test/" & path & ".nim"
  setAsanEnv()
  echo "=== RUN  " & label & " ==="
  exec quoteArg(outputPath)
  echo "=== PASS " & label & " ==="

task testMtEventBrokerAsanOrc,
  "Run multi-thread event broker tests under AddressSanitizer (clang, orc, debug)":
  testAsan("orc", "test_multi_thread_event_broker")

task testMtEventBrokerAsanRefc,
  "Run multi-thread event broker tests under AddressSanitizer (clang, refc, debug)":
  if skipRefcOnWindows("refc", "testMtEventBrokerAsanRefc"):
    return
  testAsan("refc", "test_multi_thread_event_broker")

task testMtRequestBrokerAsanOrc,
  "Run multi-thread request broker tests under AddressSanitizer (clang, orc, debug)":
  testAsan("orc", "test_multi_thread_request_broker")

task testMtRequestBrokerAsanRefc,
  "Run multi-thread request broker tests under AddressSanitizer (clang, refc, debug)":
  if skipRefcOnWindows("refc", "testMtRequestBrokerAsanRefc"):
    return
  testAsan("refc", "test_multi_thread_request_broker")

task testMtBrokerConfigsAsanOrc,
  "Run multi-thread broker config showcase under AddressSanitizer (clang, orc, debug)":
  testAsan("orc", "test_multi_thread_broker_configs")

task testMtBrokerConfigsAsanRefc,
  "Run multi-thread broker config showcase under AddressSanitizer (clang, refc, debug)":
  if skipRefcOnWindows("refc", "testMtBrokerConfigsAsanRefc"):
    return
  testAsan("refc", "test_multi_thread_broker_configs")

# ----------------------------------------------------------------------------
# probeWinTlsUninit — minimal repro for LIMITATION.md §2.1
# ----------------------------------------------------------------------------
# Demonstrates that a Win32 RegisterWaitForSingleObject completion callback
# allocating Nim memory crashes under --mm:refc on Windows (uninitialized TLS
# on the NT thread-pool wait thread) and passes under --mm:orc. No chronos,
# no brokers — see test/probe_win_tls_uninit.nim for full discussion.
#
# Expected exit codes:
#   * Non-Windows hosts             → 77 (skip)
#   * Windows + orc                 → 0
#   * Windows + refc                → non-zero (crash); task asserts this and
#                                     exits 0 to signal "hypothesis reproduced".
proc runProbeWinTlsUninit(mm: string) =
  let outBin = "build" / ("probe_win_tls_uninit_" & mm)
  let outBinExe =
    when defined(windows):
      outBin & ".exe"
    else:
      outBin
  mkDir "build"
  # `--out:` with a path overrides `--outdir:`, so put the path directly on
  # `--out:` to land the binary under build/.
  exec "nim c --threads:on --mm:" & mm & " -d:release " & "--out:" & quoteArg(outBin) &
    " " & quoteArg("test/probe_win_tls_uninit.nim")
  # Run the probe with live stdout+stderr (exec) so a refc crash's Nim/OS
  # backtrace lands in the CI log. exec raises OSError on non-zero exit; we
  # use that to distinguish "exit 0" from "exit non-zero / crash".
  var exitedNonZero = false
  try:
    exec quoteArg(outBinExe)
  except OSError:
    exitedNonZero = true
  when defined(windows):
    if mm == "orc":
      if exitedNonZero:
        echo "::error::probeWinTlsUninit/orc: probe must succeed under ORC"
        quit(1)
      echo "probeWinTlsUninit/orc: PASS"
    else:
      # refc on Windows: we *expect* the probe to crash. If it exits 0, the
      # §2.1 hypothesis no longer reproduces and the doc needs revisiting.
      if not exitedNonZero:
        echo "::warning::probeWinTlsUninit/refc exited 0 — §2.1 hypothesis " &
          "no longer reproduces. Review doc/LIMITATION.md §2.1."
        quit(1)
      echo "probeWinTlsUninit/refc: hypothesis reproduced (probe crashed " &
        "as expected)"
  else:
    # Non-Windows hosts: probe exits 77 (skip). exec sees that as non-zero
    # → OSError → exitedNonZero=true is the success path here.
    if not exitedNonZero:
      echo "::error::probeWinTlsUninit on non-Windows: expected skip exit"
      quit(1)
    echo "probeWinTlsUninit: skipped (non-Windows host)"

task probeWinTlsUninitOrc,
  "Run the §2.1 TLS-uninit probe under --mm:orc (must pass on Windows)":
  runProbeWinTlsUninit("orc")

task probeWinTlsUninitRefc,
  "Run the §2.1 TLS-uninit probe under --mm:refc (expected to crash on Windows)":
  runProbeWinTlsUninit("refc")

task runTorpedoExampleRust, "Build the Torpedo Duel FFI library ":
  buildTorpedoExampleLibrary(generateRust = true)
  exec quoteArg(findCargoExe()) &
    " run --manifest-path examples/torpedo/rust_example/Cargo.toml"

proc writeTorpedoGoModFor(buildDir: string) =
  let modPath = "examples/torpedo/go_example/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add(
    "module github.com/status-im/nim-brokers/examples/torpedo/go_example\n\n"
  )
  contents.add("go 1.21\n\n")
  contents.add("require torpedolib v0.0.0\n")
  if buildDir == "build":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add("\nreplace torpedolib => ../nimlib/" & buildDir & "/torpedolib_go\n")
  writeFile(modPath, contents)
  if buildDir == "build":
    withDir "examples/torpedo/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"

task runTorpedoExampleGo,
  "Build the Torpedo Duel FFI library  + run the Go example":
  buildTorpedoExampleLibrary(generateGo = true)
  writeTorpedoGoModFor("build")
  withDir "examples/torpedo/go_example":
    exec quoteArg(findGoExe()) & " run ."

# FFI build of the torpedo example. Same torpedolib.nim source +
# same cpp_example/main.cpp, compiled against the FFI codegen output.
task buildTorpedoExample,
  "Build the torpedo FFI example library (into nimlib/build)":
  buildTorpedoExampleLibrary()

task buildTorpedoExampleCpp,
  "Build the Torpedo Duel C++ application against the library (via CMake)":
  buildTorpedoExampleLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp")

task runTorpedoExampleCpp,
  "Build and run the Torpedo Duel C++ text UI example against the library":
  buildTorpedoExampleLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp")
  exec quoteArg(torpedoExecutablePath())

task runTorpedoExamplePy,
  "Build the torpedo library + Python wrapper and run the SAME python_example/main.py against it":
  buildTorpedoExampleLibrary(true)
  putEnv("TORPEDOLIB_BUILD_DIR", "build")
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("examples/torpedo/python_example/main.py")

task nph, "Install nph if needed and format modified Nim files":
  runNph(changedNimFiles(), "No modified .nim or .nimble files to format")

task nphall, "Install nph if needed and format all Nim files in the project":
  runNph(allNimFiles(), "No .nim or .nimble files found to format")

task alltests,
  "Run every test suite: test, testApi, runFfiExampleCpp, runFfiExamplePy, runTypeMapTestLibCpp, runTypeMapTestLibPy":
  exec "nimble test"
  exec "nimble runFfiExampleCpp"
  exec "nimble runFfiExamplePy"
  exec "nimble testApi"
  exec "nimble runTypeMapTestLibCpp"
  exec "nimble runTypeMapTestLibPy"

task allAsan, "Run all tests under AddressSanitizer (clang, orc/refc, debug)":
  exec "nimble testMtEventBrokerAsanOrc"
  exec "nimble testMtEventBrokerAsanRefc"
  exec "nimble testMtRequestBrokerAsanOrc"
  exec "nimble testMtRequestBrokerAsanRefc"
