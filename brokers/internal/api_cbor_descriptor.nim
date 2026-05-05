## Runtime schema-descriptor types for the CBOR FFI discovery API.
##
## `<lib>_listApis` and `<lib>_getSchema` return CBOR-encoded views of these
## records so dynamic clients can introspect a library's surface without
## referring to the build-time generated headers.
##
## These types are hand-rolled (not produced by the broker macros) and are
## therefore part of the *stable* CBOR FFI v1 contract: changes to fields
## here are wire-breaking. Add new fields rather than rename / reorder.

{.push raises: [].}

import std/[options]
import ./api_cbor_codec

export api_cbor_codec

type
  ApiFieldInfo* = object
    name*: string
    nimType*: string

  ApiEnumValueInfo* = object
    name*: string
    ordinal*: int

  ApiTypeInfo* = object
    name*: string
    kind*: string ## "object" / "enum" / "alias" / "distinct"; matches `ApiTypeKind`.
    fields*: seq[ApiFieldInfo]
    enumValues*: seq[ApiEnumValueInfo]
    underlyingType*: string

  ApiRequestInfo* = object
    apiName*: string
    argsType*: string
      ## Nim type name of the synthesised args struct;
      ## empty string for zero-arg requests.
    argFields*: seq[ApiFieldInfo]
    responseType*: string

  ApiEventInfo* = object
    apiName*: string
    payloadType*: string

  ApiList* = object ## Lightweight payload returned by `<lib>_listApis`.
    libName*: string
    requests*: seq[string]
    events*: seq[string]

  LibraryDescriptor* = object ## Full payload returned by `<lib>_getSchema`.
    libName*: string
    cddl*: string ## Verbatim contents of the generated `<lib>.cddl`.
    requests*: seq[ApiRequestInfo]
    events*: seq[ApiEventInfo]
    types*: seq[ApiTypeInfo]

{.pop.}
