import std/[os, strutils]

# Package
version = "2.0.1"
author = "Nagy Zoltan Peter"
description =
  "Type-safe, decoupled messaging patterns for Nim / single thread, cross-thread and FFI API support!"
license = "MIT"
skipDirs = @["tests", "examples", "tools"]

# Dependencies
requires "nim >= 2.0.0"
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

# CBOR-mode build of mylib.nim, emitting into nimlib/build_cbor/. Drives the
# C++ example through the CBOR-generated mylib.h / mylib.hpp.
proc buildFfiExampleCborFlags(
    generatePy = false, generateRust = false, generateGo = false
): string =
  result =
    "-d:BrokerFfiApiCBOR --threads:on --app:lib --path:. --outdir:examples/ffiapi/nimlib/build_cbor"
  result.add(nimMainPrefixFlag("mylib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/ffiapi/nimlib/build_cbor", "mylib"))
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

proc buildFfiExampleCborLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  exec "nim c " & buildFfiExampleCborFlags(generatePy, generateRust, generateGo) &
    " examples/ffiapi/nimlib/mylib.nim"

proc buildTorpedoExampleCborFlags(
    generatePy = false, generateRust = false, generateGo = false
): string =
  result =
    "-d:BrokerFfiApiCBOR --threads:on --app:lib --path:. --outdir:examples/torpedo/nimlib/build_cbor"
  result.add(nimMainPrefixFlag("torpedolib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/torpedo/nimlib/build_cbor", "torpedolib"))
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

proc buildTorpedoExampleCborLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  exec "nim c " & buildTorpedoExampleCborFlags(generatePy, generateRust, generateGo) &
    " examples/torpedo/nimlib/torpedolib.nim"

proc ffiExamplesBuildDir(useCbor = false): string =
  if useCbor: "examples/ffiapi/cmake-build-cbor" else: "examples/ffiapi/cmake-build"

proc buildFfiCmakeTarget(target = "", useCbor = false) =
  let cmakeDir = "examples/ffiapi"
  let buildDir = ffiExamplesBuildDir(useCbor)
  mkDir(buildDir)
  let cborFlag = if useCbor: " -DUSE_CBOR=ON" else: ""
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cborFlag &
    cmakeWindowsConfigureExtras()
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc ffiExampleExecutablePath(exampleDir: string): string =
  when defined(windows):
    joinPath(exampleDir, "build", "example.exe")
  else:
    joinPath(exampleDir, "build", "example")

proc torpedoCmakeBuildDir(useCbor = false): string =
  if useCbor: "examples/torpedo/cmake-build-cbor" else: "examples/torpedo/cmake-build"

proc buildTorpedoCmakeTarget(target = "", useCbor = false) =
  let cmakeDir = "examples/torpedo"
  let buildDir = torpedoCmakeBuildDir(useCbor)
  mkDir(buildDir)
  let cborFlag = if useCbor: " -DUSE_CBOR=ON" else: ""
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cborFlag &
    cmakeWindowsConfigureExtras()
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
  ## Fetches the third-party C/C++ dependencies required by the CBOR-mode FFI
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

task testApiCbor, "Run CBOR codec unit tests + library init integration tests":
  # Codec round-trip tests (no FFI flags needed).
  let codecTests = ["test_api_cbor_codec"]
  for f in codecTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc",
    ]:
      test opt, f

  # Library-init integration tests need the CBOR FFI runtime. Each test
  # uses a different --nimMainPrefix to keep their generated NimMain
  # symbols distinct (mirrors the native testApi convention).
  let cborApiTests = [
    ("test_api_cbor_library_init", "cbtest"),
    ("test_api_cbor_discovery", "cbdisc"),
    ("typemappingtestlib/test_typemappingtestlib_cbor", "typemappingtestlib_cbor"),
  ]
  for (f, prefix) in cborApiTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApiCBOR --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApiCBOR --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApiCBOR -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApiCBOR -d:release --mm:refc --threads:on",
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

task runFfiExampleCborRust,
  "Build the FFI API example library (CBOR mode) + run the Rust example with --features cbor":
  buildFfiExampleCborLibrary(generateRust = true)
  exec quoteArg(findCargoExe()) &
    " run --features cbor --manifest-path examples/ffiapi/rust_example/Cargo.toml"

proc findGoExe(): string =
  ## Returns the `go` toolchain invocation token. Like cargo via rustup,
  ## we rely on PATH lookup at exec time so the user's installed Go is used.
  if findExe("go").len == 0:
    quit "Go toolchain not found. Install Go 1.21+ or add `go` to PATH."
  result = "go"

