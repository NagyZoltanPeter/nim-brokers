import std/[os, strutils]

# Package
version = "0.1.0"
author = "Status Research & Development GmbH"
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

proc isNim224MacosRefcDebug(mm: string, release: bool): bool =
  ## True for the one combo with a known upstream Nim 2.2.4 stdlib
  ## regression:  macOS + Nim 2.2.4 + --mm:refc + debug build.
  ##
  ## Sustained Channel[T].send of complex seq/object payloads triggers
  ## heap corruption in refc through stdlib system/channels_builtin.nim
  ## storeAux deep-copy. Fixed in Nim 2.2.10. See LIMITATION.md for the
  ## full analysis. Linux + 2.2.4 + refc debug is unaffected; refc
  ## release on macOS + 2.2.4 is unaffected.
  when defined(macosx) and (NimMajor, NimMinor, NimPatch) == (2, 2, 4):
    return mm == "refc" and not release
  false

proc isNim224MacosRefcDebugFromOpt(opt: string): bool =
  ## Same as isNim224MacosRefcDebug but parses --mm:refc / -d:release
  ## from a full Nim option string used by the iteration loops.
  let mm = if "--mm:refc" in opt: "refc" else: "orc"
  let release = "-d:release" in opt
  isNim224MacosRefcDebug(mm, release)

proc fragileTestsNimDefine(mm: string, release: bool): string =
  ## On the affected combo, emit the Nim define that gates fragile
  ## stress tests at compile time. See LIMITATION.md for what's gated.
  if isNim224MacosRefcDebug(mm, release): " -d:brokerTestsSkipFragileRefcBursts" else: ""

proc fragileTestsNimDefineFromOpt(opt: string): string =
  if isNim224MacosRefcDebugFromOpt(opt): " -d:brokerTestsSkipFragileRefcBursts" else: ""

proc fragileTestsCmakeFlag(mm: string, release: bool): string =
  ## Emit the cmake variable that translates to a compile definition the
  ## C++ test uses to skip fragile RUN(...) calls. Always emit an
  ## explicit ON/OFF — cmake's CMakeCache.txt persists across iteration
  ## reconfigures, so omitting the flag would leave the previous
  ## iteration's value in place.
  if isNim224MacosRefcDebug(mm, release):
    " -DBROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS=ON"
  else:
    " -DBROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS=OFF"

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

proc buildFfiExampleFlags(generatePy = false): string =
  result =
    "-d:BrokerFfiApi -d:BrokerFfiApiNative --threads:on --app:lib --path:. --outdir:examples/ffiapi/nimlib/build"
  result.add(nimMainPrefixFlag("mylib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/ffiapi/nimlib/build", "mylib"))
  if existsEnv("MM"):
    result.add(" --mm:" & getEnv("MM"))
  else:
    result.add(" --mm:orc")
  if generatePy or existsEnv("GEN_PY"):
    result.add(" -d:BrokerFfiApiGenPy")

proc buildFfiExampleLibrary(generatePy = false) =
  exec "nim c " & buildFfiExampleFlags(generatePy) & " examples/ffiapi/nimlib/mylib.nim"

proc buildTorpedoExampleFlags(generatePy = false): string =
  result =
    "-d:BrokerFfiApi -d:BrokerFfiApiNative --threads:on --app:lib --path:. --outdir:examples/torpedo/nimlib/build"
  result.add(nimMainPrefixFlag("torpedolib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/torpedo/nimlib/build", "torpedolib"))
  if existsEnv("MM"):
    result.add(" --mm:" & getEnv("MM"))
  else:
    result.add(" --mm:orc")
  if generatePy or existsEnv("GEN_PY"):
    result.add(" -d:BrokerFfiApiGenPy")

proc buildTorpedoExampleLibrary(generatePy = false) =
  exec "nim c " & buildTorpedoExampleFlags(generatePy) &
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

  let mtTests = ["test_multi_thread_request_broker", "test_multi_thread_event_broker"]
  for f in mtTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc --threads:on",
    ]:
      if skipRefcOnWindows(opt, f):
        continue
      test opt & fragileTestsNimDefineFromOpt(opt), f

