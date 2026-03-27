#!/usr/bin/env python3

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RAW_DOC = ROOT / "doc" / "mylib_expanded.nim"
CLEAN_DOC = ROOT / "doc" / "mylib_expanded_clean.nim"
READABLE_DOC = ROOT / "doc" / "mylib_expanded_readable.nim"

DEBUG_BLOCK_RE = re.compile(
    r"StmtList\n(?:.*?\n)(?:RequestBroker mode: (?:API|mt)|EventBroker mode: (?:API|mt))\n?",
    re.DOTALL,
)
GENSYM_RE = re.compile(r"`gensym\d+")
NUMERIC_SUFFIX_RE = re.compile(
    r"\b("
    r"provider|ctx|n|arr|i|j|res|msg|recvRes|recvFut|completedRes|"
    r"catchedRes|providerRes|resultValue|errResult|idx"
    r")_\d+\b"
)

SECTION_COMMENTS = {
    "# ===== ApiType: DeviceInfo / AddDeviceSpec =====": [
        "## Flow:",
        "## - These are the FFI-safe data carriers shared by request and event exports.",
        "## - Each ApiType generates a Nim object, a C ABI mirror type, and encode helpers.",
    ],
    "# ===== RequestBroker(API): InitializeRequest =====": [
        "## Flow:",
        "## - The first generated block is the multithreaded broker runtime for this request type.",
        "## - `setProvider` binds the provider to a broker context and thread, then installs an AsyncChannel loop.",
        "## - `request` calls the provider directly on the same thread or sends a cross-thread message and waits for the reply.",
        "## - The API tail encodes the Nim result into the exported C result struct.",
    ],
    "# ===== RequestBroker(API): ShutdownRequest =====": [
        "## Flow:",
        "## - Same runtime pattern as InitializeRequest, but for a zero-argument shutdown request.",
        "## - The exported C wrapper is intentionally internal-facing glue for library shutdown sequencing.",
    ],
    "# ===== RequestBroker(API): AddDevice =====": [
        "## Flow:",
        "## - This request shows seq[ApiType] argument marshalling through the API layer.",
        "## - The C wrapper decodes pointer + count into `seq[AddDeviceSpec]`, then dispatches through the same MT broker runtime.",
    ],
    "# ===== RequestBroker(API): RemoveDevice =====": [
        "## Flow:",
        "## - Single-argument request broker: provider registration, same-thread fast path, cross-thread AsyncChannel path, C result export.",
    ],
    "# ===== RequestBroker(API): GetDevice =====": [
        "## Flow:",
        "## - Same request-broker structure, with object result encoding back to the C ABI.",
    ],
    "# ===== RequestBroker(API): ListDevices =====": [
        "## Flow:",
        "## - Zero-argument request whose result contains a sequence; the tail allocates and frees the C array representation.",
    ],
    "# ===== EventBroker(API): DeviceStatusChanged + shared RegisterEventListenerResult =====": [
        "## Flow:",
        "## - EventBroker generates listener tables and emit/on/off helpers for the event itself.",
        "## - The shared `RegisterEventListenerResult` request broker mediates cross-thread registration and teardown of foreign callbacks.",
        "## - The exported C callbacks are adapted into Nim closures through generated registration handlers.",
    ],
    "# ===== EventBroker(API): DeviceDiscovered =====": [
        "## Flow:",
        "## - Same event-registration pipeline as DeviceStatusChanged, with per-event callback signatures and cleanup helpers.",
    ],
    "# ===== registerBrokerLibrary: \"mylib\" =====": [
        "## Flow:",
        "## - This section assembles the full shared-library runtime around the generated brokers.",
        "## - `createContext` allocates state, starts delivery and processing threads, waits for startup readiness, and returns the context handle.",
        "## - `shutdown` cleans listeners/providers, signals worker threads, releases startup state, and frees per-context resources.",
    ],
}


def strip_debug_blocks(text: str) -> str:
    return DEBUG_BLOCK_RE.sub("\n", text)


def normalize_gensyms(text: str) -> str:
    text = GENSYM_RE.sub("", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def normalize_numeric_suffix_locals(text: str) -> str:
    return NUMERIC_SUFFIX_RE.sub(lambda match: match.group(1), text)


def collapse_repeated_prefix(body: str, min_lines: int = 40) -> str:
    lines = body.splitlines()
    max_prefix = len(lines) // 2
    for prefix_len in range(max_prefix, min_lines - 1, -1):
        if lines[:prefix_len] == lines[prefix_len : 2 * prefix_len]:
            collapsed = [
                "## Collapsed identical repeated expansion block.",
                "## The removed copy was byte-for-byte identical to the first generated MT/runtime block.",
                "",
            ]
            return "\n".join(collapsed + lines[:prefix_len] + lines[2 * prefix_len :])
    return body


def rewrite_sections(body: str) -> str:
    lines = body.splitlines()
    output: list[str] = []
    current_title: str | None = None
    current_body: list[str] = []

    def flush_section() -> None:
        nonlocal current_title, current_body
        if current_title is None:
            output.extend(current_body)
        else:
            output.append(current_title)
            comments = SECTION_COMMENTS.get(current_title)
            if comments:
                output.extend(comments)
            section_body = "\n".join(current_body).strip("\n")
            if section_body:
                output.append(collapse_repeated_prefix(section_body))
        current_title = None
        current_body = []

    for line in lines:
        if line.startswith("# ===== "):
            flush_section()
            current_title = line
        else:
            current_body.append(line)
    flush_section()
    return "\n".join(output) + "\n"


def add_readable_header(body: str) -> str:
    lines = body.splitlines()
    end_of_header = 0
    for index, line in enumerate(lines):
        if line.startswith("# ====="):
            end_of_header = index
            break
    header = lines[:end_of_header]
    rest = lines[end_of_header:]

    note = [
        "##",
        "## Readable companion:",
        "## - Removes accidental brokerDebug treeRepr blocks (StmtList / mode markers).",
        "## - Strips Nim hygiene suffixes like `gensym42 from local identifiers.",
        "## - Renames obvious generated locals like provider_587202969 to provider.",
        "## - Collapses exact duplicated section prefixes when the API expansion embeds the same MT/runtime block twice.",
        "## - Keeps generated structure intact; this is still reference material, not hand-maintained code.",
        "",
    ]
    return "\n".join(header + note + rest) + "\n"


def main() -> None:
    raw_text = RAW_DOC.read_text()
    clean_text = strip_debug_blocks(raw_text)
    readable_text = add_readable_header(
        rewrite_sections(
            normalize_numeric_suffix_locals(normalize_gensyms(clean_text))
        )
    )

    CLEAN_DOC.write_text(clean_text)
    READABLE_DOC.write_text(readable_text)


if __name__ == "__main__":
    main()