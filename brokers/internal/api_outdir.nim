## api_outdir
## ----------
## Tiny compile-time helper for ensuring the generated-output directory
## exists. Extracted from the (now-retired) native `api_codegen_c.nim` so
## the CBOR codegen and the CMake package emitter can share it without
## pulling in any native-codegen module.

import std/[os, macros]

proc ensureGeneratedOutputDir*(outDir: string) {.compileTime, raises: [].} =
  if outDir.len == 0 or dirExists(outDir):
    return
  try:
    createDir(outDir)
  except CatchableError:
    error(
      "Failed to create generated output directory '" & outDir & "': " &
        getCurrentExceptionMsg()
    )