task perftest, "Run performance and stress tests":
  # perf_test_* are stress-by-design and would tear up the affected
  # Nim 2.2.4 macOS refc debug freelist almost immediately; gate the
  # whole task on this combo rather than carving out individual tests.
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
      if isNim224MacosRefcDebugFromOpt(opt):
        echo "Skipping " & f & " (" & opt &
          ") on macOS + Nim 2.2.4: see LIMITATION.md (perf tests are stress-by-design)."
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
    ("test_api_cbor_library_init", "cbtest"), ("test_api_cbor_event_subscribe", "evtt")
  ]
  for (f, prefix) in cborApiTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiCBOR --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiCBOR --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiCBOR -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiCBOR -d:release --mm:refc --threads:on",
    ]:
      if skipRefcOnWindows(opt, f):
        continue
      # The event subscribe test exercises cross-thread Channel[T] sends
      # of complex CBOR-encoded payloads from a generated listener
      # closure that captures GC'd globals (the per-library subscription
      # table + lock). Under refc this combination is fragile:
      #   - refc + debug on macOS hits the Nim 2.2.4 stdlib Channel[T]
      #     regression documented in LIMITATION.md (sustained sends of
      #     complex seq/object payloads hang in storeAux).
      #   - refc + release SIGSEGVs on macOS at first delivery — the
      #     stop-the-world GC interacts badly with chronos thread-pool
      #     callbacks holding shared listener state across threads.
      # Skip the entire refc matrix for the event test on macOS until a
      # follow-up phase can either rework the listener to use shared-heap
      # state exclusively (avoiding GC'd captures across threads) or pin
      # to ORC.
      when defined(macosx):
        if f == "test_api_cbor_event_subscribe" and "--mm:refc" in opt:
          echo "Skipping " & f & " (" & opt &
            ") on macOS + refc: known cross-thread refc fragility — see LIMITATION.md and Phase 3 follow-up."
          continue
      let extraOpt = nimMainPrefixFlag(prefix)
      test opt & extraOpt & fragileTestsNimDefineFromOpt(opt), f

task testApi, "Run FFI API broker tests":
  let apiTests =
    ["test_api_request_broker", "test_api_event_broker", "test_api_library_init"]
  for f in apiTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiNative --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiNative --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiNative -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:BrokerFfiApiNative -d:release --mm:refc --threads:on",
    ]:
      if skipRefcOnWindows(opt, f):
        continue
      let extraOpt =
        if f == "test_api_library_init":
          nimMainPrefixFlag("apitestlib")
        else:
          ""
      test opt & extraOpt & fragileTestsNimDefineFromOpt(opt), f

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

proc buildTypeMapTestLibrary(mm: string = "orc", release: bool = false) =
  var flags =
    "-d:BrokerFfiApi -d:BrokerFfiApiNative -d:BrokerFfiApiGenPy --threads:on --app:lib --mm:" &
    mm & " --path:. --outdir:test/typemappingtestlib/build"
  flags.add(nimMainPrefixFlag("typemappingtestlib"))
  flags.add(nimWindowsCcFlag())
  flags.add(nimWindowsImplibFlag("test/typemappingtestlib/build", "typemappingtestlib"))
  flags.add(fragileTestsNimDefine(mm, release))
  if release:
    flags.add(" -d:release")
  exec "nim c " & flags & " test/typemappingtestlib/typemappingtestlib.nim"

proc typeMapTestCmakeBuildDir(): string =
  "test/typemappingtestlib/cmake-build"

proc buildTypeMapTestCmakeTarget(target = "", fragileFlag: string = "") =
  let cmakeDir = "test/typemappingtestlib"
  let buildDir = typeMapTestCmakeBuildDir()
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cmakeWindowsConfigureExtras() &
    fragileFlag
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc typeMapTestCppExecutablePath(): string =
  when defined(windows):
    "test/typemappingtestlib/build/test_typemappingtestlib.exe"
  else:
    "test/typemappingtestlib/build/test_typemappingtestlib"

proc typeMapTestAsanBuildDir(): string =
  "test/typemappingtestlib/cmake-build-asan"

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

proc buildTypeMapTestLibraryAsan(mm: string = "orc") =
  var flags =
    "--cc:clang --debugger:native -d:BrokerFfiApi -d:BrokerFfiApiNative -d:BrokerFfiApiGenPy --threads:on --app:lib --mm:" &
    mm & " --passC:" & quoteArg(asanCompileFlags()) & " --passL:" &
    quoteArg(asanLinkFlags(sharedLib = true)) &
    " --path:. --outdir:test/typemappingtestlib/build-asan"
  flags.add(nimMainPrefixFlag("typemappingtestlib"))
  exec "nim c " & flags & " test/typemappingtestlib/typemappingtestlib.nim"

proc buildTypeMapTestCmakeTargetAsan(target = "") =
  let cmakeDir = "test/typemappingtestlib"
  let buildDir = typeMapTestAsanBuildDir()
  let outDir = getCurrentDir() / "test/typemappingtestlib/build-asan"
  mkDir(buildDir)
  # On non-Windows, the asan build pins clang/clang++ directly. On Windows,
  # cmakeWindowsConfigureExtras() supplies Ninja+clang+lld+RelWithDebInfo+UCRT
  # — the same toolchain we use for the non-asan path, so heap/CRT match.
  var configure =
    "cmake -S " & cmakeDir & " -B " & buildDir & " -DASAN=ON -DTYPEMAPTEST_DIR=" &
    quoteArg(outDir)
  when defined(windows):
    configure.add(cmakeWindowsConfigureExtras())
  else:
    configure.add(" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++")
  exec configure
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc typeMapTestCppAsanExecutablePath(): string =
  when defined(windows):
    "test/typemappingtestlib/build-asan/test_typemappingtestlib.exe"
  else:
    "test/typemappingtestlib/build-asan/test_typemappingtestlib"

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

task buildTypeMapTestLib, "Build the type mapping test library (C/C++/Python)":
  buildTypeMapTestLibrary()