proc writeFfiGoModFor(buildDir: string) =
  ## The generated Go module is emitted into either `nimlib/build/mylib_go`
  ## or `nimlib/build_cbor/mylib_go`. Go can't conditionally pick a
  ## `replace` target by build tag, so we rewrite the example's go.mod
  ## per mode before invoking the Go toolchain.
  let modPath = "examples/ffiapi/go_example/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add("module github.com/status-im/nim-brokers/examples/ffiapi/go_example\n\n")
  contents.add("go 1.21\n\n")
  contents.add("require mylib v0.0.0\n")
  if buildDir == "build_cbor":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add("\nreplace mylib => ../nimlib/" & buildDir & "/mylib_go\n")
  writeFile(modPath, contents)
  # Sync go.sum + transitive deps for the cbor case.
  if buildDir == "build_cbor":
    withDir "examples/ffiapi/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"

task buildFfiExampleCborGo,
  "Build the FFI API example library (CBOR mode) + generated Go wrapper":
  buildFfiExampleCborLibrary(generateGo = true)

task runFfiExampleCborGo,
  "Build the FFI API example library (CBOR mode) + run the Go example":
  buildFfiExampleCborLibrary(generateGo = true)
  writeFfiGoModFor("build_cbor")
  withDir "examples/ffiapi/go_example":
    exec quoteArg(findGoExe()) & " run ."

# ---------------------------------------------------------------------------
# CBOR-mode build of mylib.nim + the same cpp_example/main.cpp.
# ---------------------------------------------------------------------------

task buildFfiExampleCbor,
  "Build FFI API example library (CBOR mode, into nimlib/build_cbor)":
  buildFfiExampleCborLibrary()

task buildFfiExampleCborCpp,
  "Build FFI API example — C++ application against the CBOR-mode library (via CMake)":
  buildFfiExampleCborLibrary()
  buildFfiCmakeTarget("example_cpp", useCbor = true)

task runFfiExampleCborCpp,
  "Build and run the C++ FFI example application against the CBOR-mode library":
  buildFfiExampleCborLibrary()
  buildFfiCmakeTarget("example_cpp", useCbor = true)
  exec quoteArg(ffiExampleExecutablePath("examples/ffiapi/cpp_example"))

task runFfiExampleCborPy,
  "Build the CBOR-mode FFI example library + Python wrapper and run the SAME python_example/main.py against it":
  buildFfiExampleCborLibrary(true)
  putEnv("MYLIB_BUILD_DIR", "build_cbor")
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("examples/ffiapi/python_example/main.py")

# CBOR-mode parity build of the typemapping test library: compiles the
# SAME test/typemappingtestlib/typemappingtestlib.nim source with
# -d:BrokerFfiApiCBOR into build_cbor/ and drives the SAME
# test_typemappingtestlib.{cpp,py} test code against that build (via the
# CMake project's USE_CBOR=ON toggle for C++).
proc buildTypeMapTestLibCbor(
    genPy: bool = false, genRust: bool = false, genGo: bool = false
) =
  let mm =
    if existsEnv("MM"):
      getEnv("MM")
    else:
      "orc"
  let release = existsEnv("RELEASE")
  var flags =
    "-d:BrokerFfiApiCBOR --threads:on --app:lib --mm:" & mm &
    " --path:. --outdir:test/typemappingtestlib/build_cbor"
  flags.add(nimMainPrefixFlag("typemappingtestlib"))
  flags.add(nimWindowsCcFlag())
  flags.add(
    nimWindowsImplibFlag("test/typemappingtestlib/build_cbor", "typemappingtestlib")
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

task buildTypeMapTestLibCbor, "Build the CBOR-mode type-mapping parity test library":
  buildTypeMapTestLibCbor()

proc typeMapTestLibCborCmakeDir(): string =
  "test/typemappingtestlib/cmake-build-cbor"

task runTypeMapTestLibCborCpp,
  "Build the CBOR-mode parity library + run the C++ parity test against it":
  buildTypeMapTestLibCbor()
  let cmakeDir = typeMapTestLibCborCmakeDir()
  let srcDir = "test/typemappingtestlib"
  exec "cmake -S " & quoteArg(srcDir) & " -B " & quoteArg(cmakeDir) & " -DUSE_CBOR=ON" &
    cmakeWindowsConfigureExtras()
  exec "cmake --build " & quoteArg(cmakeDir)
  exec quoteArg("test/typemappingtestlib/build_cbor/test_typemappingtestlib")

task runTypeMapTestLibCborRust,
  "Build the CBOR-mode parity library + Rust wrapper and run the Rust parity test":
  buildTypeMapTestLibCbor(genRust = true)
  exec quoteArg(findCargoExe()) &
    " run --features cbor --manifest-path test/typemappingtestlib/rust_test/Cargo.toml"

proc writeTypeMapGoModFor(buildDir: string) =
  let modPath = "test/typemappingtestlib/go_test/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add(
    "module github.com/status-im/nim-brokers/test/typemappingtestlib/go_test\n\n"
  )
  contents.add("go 1.21\n\n")
  contents.add("require typemappingtestlib v0.0.0\n")
  if buildDir == "build_cbor":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add(
    "\nreplace typemappingtestlib => ../" & buildDir & "/typemappingtestlib_go\n"
  )
  writeFile(modPath, contents)
  if buildDir == "build_cbor":
    withDir "test/typemappingtestlib/go_test":
      exec quoteArg(findGoExe()) & " mod tidy"