task testFfiApi,
  "Build and run the Python FFI API binding tests (orc/refc × debug/release)":
  for mm in ["orc", "refc"]:
    for release in [false, true]:
      let mode = if release: "release" else: "debug"
      echo "\n=== testFfiApi (mm:" & mm & " " & mode & ") ==="
      if skipRefcOnWindows(mm, "testFfiApi (" & mode & ")"):
        continue
      buildTypeMapTestLibrary(mm, release)
      let bits = soElfBits("test/typemappingtestlib/build/libtypemappingtestlib.so")
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
      exec quoteArg(python) & " -m unittest discover -s test/typemappingtestlib -p " &
        quoteArg("test_*.py") & " -v"

task testFfiApiCpp,
  "Build and run the C++ FFI API binding tests (orc/refc × debug/release)":
  for mm in ["orc", "refc"]:
    for release in [false, true]:
      let mode = if release: "release" else: "debug"
      echo "\n=== testFfiApiCpp (mm:" & mm & " " & mode & ") ==="
      if skipRefcOnWindows(mm, "testFfiApiCpp (" & mode & ")"):
        continue
      buildTypeMapTestLibrary(mm, release)
      buildTypeMapTestCmakeTarget(
        "test_typemappingtestlib", fragileTestsCmakeFlag(mm, release)
      )
      exec quoteArg(typeMapTestCppExecutablePath())

proc testAsan(mm: string, path: string) =
  let outputPath = joinPath("build", path & "_asan_" & mm).addFileExt(ExeExt)
  let label = path & " [ASAN, clang, mm:" & mm & ", debug]"
  let flags =
    "--cc:clang --debugger:native -d:nimUnittestOutputLevel:VERBOSE --threads:on --mm:" &
    mm & " --passC:" & quoteArg(asanCompileFlags()) & " --passL:" &
    quoteArg(asanLinkFlags()) & " --path:. --out:" & quoteArg(outputPath)
  exec "nim c " & flags & " test/" & path & ".nim"
  setAsanEnv()
  echo "=== RUN  " & label & " ==="
  exec quoteArg(outputPath)
  echo "=== PASS " & label & " ==="

task testFfiApiCppAsanOrc,
  "Build and run C++ FFI API binding tests under AddressSanitizer (clang, orc, debug)":
  echo "\n=== testFfiApiCppAsanOrc (clang, mm:orc, debug) ==="
  buildTypeMapTestLibraryAsan("orc")
  buildTypeMapTestCmakeTargetAsan("test_typemappingtestlib")
  setAsanEnv()
  exec quoteArg(typeMapTestCppAsanExecutablePath())

task testFfiApiCppAsanRefc,
  "Build and run C++ FFI API binding tests under AddressSanitizer (clang, refc, debug)":
  if skipRefcOnWindows("refc", "testFfiApiCppAsanRefc"):
    return
  echo "\n=== testFfiApiCppAsanRefc (clang, mm:refc, debug) ==="
  buildTypeMapTestLibraryAsan("refc")
  buildTypeMapTestCmakeTargetAsan("test_typemappingtestlib")
  setAsanEnv()
  exec quoteArg(typeMapTestCppAsanExecutablePath())

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

task buildTorpedoExample, "Build the torpedo FFI example library":
  buildTorpedoExampleLibrary()

task buildTorpedoExamplePy,
  "Build the torpedo FFI example library with generated Python wrapper":
  buildTorpedoExampleLibrary(true)

task runTorpedoExamplePy, "Build and run the Torpedo Duel Python text UI example":
  buildTorpedoExampleLibrary(true)
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("examples/torpedo/python_example/main.py")

task buildTorpedoExampleCpp, "Build the Torpedo Duel C++ application (via CMake)":
  buildTorpedoExampleLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp")

task runTorpedoExampleCpp, "Build and run the Torpedo Duel C++ text UI example":
  buildTorpedoExampleLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp")
  exec quoteArg(torpedoExecutablePath())

task nph, "Install nph if needed and format modified Nim files":
  runNph(changedNimFiles(), "No modified .nim or .nimble files to format")

task nphall, "Install nph if needed and format all Nim files in the project":
  runNph(allNimFiles(), "No .nim or .nimble files found to format")

task alltests,
  "Run every test suite: test, testApi, testFfiApi, testFfiApiCpp, runFfiExamplePy, runFfiExampleCpp, runFfiExampleC":
  exec "nimble test"
  exec "nimble testApi"
  exec "nimble testFfiApi"
  exec "nimble testFfiApiCpp"
  exec "nimble runFfiExamplePy"
  exec "nimble runFfiExampleCpp"
  exec "nimble runFfiExampleC"

task allAsan, "Run all tests under AddressSanitizer (clang, orc/refc, debug)":
  exec "nimble testFfiApiCppAsanOrc"
  exec "nimble testFfiApiCppAsanRefc"
  exec "nimble testMtEventBrokerAsanOrc"
  exec "nimble testMtEventBrokerAsanRefc"
  exec "nimble testMtRequestBrokerAsanOrc"
  exec "nimble testMtRequestBrokerAsanRefc"