task runTypeMapTestLibCborGo,
  "Build the CBOR-mode parity library + Go wrapper and run the Go parity test":
  buildTypeMapTestLibCbor(genGo = true)
  writeTypeMapGoModFor("build_cbor")
  withDir "test/typemappingtestlib/go_test":
    exec quoteArg(findGoExe()) & " run ."

task runTypeMapTestLibCborPy,
  "Build the CBOR-mode parity library + Python wrapper and run the unified Python parity test against it":
  buildTypeMapTestLibCbor(true)
  # The same test_typemappingtestlib.py drives both native and CBOR
  # builds; selection is via TYPEMAP_BUILD_DIR which points at the
  # build output that holds the matching generated .py wrapper.
  putEnv("TYPEMAP_BUILD_DIR", "build_cbor")
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

task runTorpedoExampleCborRust,
  "Build the Torpedo Duel FFI library (CBOR mode) + run the Rust example with --features cbor":
  buildTorpedoExampleCborLibrary(generateRust = true)
  exec quoteArg(findCargoExe()) &
    " run --features cbor --manifest-path examples/torpedo/rust_example/Cargo.toml"

proc writeTorpedoGoModFor(buildDir: string) =
  let modPath = "examples/torpedo/go_example/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add(
    "module github.com/status-im/nim-brokers/examples/torpedo/go_example\n\n"
  )
  contents.add("go 1.21\n\n")
  contents.add("require torpedolib v0.0.0\n")
  if buildDir == "build_cbor":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add("\nreplace torpedolib => ../nimlib/" & buildDir & "/torpedolib_go\n")
  writeFile(modPath, contents)
  if buildDir == "build_cbor":
    withDir "examples/torpedo/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"

task runTorpedoExampleCborGo,
  "Build the Torpedo Duel FFI library (CBOR mode) + run the Go example":
  buildTorpedoExampleCborLibrary(generateGo = true)
  writeTorpedoGoModFor("build_cbor")
  withDir "examples/torpedo/go_example":
    exec quoteArg(findGoExe()) & " run ."

# CBOR-mode build of the torpedo example. Same torpedolib.nim source +
# same cpp_example/main.cpp, compiled against the CBOR FFI codegen output.
task buildTorpedoExampleCbor,
  "Build the torpedo FFI example library (CBOR mode, into nimlib/build_cbor)":
  buildTorpedoExampleCborLibrary()

task buildTorpedoExampleCborCpp,
  "Build the Torpedo Duel C++ application against the CBOR-mode library (via CMake)":
  buildTorpedoExampleCborLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp", useCbor = true)

task runTorpedoExampleCborCpp,
  "Build and run the Torpedo Duel C++ text UI example against the CBOR-mode library":
  buildTorpedoExampleCborLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp", useCbor = true)
  exec quoteArg(torpedoExecutablePath())

task runTorpedoExampleCborPy,
  "Build the CBOR-mode torpedo library + Python wrapper and run the SAME python_example/main.py against it":
  buildTorpedoExampleCborLibrary(true)
  putEnv("TORPEDOLIB_BUILD_DIR", "build_cbor")
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("examples/torpedo/python_example/main.py")

task nph, "Install nph if needed and format modified Nim files":
  runNph(changedNimFiles(), "No modified .nim or .nimble files to format")

task nphall, "Install nph if needed and format all Nim files in the project":
  runNph(allNimFiles(), "No .nim or .nimble files found to format")

task alltests,
  "Run every test suite: test, testApiCbor, runFfiExampleCborCpp, runFfiExampleCborPy, runTypeMapTestLibCborCpp, runTypeMapTestLibCborPy":
  exec "nimble test"
  exec "nimble runFfiExampleCborCpp"
  exec "nimble runFfiExampleCborPy"
  exec "nimble testApiCbor"
  exec "nimble runTypeMapTestLibCborCpp"
  exec "nimble runTypeMapTestLibCborPy"

task allAsan, "Run all tests under AddressSanitizer (clang, orc/refc, debug)":
  exec "nimble testMtEventBrokerAsanOrc"
  exec "nimble testMtEventBrokerAsanRefc"
  exec "nimble testMtRequestBrokerAsanOrc"
  exec "nimble testMtRequestBrokerAsanRefc"
