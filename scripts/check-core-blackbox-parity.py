#!/usr/bin/env python3
"""Compare two lib_cmdy builds through the public C ABI only.

This is a behavioral clean-room gate: it never reads either implementation.
It feeds deterministic terminal streams into both dynamic libraries and compares
cursor, scrollback, text, cells, attributes, and semantic command blocks.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import itertools
import json
import random
import subprocess
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path


U8P = ctypes.POINTER(ctypes.c_uint8)
U32P = ctypes.POINTER(ctypes.c_uint32)
I32P = ctypes.POINTER(ctypes.c_int32)


class CoreLibrary:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lib = ctypes.CDLL(str(path.resolve()))
        self.lib.cmdy_create.argtypes = [ctypes.c_int32, ctypes.c_int32]
        self.lib.cmdy_create.restype = ctypes.c_void_p
        self.lib.cmdy_free.argtypes = [ctypes.c_void_p]
        self.lib.cmdy_feed.argtypes = [ctypes.c_void_p, U8P, ctypes.c_size_t]
        self.lib.cmdy_resize.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32]
        for name in (
            "cmdy_cols", "cmdy_rows", "cmdy_buffer_line_count",
            "cmdy_cursor_row", "cmdy_cursor_col", "cmdy_live_top_row",
            "cmdy_block_count",
        ):
            fn = getattr(self.lib, name)
            fn.argtypes = [ctypes.c_void_p]
            fn.restype = ctypes.c_int32
        self.lib.cmdy_line_text.argtypes = [
            ctypes.c_void_p, ctypes.c_int32, ctypes.POINTER(ctypes.c_char),
            ctypes.c_size_t,
        ]
        self.lib.cmdy_line_text.restype = ctypes.c_long
        self.lib.cmdy_cell.argtypes = [
            ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32,
            U32P, I32P, U32P, U32P, U32P,
        ]
        self.lib.cmdy_cell.restype = ctypes.c_int32
        self.lib.cmdy_block_get.argtypes = [
            ctypes.c_void_p, ctypes.c_int32,
            I32P, I32P, I32P, I32P, I32P,
        ]
        self.lib.cmdy_block_get.restype = ctypes.c_int32

    def run(self, case: "Case") -> dict[str, object]:
        handle = self.lib.cmdy_create(case.cols, case.rows)
        if not handle:
            raise RuntimeError(f"{self.path}: cmdy_create failed")
        try:
            offset = 0
            for size in case.chunks:
                chunk = case.payload[offset:offset + size]
                offset += size
                if chunk:
                    data = (ctypes.c_uint8 * len(chunk)).from_buffer_copy(chunk)
                    self.lib.cmdy_feed(handle, data, len(chunk))
            if offset != len(case.payload):
                raise RuntimeError(f"invalid chunk plan for {case.name}")
            if case.resize is not None:
                self.lib.cmdy_resize(handle, *case.resize)
            return self._snapshot(handle)
        finally:
            self.lib.cmdy_free(handle)

    def _snapshot(self, handle: int) -> dict[str, object]:
        cols = self.lib.cmdy_cols(handle)
        rows = self.lib.cmdy_rows(handle)
        line_count = self.lib.cmdy_buffer_line_count(handle)
        lines: list[str] = []
        line_bytes: list[str] = []
        cells: list[list[list[int]]] = []
        for row in range(line_count):
            # A cell can contain an arbitrary combining sequence, so a fixed
            # bytes-per-column allocation can silently truncate the ABI text.
            capacity = max(4096, cols * 256 + 1)
            while True:
                buffer = ctypes.create_string_buffer(capacity)
                written = self.lib.cmdy_line_text(handle, row, buffer, capacity)
                if written < 0:
                    raise RuntimeError(f"cmdy_line_text failed at {row}")
                if written < capacity - 1:
                    break
                capacity *= 2
                if capacity > 16 * 1024 * 1024:
                    raise RuntimeError(f"cmdy_line_text is implausibly large at {row}")
            raw_line = buffer.raw[:written]
            line_bytes.append(raw_line.hex())
            lines.append(raw_line.decode("utf-8", "replace"))
            row_cells: list[list[int]] = []
            for col in range(cols):
                scalar = ctypes.c_uint32()
                width = ctypes.c_int32()
                fg = ctypes.c_uint32()
                bg = ctypes.c_uint32()
                style = ctypes.c_uint32()
                result = self.lib.cmdy_cell(
                    handle, row, col, ctypes.byref(scalar), ctypes.byref(width),
                    ctypes.byref(fg), ctypes.byref(bg), ctypes.byref(style),
                )
                if result != 0:
                    raise RuntimeError(f"cmdy_cell failed at {row},{col}")
                row_cells.append([scalar.value, width.value, fg.value, bg.value, style.value])
            cells.append(row_cells)
        blocks: list[list[int]] = []
        for index in range(self.lib.cmdy_block_count(handle)):
            values = [ctypes.c_int32() for _ in range(5)]
            result = self.lib.cmdy_block_get(
                handle, index, *(ctypes.byref(value) for value in values))
            if result != 0:
                raise RuntimeError(f"cmdy_block_get failed at {index}")
            blocks.append([value.value for value in values])
        return {
            "size": [cols, rows],
            "lineCount": line_count,
            "cursor": [self.lib.cmdy_cursor_row(handle), self.lib.cmdy_cursor_col(handle)],
            "liveTop": self.lib.cmdy_live_top_row(handle),
            "lineBytes": line_bytes,
            "lines": lines,
            "cells": cells,
            "blocks": blocks,
        }


@dataclass(frozen=True)
class Case:
    name: str
    cols: int
    rows: int
    payload: bytes
    chunks: tuple[int, ...]
    resize: tuple[int, int] | None = None


def nowrap_parked_dl_matrix_cases() -> Iterator[Case]:
    """Exhaust the DL boundary after a no-wrap print parks past a margin.

    Axes: widths 2...6, heights 1...5, every horizontal margin, every
    physical cursor row, and DL counts 1...height+1.  The printable run fills
    the margin exactly with DECAWM disabled.  Cardinality: 3,850.
    """
    for cols in range(2, 7):
        for rows in range(1, 6):
            for left in range(1, cols + 1):
                for right in range(left, cols + 1):
                    content = b"A" * (right - left + 1)
                    for row in range(1, rows + 1):
                        for delete_count in range(1, rows + 2):
                            payload = b"".join([
                                b"\x1b[?69h",
                                f"\x1b[{left};{right}s".encode(),
                                b"\x1b[?7l",
                                f"\x1b[{row};{left}H".encode(),
                                content,
                                f"\x1b[{delete_count}M".encode(),
                            ])
                            name = (f"audit-nowrap-dl-c{cols}-r{rows}-"
                                    f"m{left}-{right}-y{row}-n{delete_count}")
                            yield Case(name, cols, rows, payload,
                                       (len(payload),), None)


def il_to_dl_superset_matrix_cases() -> Iterator[Case]:
    """Exhaust small-screen IL-to-DL content and erase-state transitions.

    This is the saved, documented superset of the earlier ad-hoc 27,720-case
    audit.  Axes: widths 2...6; heights 1...5; every horizontal margin and
    cursor row; IL and DL counts 1...height+1; pending, settled, and no-wrap
    parked cursor states; default and active RGB backgrounds; and simple or
    combining printable content.  Cardinality: 231,000.
    """
    cursor_states = ("pending", "settled", "nowrap-parked")
    for cols in range(2, 7):
        for rows in range(1, 6):
            for left in range(1, cols + 1):
                for right in range(left, cols + 1):
                    margin_width = right - left + 1
                    for row in range(1, rows + 1):
                        for insert_count in range(1, rows + 2):
                            for delete_count in range(1, rows + 2):
                                for cursor_state in cursor_states:
                                    occupied = (margin_width if cursor_state != "settled"
                                                else max(0, margin_width - 1))
                                    for active_background in (False, True):
                                        for combining_content in (False, True):
                                            if occupied == 0:
                                                content = b""
                                            elif combining_content:
                                                content = (b"A" * (occupied - 1) +
                                                           "A\u0301".encode())
                                            else:
                                                content = b"A" * occupied
                                            payload_parts = [
                                                b"\x1b[?69h",
                                                f"\x1b[{left};{right}s".encode(),
                                                f"\x1b[{row};{left}H".encode(),
                                            ]
                                            if cursor_state == "nowrap-parked":
                                                payload_parts.append(b"\x1b[?7l")
                                            if active_background:
                                                payload_parts.append(b"\x1b[48:2::3:4m")
                                            payload_parts.extend([
                                                f"\x1b[{insert_count}L".encode(),
                                                content,
                                                f"\x1b[{delete_count}M".encode(),
                                            ])
                                            payload = b"".join(payload_parts)
                                            name = (f"audit-il-dl-c{cols}-r{rows}-"
                                                    f"m{left}-{right}-y{row}-"
                                                    f"i{insert_count}-d{delete_count}-"
                                                    f"{cursor_state}-bg{int(active_background)}-"
                                                    f"mn{int(combining_content)}")
                                            yield Case(name, cols, rows, payload,
                                                       (len(payload),), None)


def active_margin_il_dl_roundtrip_matrix_cases() -> Iterator[Case]:
    """Audit content present before an active-margin IL/DL round trip.

    The bounded family fixes a four-by-four screen and exhausts inactive,
    active, partial, full, and hidden horizontal geometry; every explicit
    vertical region plus the default; every cursor row; blank, narrow, and
    width-two content; and IL/DL counts one through five. Cardinality: 14,700.
    """
    geometries = (
        ("off", b""),
        ("active-default", b"\x1b[?69h"),
        ("active-full", b"\x1b[?69h\x1b[1;4s"),
        ("active-left", b"\x1b[?69h\x1b[1;3s"),
        ("active-right", b"\x1b[?69h\x1b[2;4s"),
        ("active-internal", b"\x1b[?69h\x1b[2;3s"),
        ("hidden-full", b"\x1b[?69h\x1b[1;4s\x1b[?69l"),
    )
    verticals: list[tuple[str, bytes]] = [("default", b"")]
    verticals.extend(
        (f"v{top}-{bottom}", f"\x1b[{top};{bottom}r".encode())
        for top in range(1, 5)
        for bottom in range(top + 1, 5)
    )
    contents = (
        ("blank", b""),
        ("ascii", b"A"),
        ("wide", "\u65e5".encode()),
    )
    for geometry_name, geometry in geometries:
        for vertical_name, vertical in verticals:
            for row in range(1, 5):
                position = f"\x1b[{row};1H".encode()
                for content_name, content in contents:
                    for insert_count in range(1, 6):
                        for delete_count in range(1, 6):
                            payload = b"".join([
                                geometry, vertical, position, content,
                                f"\x1b[{insert_count}L".encode(),
                                f"\x1b[{delete_count}M".encode(),
                            ])
                            name = (
                                f"audit-active-il-dl-roundtrip-"
                                f"{geometry_name}-{vertical_name}-y{row}-"
                                f"{content_name}-i{insert_count}-d{delete_count}"
                            )
                            yield Case(name, 4, 4, payload,
                                       (len(payload),), None)


def active_margin_il_dl_roundtrip_representative_cases() -> Iterator[Case]:
    """Compact controls for the random-136 IL/DL round-trip branches."""
    reduced = bytes.fromhex(
        "1b5b3f36681b5b3f3639681b5b323b35721b44f09f9a80"
        "1b5b324c1b5b324d1b4d1b391b4461"
    )
    yield Case("random-0136-width-residual", 3, 4, reduced,
               (len(reduced),), (1, 1))

    selected = (
        ("active-il-dl-roundtrip-minimum",
         "audit-active-il-dl-roundtrip-active-default-v2-4-y3-wide-i2-d2"),
        ("active-il-dl-roundtrip-ascii",
         "audit-active-il-dl-roundtrip-active-default-v2-4-y3-ascii-i2-d2"),
        ("active-il-dl-roundtrip-blank-control",
         "audit-active-il-dl-roundtrip-active-default-v2-4-y3-blank-i2-d2"),
        ("active-il-dl-roundtrip-off-control",
         "audit-active-il-dl-roundtrip-off-v2-4-y3-wide-i2-d2"),
        ("active-il-dl-roundtrip-hidden-control",
         "audit-active-il-dl-roundtrip-hidden-full-v2-4-y3-wide-i2-d2"),
        ("active-il-dl-roundtrip-full",
         "audit-active-il-dl-roundtrip-active-full-v1-4-y2-wide-i3-d1"),
        ("active-il-dl-roundtrip-left",
         "audit-active-il-dl-roundtrip-active-left-v1-4-y3-ascii-i3-d2"),
        ("active-il-dl-roundtrip-right-overlap",
         "audit-active-il-dl-roundtrip-active-right-v1-4-y3-wide-i2-d1"),
        ("active-il-dl-roundtrip-right-no-overlap-control",
         "audit-active-il-dl-roundtrip-active-right-v1-4-y3-ascii-i2-d1"),
        ("active-il-dl-roundtrip-internal-overlap",
         "audit-active-il-dl-roundtrip-active-internal-v1-4-y4-wide-i1-d1"),
        ("active-il-dl-roundtrip-default-region",
         "audit-active-il-dl-roundtrip-active-default-default-y4-wide-i3-d3"),
        ("active-il-dl-roundtrip-short-region",
         "audit-active-il-dl-roundtrip-active-default-v1-3-y3-wide-i2-d1"),
        ("active-il-dl-roundtrip-inset-region",
         "audit-active-il-dl-roundtrip-active-default-v3-4-y4-wide-i1-d1"),
        ("active-il-dl-roundtrip-low-insert-control",
         "audit-active-il-dl-roundtrip-active-default-v1-4-y2-wide-i2-d1"),
        ("active-il-dl-roundtrip-high-insert-control",
         "audit-active-il-dl-roundtrip-active-default-v1-4-y2-wide-i4-d1"),
        ("active-il-dl-roundtrip-low-delete-control",
         "audit-active-il-dl-roundtrip-active-default-v1-4-y3-wide-i3-d1"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in active_margin_il_dl_roundtrip_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing active IL/DL controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def narrowed_margin_dl_matrix_cases() -> Iterator[Case]:
    """Audit DL after replacing full-width geometry at the physical edge.

    Axes: widths 2...6, heights 1...5, every replacement horizontal
    margin, every physical row, DL counts 1...height+1, and settled,
    wrap-pending, or DECAWM-off parked state at the old physical right edge.
    Cardinality: 11,550.
    """
    for cols in range(2, 7):
        for rows in range(1, 6):
            for left in range(1, cols + 1):
                for right in range(left, cols + 1):
                    for row in range(1, rows + 1):
                        for cursor_state in ("settled", "pending", "nowrap-parked"):
                            for delete_count in range(1, rows + 2):
                                payload_parts = [f"\x1b[{row};{cols}H".encode()]
                                if cursor_state == "pending":
                                    payload_parts.append(b"A")
                                elif cursor_state == "nowrap-parked":
                                    payload_parts.extend([b"\x1b[?7l", b"A"])
                                payload_parts.extend([
                                    b"\x1b[?69h",
                                    f"\x1b[{left};{right}s".encode(),
                                    f"\x1b[{delete_count}M".encode(),
                                ])
                                payload = b"".join(payload_parts)
                                name = (f"audit-narrow-dl-c{cols}-r{rows}-"
                                        f"m{left}-{right}-y{row}-"
                                        f"{cursor_state}-n{delete_count}")
                                yield Case(name, cols, rows, payload,
                                           (len(payload),), None)


def narrowed_margin_dl_content_matrix_cases() -> Iterator[Case]:
    """Expose DL mutations after the cursor is stranded by new margins.

    Axes: widths 2...5; heights 1...4; default and every valid explicit
    vertical region; every horizontal-margin pair; every physical cursor row;
    settled, wrap-pending, and no-wrap parked cursor states at the old physical
    right edge; DL counts 1, 2, and height+1 (deduplicated); blank content plus
    narrow, wide, and placeholder markers on every physical row.  Nonblank
    markers start at the requested left margin before DECLRMM is enabled.
    Cardinality: 157,488.
    """
    placeholder = "\U0010eeee\u0305\u030d\u030e".encode()
    for cols in range(2, 6):
        for rows in range(1, 5):
            verticals: list[tuple[str, bytes]] = [("default", b"")]
            verticals.extend(
                (f"v{top}-{bottom}", f"\x1b[{top};{bottom}r".encode())
                for top in range(1, rows + 1)
                for bottom in range(top + 1, rows + 1)
            )
            delete_counts = sorted({1, 2, rows + 1})
            for left in range(1, cols + 1):
                for right in range(left, cols + 1):
                    marker_states: list[tuple[str, bytes]] = [("blank", b"")]
                    for marker_row in range(1, rows + 1):
                        marker_position = f"\x1b[{marker_row};{left}H".encode()
                        marker_states.extend([
                            (f"narrow-y{marker_row}",
                             b"\x1b[?7l" + marker_position + b"Z"),
                            (f"wide-y{marker_row}",
                             b"\x1b[?7l" + marker_position
                             + "\u65e5".encode()),
                            (f"placeholder-y{marker_row}",
                             b"\x1b[?7l" + marker_position + placeholder),
                        ])
                    for vertical_name, vertical_setup in verticals:
                        for cursor_row in range(1, rows + 1):
                            old_edge = f"\x1b[{cursor_row};{cols}H".encode()
                            cursor_states = (
                                ("settled", b"\x1b[?7h" + old_edge),
                                ("pending", b"\x1b[?7h" + old_edge + b"A"),
                                ("nowrap-parked",
                                 b"\x1b[?7l" + old_edge + b"A"),
                            )
                            for state_name, cursor_setup in cursor_states:
                                for delete_count in delete_counts:
                                    for marker_name, marker_setup in marker_states:
                                        payload = b"".join([
                                            marker_setup,
                                            vertical_setup,
                                            cursor_setup,
                                            b"\x1b[?69h",
                                            f"\x1b[{left};{right}s".encode(),
                                            f"\x1b[{delete_count}M".encode(),
                                        ])
                                        name = (
                                            f"audit-narrow-dl-content-c{cols}-"
                                            f"r{rows}-m{left}-{right}-"
                                            f"{vertical_name}-y{cursor_row}-"
                                            f"{state_name}-n{delete_count}-"
                                            f"{marker_name}"
                                        )
                                        yield Case(name, cols, rows, payload,
                                                   (len(payload),), None)


def narrowed_margin_dl_content_representative_cases() -> Iterator[Case]:
    """Freeze the random-0081 DL/content witness and close controls."""
    minimal = b"Z\x1b[?69h\x1b[1;1s\x1b[M"
    yield Case("random-0081-narrowed-margin-dl-content", 2, 1, minimal,
               (len(minimal),), None)
    placeholder = ("\U0010eeee\u0305\u030d\u030e".encode()
                   + b"\x1b[?69h\x1b[1;1s\x1b[M")
    yield Case("random-0081-placeholder-content", 2, 1, placeholder,
               (len(placeholder),), None)
    full_width = b"Z\x1b[?69h\x1b[1;2s\x1b[M"
    yield Case("random-0081-cursor-inside-margin-control", 2, 1, full_width,
               (len(full_width),), None)
    blank = b"\x1b[2G\x1b[?69h\x1b[1;1s\x1b[M"
    yield Case("random-0081-blank-content-control", 2, 1, blank,
               (len(blank),), None)


def hidden_margin_decfi_wide_matrix_cases() -> Iterator[Case]:
    """Audit DECFI wide-cell shifts after DECLRMM is disabled.

    Axes: widths 3...6, every stored horizontal margin, every physical print
    start and DECFI cursor column, four width-two grapheme classes, and wide
    content with or without a trailing narrow cell.  Cardinality: 10,760.
    """
    wide_graphemes = (
        ("cjk", "\u65e5".encode()),
        ("rocket", "\U0001f680".encode()),
        ("flag", "\U0001f1fa\U0001f1f8".encode()),
        ("heart-vs16", "\u2764\ufe0f".encode()),
    )
    for cols in range(3, 7):
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                for print_col in range(1, cols + 1):
                    for cursor_col in range(1, cols + 1):
                        for grapheme_name, grapheme in wide_graphemes:
                            for narrow_suffix in (False, True):
                                payload = b"".join([
                                    b"\x1b[?69h",
                                    f"\x1b[{left};{right}s".encode(),
                                    f"\x1b[1;{print_col}H".encode(),
                                    grapheme,
                                    b"A" if narrow_suffix else b"",
                                    f"\x1b[1;{cursor_col}H".encode(),
                                    b"\x1b[?69l",
                                    b"\x1b9",
                                ])
                                name = (f"audit-hidden-decfi-c{cols}-"
                                        f"m{left}-{right}-p{print_col}-"
                                        f"x{cursor_col}-{grapheme_name}-"
                                        f"suffix{int(narrow_suffix)}")
                                yield Case(name, cols, 2, payload,
                                           (len(payload),), None)


def hidden_margin_decfi_cursor_matrix_cases() -> Iterator[Case]:
    """Audit the cursor-only DECFI branch after DECLRMM is disabled.

    Axes: widths 3...6, every stored horizontal margin, and every physical
    cursor column.  Cardinality: 259.
    """
    for cols in range(3, 7):
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                for cursor_col in range(1, cols + 1):
                    payload = b"".join([
                        b"\x1b[?69h",
                        f"\x1b[{left};{right}s".encode(),
                        f"\x1b[1;{cursor_col}H".encode(),
                        b"\x1b[?69l",
                        b"\x1b9",
                    ])
                    name = (f"audit-hidden-decfi-cursor-c{cols}-"
                            f"m{left}-{right}-x{cursor_col}")
                    yield Case(name, cols, 2, payload, (len(payload),), None)


def active_margin_decfi_wide_persistence_matrix_cases() -> Iterator[Case]:
    """Audit DECFI after width-two content reaches an active right edge.

    Axes: widths 2...6; every active horizontal margin at least two columns
    wide; ASCII and four width-two grapheme classes; pending, explicitly
    settled, and no-wrap parked edge states; default, one, two, and
    width-plus-one CHT counts; and preserving or cell-replacing histories.
    Cardinality: 14,700.
    """
    sources = (
        ("ascii", b"A", 1),
        ("cjk", "\u65e5".encode(), 2),
        ("rocket", "\U0001f680".encode(), 2),
        ("flag", "\U0001f1fa\U0001f1f8".encode(), 2),
        ("heart", "\u2764\ufe0f".encode(), 2),
    )
    for cols in range(2, 7):
        for left in range(1, cols + 1):
            for right in range(left + 1, cols + 1):
                geometry = (b"\x1b[?69h" +
                            f"\x1b[{left};{right}s".encode())
                for source_name, source, source_width in sources:
                    lead = right - source_width + 1
                    position = f"\x1b[1;{lead}H".encode()
                    edge = f"\x1b[1;{right}H".encode()
                    states = (
                        ("pending", b"\x1b[?7h" + position + source),
                        ("settled", b"\x1b[?7h" + position + source + edge),
                        ("parked", b"\x1b[?7l" + position + source),
                    )
                    for state_name, state in states:
                        for count in sorted({0, 1, 2, cols + 1}):
                            move = f"\x1b[{count}I".encode()
                            histories = (
                                ("none", b""),
                                ("style", b"\x1b[31m"),
                                ("semantic", b"\x1b]133;A\x07"),
                                ("write-other", b"\x1b[2;1HZ" + edge),
                                ("erase-wide",
                                 position + b"\x1b[2X" + edge),
                                ("delete-wide",
                                 position + b"\x1b[2P" + edge),
                                ("print-narrow", edge + b"B" + edge),
                            )
                            for history_name, history in histories:
                                payload = (geometry + state + move + history +
                                           b"\x1b9")
                                name = (
                                    f"audit-active-decfi-wide-c{cols}-"
                                    f"m{left}-{right}-{source_name}-{state_name}-"
                                    f"n{count}-{history_name}"
                                )
                                yield Case(name, cols, 2, payload,
                                           (len(payload),), None)


def active_margin_decfi_wide_persistence_representative_cases() -> Iterator[Case]:
    """Compact controls for the random-126 DECFI persistence branches."""
    reduced = bytes.fromhex(
        "091b5b3f36396841cc815a091b5b323b397341cc81c3a93041cc8161"
        "c3a9e29da4efb88f1b5b32491b395af09f9a80f09f9a80f09f9a80"
        "f09f9a80301b5b32421b5d3133333b4107"
    )
    yield Case("random-0126-decfi-semantic-row-residual", 8, 6,
               reduced, (len(reduced),), (11, 10))

    selected = (
        ("active-decfi-wide-pending",
         "audit-active-decfi-wide-c4-m2-3-heart-pending-n2-none"),
        ("active-decfi-wide-settled",
         "audit-active-decfi-wide-c4-m2-3-cjk-settled-n1-none"),
        ("active-decfi-wide-parked",
         "audit-active-decfi-wide-c4-m2-3-rocket-parked-n0-none"),
        ("active-decfi-wide-flag",
         "audit-active-decfi-wide-c4-m2-3-flag-pending-n5-none"),
        ("active-decfi-narrow-control",
         "audit-active-decfi-wide-c4-m2-3-ascii-pending-n2-none"),
        ("active-decfi-wide-style",
         "audit-active-decfi-wide-c4-m2-3-heart-pending-n2-style"),
        ("active-decfi-wide-semantic",
         "audit-active-decfi-wide-c4-m2-3-heart-pending-n2-semantic"),
        ("active-decfi-wide-write-other",
         "audit-active-decfi-wide-c4-m2-3-heart-pending-n2-write-other"),
        ("active-decfi-wide-erase-reset",
         "audit-active-decfi-wide-c4-m2-3-heart-pending-n2-erase-wide"),
        ("active-decfi-wide-delete-reset",
         "audit-active-decfi-wide-c4-m2-3-heart-pending-n2-delete-wide"),
        ("active-decfi-wide-print-reset",
         "audit-active-decfi-wide-c4-m2-3-heart-pending-n2-print-narrow"),
        ("active-decfi-wide-full",
         "audit-active-decfi-wide-c4-m1-4-heart-pending-n2-none"),
        ("active-decfi-wide-left",
         "audit-active-decfi-wide-c4-m1-3-heart-pending-n2-none"),
        ("active-decfi-wide-right",
         "audit-active-decfi-wide-c4-m2-4-heart-pending-n2-none"),
        ("active-decfi-wide-internal",
         "audit-active-decfi-wide-c6-m2-5-heart-pending-n2-none"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in active_margin_decfi_wide_persistence_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing active DECFI wide controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def hidden_margin_vs16_setup_matrix_cases() -> Iterator[Case]:
    """Audit VS16 after a narrow emoji base wraps from beyond a margin.

    Axes: widths 3...6, every stored horizontal margin whose right edge is
    internal, every physical print column to its right, every final cursor
    column, and with or without a following narrow printable.  Cardinality:
    724.  These are the setup prefixes deliberately excluded from the wider
    mode-off DECFI matrix.
    """
    heart_vs16 = "\u2764\ufe0f".encode()
    for cols in range(3, 7):
        for left in range(1, cols + 1):
            for right in range(left, cols):
                for print_col in range(right + 1, cols + 1):
                    for cursor_col in range(1, cols + 1):
                        for narrow_suffix in (False, True):
                            payload = b"".join([
                                b"\x1b[?69h",
                                f"\x1b[{left};{right}s".encode(),
                                f"\x1b[1;{print_col}H".encode(),
                                heart_vs16,
                                b"A" if narrow_suffix else b"",
                                f"\x1b[1;{cursor_col}H".encode(),
                            ])
                            name = (f"audit-hidden-vs16-c{cols}-"
                                    f"m{left}-{right}-p{print_col}-"
                                    f"x{cursor_col}-suffix{int(narrow_suffix)}")
                            yield Case(name, cols, 2, payload,
                                       (len(payload),), None)


def ind_stored_margin_geometry_matrix_cases() -> Iterator[Case]:
    """Audit IND across stored horizontal and vertical geometry.

    Axes: widths 2...6; heights 1...4; every stored horizontal margin;
    default vertical geometry plus every explicit top/bottom pair; every
    physical cursor row; DECLRMM active or hidden; CUP and settled cursors at
    every physical column; and physical-edge wrap-pending or no-wrap parked
    cursors.  Each physical row starts with a distinct narrow marker.
    Cardinality: 57,600.
    """
    for cols in range(2, 7):
        for rows in range(1, 5):
            vertical_regions: list[tuple[int, int] | None] = [None]
            vertical_regions.extend(
                (top, bottom)
                for top in range(1, rows + 1)
                for bottom in range(top + 1, rows + 1)
            )
            marker_setup = b"".join(
                f"\x1b[{row};1H".encode() + bytes([64 + row]) * cols
                for row in range(1, rows + 1)
            )
            for vertical_region in vertical_regions:
                if vertical_region is None:
                    vertical_setup = b""
                    vertical_name = "default"
                else:
                    top, bottom = vertical_region
                    vertical_setup = f"\x1b[{top};{bottom}r".encode()
                    vertical_name = f"v{top}-{bottom}"
                for row in range(1, rows + 1):
                    cursor_states: list[tuple[str, int, bytes]] = []
                    for cursor_col in range(cols):
                        cursor_states.append((
                            "cup", cursor_col,
                            f"\x1b[{row};{cursor_col + 1}H".encode(),
                        ))
                        if cursor_col == 0:
                            settled_setup = f"\x1b[{row};1H".encode() + b"Q\b"
                        else:
                            settled_setup = (
                                f"\x1b[{row};{cursor_col}H".encode() + b"Q")
                        cursor_states.append(("settled", cursor_col, settled_setup))
                    physical_edge = f"\x1b[{row};{cols}H".encode()
                    cursor_states.extend([
                        ("pending", cols, physical_edge + b"Q"),
                        ("nowrap", cols, b"\x1b[?7l" + physical_edge + b"Q"),
                    ])
                    for state_name, cursor_col, cursor_setup in cursor_states:
                        for left in range(1, cols + 1):
                            for right in range(left, cols + 1):
                                for margin_mode in ("active", "hidden"):
                                    parts = [
                                        marker_setup, vertical_setup, cursor_setup,
                                        b"\x1b[?69h",
                                        f"\x1b[{left};{right}s".encode(),
                                    ]
                                    if margin_mode == "hidden":
                                        parts.append(b"\x1b[?69l")
                                    parts.append(b"\x1bD")
                                    payload = b"".join(parts)
                                    name = (f"audit-ind-c{cols}-r{rows}-"
                                            f"{vertical_name}-y{row}-"
                                            f"m{left}-{right}-{margin_mode}-"
                                            f"{state_name}-x{cursor_col}")
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def lf_ri_parked_geometry_matrix_cases() -> Iterator[Case]:
    """Audit LF, IND, and RI from settled, pending, and parked edges.

    Axes: widths 1...6; heights 1...4; default vertical geometry plus every
    explicit top/bottom pair; every physical cursor row; physical geometry and
    every active or hidden horizontal-margin pair; the stored right edge and,
    when distinct, the physical right edge; settled cursors with autowrap on or
    off, wrap-pending cursors, and DECAWM-off parked cursors; LF, IND, and RI;
    and blank, narrow-marker, or width-two-marker initial rows.  Cardinality:
    304,560.
    """
    wide_markers = ("\u65e5", "\u754c", "\u8a9e", "\u672c")
    for cols in range(1, 7):
        horizontal_geometries: list[tuple[str, int, bytes]] = [
            ("physical", cols, b""),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                enable = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                horizontal_geometries.extend([
                    (f"active-{left}-{right}-stored-edge", right, enable),
                    (f"hidden-{left}-{right}-stored-edge", right,
                     enable + b"\x1b[?69l"),
                ])
                if right < cols:
                    horizontal_geometries.extend([
                        (f"active-{left}-{right}-physical-edge", cols, enable),
                        (f"hidden-{left}-{right}-physical-edge", cols,
                         enable + b"\x1b[?69l"),
                    ])
        for rows in range(1, 5):
            vertical_regions: list[tuple[int, int] | None] = [None]
            vertical_regions.extend(
                (top, bottom)
                for top in range(1, rows + 1)
                for bottom in range(top + 1, rows + 1)
            )
            marker_setups: list[tuple[str, bytes]] = [("blank", b"")]
            narrow_setup = [b"\x1b[?7l"]
            wide_setup = [b"\x1b[?7l"]
            for marker_row in range(1, rows + 1):
                narrow_setup.extend([
                    f"\x1b[{marker_row};1H".encode(),
                    bytes([64 + marker_row]) * cols,
                ])
                wide_content = (wide_markers[marker_row - 1].encode() *
                                (cols // 2))
                if cols == 1:
                    wide_content = wide_markers[marker_row - 1].encode()
                elif cols % 2:
                    wide_content += bytes([96 + marker_row])
                wide_setup.extend([
                    f"\x1b[{marker_row};1H".encode(), wide_content,
                ])
            marker_setups.extend([
                ("narrow", b"".join(narrow_setup)),
                ("wide", b"".join(wide_setup)),
            ])
            for vertical_region in vertical_regions:
                if vertical_region is None:
                    vertical_setup = b""
                    vertical_name = "default"
                else:
                    top, bottom = vertical_region
                    vertical_setup = f"\x1b[{top};{bottom}r".encode()
                    vertical_name = f"v{top}-{bottom}"
                for row in range(1, rows + 1):
                    for geometry_name, edge, geometry_setup in horizontal_geometries:
                        cup = f"\x1b[{row};{edge}H".encode()
                        cursor_states = (
                            ("settled-wrap", b"\x1b[?7h" + cup),
                            ("settled-nowrap", b"\x1b[?7l" + cup),
                            ("pending", b"\x1b[?7h" + cup + b"A"),
                            ("parked", b"\x1b[?7l" + cup + b"A"),
                        )
                        for state_name, cursor_setup in cursor_states:
                            for control_name, control in (
                                ("lf", b"\n"),
                                ("ind", b"\x1bD"),
                                ("ri", b"\x1bM"),
                            ):
                                for marker_name, marker_setup in marker_setups:
                                    payload = b"".join([
                                        marker_setup, vertical_setup,
                                        geometry_setup, cursor_setup, control,
                                    ])
                                    name = (f"audit-lf-ri-c{cols}-r{rows}-"
                                            f"{vertical_name}-y{row}-"
                                            f"{geometry_name}-{state_name}-"
                                            f"{control_name}-{marker_name}")
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def active_edge_print_setup_matrix_cases() -> Iterator[Case]:
    """Isolate active-margin wraps below the vertical scroll region.

    These are the 1,155 setup-divergent cases separated from the broader
    LF/IND/RI audit.  Axes: widths 2...6; every internal horizontal margin;
    heights 3...4; every vertical region/cursor pair with the cursor below the
    region; narrow and width-two row markers; the one blank-content geometry
    whose cursor move is directly observable; and LF, IND, or RI as an
    observer after the common autowrap-on physical-edge print prefix.
    """
    wide_markers = ("\u65e5", "\u754c", "\u8a9e", "\u672c")
    controls = (("lf", b"\n"), ("ind", b"\x1bD"), ("ri", b"\x1bM"))
    for cols in range(2, 7):
        for left in range(1, cols + 1):
            for right in range(left, cols):
                margin_setup = (b"\x1b[?69h" +
                                f"\x1b[{left};{right}s".encode())
                for rows in range(3, 5):
                    narrow_setup = [b"\x1b[?7l"]
                    wide_setup = [b"\x1b[?7l"]
                    for marker_row in range(1, rows + 1):
                        narrow_setup.extend([
                            f"\x1b[{marker_row};1H".encode(),
                            bytes([64 + marker_row]) * cols,
                        ])
                        wide_content = (wide_markers[marker_row - 1].encode() *
                                        (cols // 2))
                        if cols % 2:
                            wide_content += bytes([96 + marker_row])
                        wide_setup.extend([
                            f"\x1b[{marker_row};1H".encode(), wide_content,
                        ])
                    marker_setups: list[tuple[str, bytes]] = [
                        ("narrow", b"".join(narrow_setup)),
                        ("wide", b"".join(wide_setup)),
                    ]
                    vertical_cases = [
                        (top, bottom, row)
                        for top in range(1, rows + 1)
                        for bottom in range(top + 1, rows + 1)
                        for row in range(bottom + 1, rows + 1)
                    ]
                    for top, bottom, row in vertical_cases:
                        variants = list(marker_setups)
                        if rows == 4 and top == 1 and bottom == 2 and row == 3:
                            variants.append(("blank", b""))
                        vertical_setup = f"\x1b[{top};{bottom}r".encode()
                        source = (b"\x1b[?7h" +
                                  f"\x1b[{row};{cols}H".encode() + b"A")
                        for marker_name, marker_setup in variants:
                            for control_name, control in controls:
                                payload = (marker_setup + vertical_setup +
                                           margin_setup + source + control)
                                name = (f"audit-active-edge-print-c{cols}-r{rows}-"
                                        f"v{top}-{bottom}-y{row}-m{left}-{right}-"
                                        f"{marker_name}-{control_name}")
                                yield Case(name, cols, rows, payload,
                                           (len(payload),), None)


def declrmm_normalization_matrix_cases() -> Iterator[Case]:
    """Audit DECSLRM endpoint normalization and subsequent CR behavior.

    Axes: widths 2...6; every requested endpoint in 1...width+2;
    settled cursors at every physical column; and wrap-pending at the physical
    edge.  Each request is followed by CR so stored horizontal geometry is
    observable through the public cursor.  Cardinality: 1,070.
    """
    for cols in range(2, 7):
        for left in range(1, cols + 3):
            for right in range(1, cols + 3):
                margin_request = f"\x1b[{left};{right}s".encode()
                for cursor_col in range(1, cols + 1):
                    payload = b"".join([
                        b"\x1b[?69h",
                        f"\x1b[1;{cursor_col}H".encode(),
                        margin_request,
                        b"\r",
                    ])
                    name = (f"audit-declrmm-normalization-c{cols}-"
                            f"m{left}-{right}-settled-x{cursor_col}")
                    yield Case(name, cols, 1, payload, (len(payload),), None)
                pending_payload = b"".join([
                    b"\x1b[?69h",
                    f"\x1b[1;{cols}H".encode(),
                    b"A",
                    margin_request,
                    b"\r",
                ])
                pending_name = (f"audit-declrmm-normalization-c{cols}-"
                                f"m{left}-{right}-pending")
                yield Case(pending_name, cols, 1, pending_payload,
                           (len(pending_payload),), None)


def cuf_after_edge_matrix_cases() -> Iterator[Case]:
    """Audit CUF after a print reaches a physical or stored right edge.

    Axes: widths 1...6; physical geometry plus every active horizontal-margin
    pair; explicit CUF counts 0...width+1; autowrap enabled or disabled; and
    ASCII narrow, non-ASCII narrow, combining, wide, and emoji-ZWJ followers.
    Cardinality: 4,110.
    """
    followers = (
        ("ascii", b"B"),
        ("unicode", "\u00e9".encode()),
        ("combining", "\u0301".encode()),
        ("wide", "\u65e5".encode()),
        ("emoji-zwj", "\U0001f469\u200d\U0001f4bb".encode()),
    )
    for cols in range(1, 7):
        geometries: list[tuple[str, int, bytes]] = [
            ("physical", cols, b""),
        ]
        geometries.extend(
            (
                f"margin-{left}-{right}",
                right,
                b"\x1b[?69h" + f"\x1b[{left};{right}s".encode(),
            )
            for left in range(1, cols + 1)
            for right in range(left, cols + 1)
        )
        for geometry_name, right, geometry_setup in geometries:
            for autowrap in (True, False):
                wrap_setup = b"\x1b[?7h" if autowrap else b"\x1b[?7l"
                for count in range(0, cols + 2):
                    for follower_name, follower in followers:
                        payload = b"".join([
                            geometry_setup,
                            wrap_setup,
                            f"\x1b[1;{right}H".encode(),
                            b"A",
                            f"\x1b[{count}C".encode(),
                            follower,
                        ])
                        name = (f"audit-cuf-edge-c{cols}-{geometry_name}-"
                                f"wrap{int(autowrap)}-n{count}-{follower_name}")
                        yield Case(name, cols, 2, payload,
                                   (len(payload),), None)


def cht_after_edge_matrix_cases() -> Iterator[Case]:
    """Audit CHT after a cursor reaches a physical or stored right edge.

    Axes: widths 1...6; physical geometry plus every active or hidden
    horizontal-margin pair; settled, wrap-pending, and no-wrap parked edge
    states; ASCII, non-ASCII, and decomposed width-one source graphemes;
    default, one, two, and width-plus-one CHT counts (deduplicated); and ASCII,
    non-ASCII, decomposed, combining, wide, or emoji-ZWJ followers.
    Cardinality: 25,326.
    """
    sources = (
        ("ascii", b"A"),
        ("unicode", "\u00e9".encode()),
        ("decomposed", "A\u0301".encode()),
    )
    followers = (
        ("ascii", b"B"),
        ("unicode", "\u00e9".encode()),
        ("decomposed", "A\u0301".encode()),
        ("combining", "\u0301".encode()),
        ("wide", "\u65e5".encode()),
        ("emoji-zwj", "\U0001f469\u200d\U0001f4bb".encode()),
    )
    for cols in range(1, 7):
        geometries: list[tuple[str, bytes, int]] = [
            ("physical", b"", cols),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                geometries.extend((
                    (f"active-{left}-{right}", stored, right),
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l", cols),
                ))
        counts = sorted({0, 1, 2, cols + 1})
        for geometry_name, geometry_setup, edge in geometries:
            position = f"\x1b[1;{edge}H".encode()
            for source_name, source in sources:
                states = (
                    ("settled", b"\x1b[?7h" + position + source + position),
                    ("pending", b"\x1b[?7h" + position + source),
                    ("parked", b"\x1b[?7l" + position + source),
                )
                for state_name, state_setup in states:
                    for count in counts:
                        move = f"\x1b[{count}I".encode()
                        for follower_name, follower in followers:
                            payload = (geometry_setup + state_setup + move +
                                       follower)
                            name = (f"audit-cht-edge-c{cols}-{geometry_name}-"
                                    f"{state_name}-{source_name}-n{count}-"
                                    f"{follower_name}")
                            yield Case(name, cols, 2, payload,
                                       (len(payload),), None)


def cht_after_edge_representative_cases() -> Iterator[Case]:
    """Compact deterministic controls for CHT's right-edge state change."""
    selected = (
        ("cht-edge-width-one-pending-unicode-control",
         "audit-cht-edge-c1-physical-pending-ascii-n0-unicode"),
        ("cht-edge-pending-unicode-minimum",
         "audit-cht-edge-c2-physical-pending-ascii-n0-unicode"),
        ("cht-edge-pending-unicode-explicit-two",
         "audit-cht-edge-c2-physical-pending-ascii-n2-unicode"),
        ("cht-active-internal-edge-pending-unicode",
         "audit-cht-edge-c3-active-1-2-pending-ascii-n2-unicode"),
        ("cht-hidden-internal-margin-physical-edge-pending-unicode",
         "audit-cht-edge-c3-hidden-1-2-pending-ascii-n2-unicode"),
        ("cht-edge-settled-unicode-control",
         "audit-cht-edge-c2-physical-settled-ascii-n2-unicode"),
        ("cht-edge-parked-unicode-control",
         "audit-cht-edge-c2-physical-parked-ascii-n2-unicode"),
        ("cht-edge-pending-ascii-control",
         "audit-cht-edge-c2-physical-pending-ascii-n2-ascii"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in cht_after_edge_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing CHT edge controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def semantic_block_resize_edge_matrix_cases() -> Iterator[Case]:
    """Audit semantic block rows after edge-state printing and resize.

    Axes: widths 1...6; heights 1...4 and every source row; physical
    geometry plus every active or hidden horizontal-margin pair; settled,
    wrap-pending, and no-wrap parked source states; ASCII, non-ASCII narrow,
    and wide followers; and neighboring shrink, unchanged, or grow resize
    widths (deduplicated).  Resize height is unchanged.  Cardinality: 31,590.
    """
    prompt = b"\x1b]133;A\x07"
    command = b"\x1b]133;C\x07"
    followers = (
        ("ascii", b"B"),
        ("unicode", "\u00e9".encode()),
        ("wide", "\u65e5".encode()),
    )
    for cols in range(1, 7):
        geometries: list[tuple[str, bytes, int]] = [
            ("physical", b"", cols),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                geometries.extend((
                    (f"active-{left}-{right}", stored, right),
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l", cols),
                ))
        resize_widths = sorted({max(1, cols - 1), cols, cols + 1})
        for rows in range(1, 5):
            for source_row in range(1, rows + 1):
                for geometry_name, geometry_setup, edge in geometries:
                    position = f"\x1b[{source_row};{edge}H".encode()
                    states = (
                        ("settled", b"\x1b[?7h" + position),
                        ("pending", b"\x1b[?7h" + position + b"A"),
                        ("parked", b"\x1b[?7l" + position + b"A"),
                    )
                    for state_name, state_setup in states:
                        for follower_name, follower in followers:
                            payload = (geometry_setup + prompt + state_setup +
                                       command + follower)
                            for resize_width in resize_widths:
                                name = (
                                    f"audit-semantic-resize-c{cols}-r{rows}-"
                                    f"{geometry_name}-y{source_row}-"
                                    f"{state_name}-{follower_name}-"
                                    f"w{resize_width}"
                                )
                                yield Case(name, cols, rows, payload,
                                           (len(payload),),
                                           (resize_width, rows))


def semantic_block_resize_edge_representative_cases() -> Iterator[Case]:
    """Compact controls for semantic block rows across edge-state resize."""
    selected = (
        ("semantic-resize-width-one-control",
         "audit-semantic-resize-c1-r2-active-1-1-y2-pending-ascii-w2"),
        ("semantic-resize-minimum",
         "audit-semantic-resize-c2-r2-active-1-1-y2-pending-ascii-w3"),
        ("semantic-resize-unicode-follower",
         "audit-semantic-resize-c2-r2-active-1-1-y2-pending-unicode-w3"),
        ("semantic-resize-wide-follower",
         "audit-semantic-resize-c2-r2-active-1-1-y2-pending-wide-w3"),
        ("semantic-resize-shrink-reference-steady",
         "audit-semantic-resize-c3-r2-active-1-1-y2-pending-ascii-w2"),
        ("semantic-resize-shrink-reference-advance",
         "audit-semantic-resize-c3-r2-active-2-3-y2-pending-ascii-w2"),
        ("semantic-resize-shrink-settled-wide",
         "audit-semantic-resize-c3-r2-active-1-1-y2-settled-wide-w2"),
        ("semantic-resize-nonbottom-control",
         "audit-semantic-resize-c2-r2-active-1-1-y1-pending-ascii-w3"),
        ("semantic-resize-settled-control",
         "audit-semantic-resize-c2-r2-active-1-1-y2-settled-ascii-w3"),
        ("semantic-resize-parked-control",
         "audit-semantic-resize-c2-r2-active-1-1-y2-parked-ascii-w3"),
        ("semantic-resize-unchanged-width-control",
         "audit-semantic-resize-c2-r2-active-1-1-y2-pending-ascii-w2"),
        ("semantic-resize-hidden-margin-control",
         "audit-semantic-resize-c2-r2-hidden-1-1-y2-pending-ascii-w3"),
        ("semantic-resize-physical-control",
         "audit-semantic-resize-c2-r2-physical-y2-pending-ascii-w3"),
        ("semantic-resize-active-full-control",
         "audit-semantic-resize-c2-r2-active-1-2-y2-pending-ascii-w3"),
        ("semantic-resize-aligned-edge-control",
         "audit-semantic-resize-c3-r2-active-1-2-y2-pending-ascii-w2"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_block_resize_edge_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic resize controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def semantic_cursor_resize_representative_cases() -> Iterator[Case]:
    """One fixed control for each observed reference cursor transition shape."""
    selected = (
        ("semantic-cursor-shape-01",
         "audit-semantic-resize-c1-r1-physical-y1-pending-ascii-w2"),
        ("semantic-cursor-shape-02",
         "audit-semantic-resize-c1-r1-physical-y1-settled-wide-w2"),
        ("semantic-cursor-shape-03",
         "audit-semantic-resize-c2-r2-active-1-1-y1-pending-ascii-w3"),
        ("semantic-cursor-shape-04",
         "audit-semantic-resize-c3-r2-active-1-2-y1-pending-ascii-w4"),
        ("semantic-cursor-shape-05",
         "audit-semantic-resize-c4-r2-active-1-3-y1-pending-ascii-w5"),
        ("semantic-cursor-shape-06",
         "audit-semantic-resize-c5-r2-active-1-4-y1-pending-ascii-w6"),
        ("semantic-cursor-shape-07",
         "audit-semantic-resize-c6-r2-active-1-5-y1-pending-ascii-w7"),
        ("semantic-cursor-shape-08",
         "audit-semantic-resize-c6-r2-active-3-3-y1-pending-wide-w7"),
        ("semantic-cursor-shape-09",
         "audit-semantic-resize-c4-r2-active-2-2-y1-pending-wide-w5"),
        ("semantic-cursor-shape-10",
         "audit-semantic-resize-c2-r2-active-1-1-y1-pending-wide-w3"),
        ("semantic-cursor-shape-11",
         "audit-semantic-resize-c1-r2-physical-y1-pending-ascii-w2"),
        ("semantic-cursor-shape-12",
         "audit-semantic-resize-c1-r1-physical-y1-settled-ascii-w2"),
        ("semantic-cursor-shape-13",
         "audit-semantic-resize-c1-r1-physical-y1-pending-ascii-w1"),
        ("semantic-cursor-shape-14",
         "audit-semantic-resize-c1-r1-physical-y1-settled-wide-w1"),
        ("semantic-cursor-shape-15",
         "audit-semantic-resize-c1-r2-physical-y1-pending-ascii-w1"),
        ("semantic-cursor-shape-16",
         "audit-semantic-resize-c1-r1-physical-y1-settled-ascii-w1"),
        ("semantic-cursor-shape-17",
         "audit-semantic-resize-c3-r1-physical-y1-settled-wide-w2"),
        ("semantic-cursor-shape-18",
         "audit-semantic-resize-c4-r1-physical-y1-settled-wide-w3"),
        ("semantic-cursor-shape-19",
         "audit-semantic-resize-c4-r2-active-1-1-y1-pending-ascii-w3"),
        ("semantic-cursor-shape-20",
         "audit-semantic-resize-c5-r2-active-1-2-y1-pending-ascii-w4"),
        ("semantic-cursor-shape-21",
         "audit-semantic-resize-c6-r2-active-1-3-y1-pending-ascii-w5"),
        ("semantic-cursor-shape-22",
         "audit-semantic-resize-c6-r1-active-1-5-y1-settled-ascii-w5"),
        ("semantic-cursor-shape-23",
         "audit-semantic-resize-c5-r1-active-1-4-y1-settled-ascii-w4"),
        ("semantic-cursor-shape-24",
         "audit-semantic-resize-c4-r1-active-1-3-y1-settled-ascii-w3"),
        ("semantic-cursor-shape-25",
         "audit-semantic-resize-c3-r1-active-1-1-y1-settled-wide-w2"),
        ("semantic-cursor-shape-26",
         "audit-semantic-resize-c3-r1-physical-y1-pending-ascii-w2"),
        ("semantic-cursor-shape-27",
         "audit-semantic-resize-c2-r1-physical-y1-settled-ascii-w1"),
        ("semantic-cursor-shape-28",
         "audit-semantic-resize-c4-r1-physical-y1-pending-ascii-w3"),
        ("semantic-cursor-shape-29",
         "audit-semantic-resize-c6-r1-physical-y1-settled-ascii-w5"),
        ("semantic-cursor-shape-30",
         "audit-semantic-resize-c5-r1-physical-y1-settled-ascii-w4"),
        ("semantic-cursor-shape-31",
         "audit-semantic-resize-c3-r2-active-2-3-y1-pending-wide-w2"),
        ("semantic-cursor-shape-32",
         "audit-semantic-resize-c3-r1-physical-y1-settled-ascii-w2"),
        ("semantic-cursor-shape-33",
         "audit-semantic-resize-c3-r2-active-2-3-y1-pending-ascii-w2"),
        ("semantic-cursor-shape-34",
         "audit-semantic-resize-c4-r2-active-2-4-y2-pending-ascii-w3"),
        ("semantic-cursor-shape-35",
         "audit-semantic-resize-c6-r2-active-6-6-y2-pending-ascii-w5"),
        ("semantic-cursor-shape-36",
         "audit-semantic-resize-c5-r2-active-5-5-y2-pending-ascii-w4"),
        ("semantic-cursor-shape-37",
         "audit-semantic-resize-c3-r3-active-2-3-y1-pending-wide-w2"),
        ("semantic-cursor-shape-38",
         "audit-semantic-resize-c3-r2-active-3-3-y2-pending-ascii-w2"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_block_resize_edge_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic cursor controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def semantic_resize_history_matrix_cases() -> Iterator[Case]:
    """Audit persistence of an active-margin bottom-wrap boundary.

    The boundary is followed by bounded same-row print histories or one
    interposed cursor/edit/mode/semantic control before a neighboring width
    resize.  Widths 3...6, heights 2...3, representative left/right/internal
    partial margins, pending-narrow or settled-wide boundary creation, all
    0...margin-width ASCII/non-ASCII/wide follower counts, and 22 controls
    produce 4,632 cases.
    """
    prompt = b"\x1b]133;A\x07"
    command = b"\x1b]133;C\x07"
    wide = "\U0001f680".encode()
    follower_kinds = (
        ("ascii", b"C"),
        ("unicode", "\u00e9".encode()),
        ("wide", "\u65e5".encode()),
    )
    for cols in range(3, 7):
        margins = [(1, cols - 1), (2, cols)]
        if cols >= 4:
            margins.append((2, cols - 1))
        resize_widths = (cols - 1, cols, cols + 1)
        for rows in range(2, 4):
            for left, right in margins:
                stored = b"\x1b[?69h" + f"\x1b[{left};{right}s".encode()
                position = f"\x1b[{rows};{right}H".encode()
                margin_width = right - left + 1
                boundary_states = (
                    ("pending-narrow", position + b"A", b"B"),
                    ("settled-wide", position, wide),
                )
                controls = (
                    ("backspace", b"\b"),
                    ("tab", b"\t"),
                    ("carriage-return", b"\r"),
                    ("line-feed", b"\n"),
                    ("index", b"\x1bD"),
                    ("reverse-index", b"\x1bM"),
                    ("cursor-up", b"\x1b[2A"),
                    ("cursor-down", b"\x1b[2B"),
                    ("cursor-forward", b"\x1b[2C"),
                    ("cursor-back", b"\x1b[2D"),
                    ("cursor-home", b"\x1b[H"),
                    ("cursor-bottom-left", f"\x1b[{rows};{left}H".encode()),
                    ("erase-char", b"\x1b[2X"),
                    ("erase-line", b"\x1b[K"),
                    ("erase-display", b"\x1b[J"),
                    ("insert-char", b"\x1b[2@"),
                    ("delete-char", b"\x1b[2P"),
                    ("semantic-marker", b"\x1b]133;B\x07"),
                    ("margin-hide", b"\x1b[?69l"),
                    ("margin-hide-show", b"\x1b[?69l\x1b[?69h"),
                    ("margin-full", f"\x1b[1;{cols}s".encode()),
                    ("style", b"\x1b[1m"),
                )
                histories = []
                for follower_name, follower in follower_kinds:
                    for count in range(margin_width + 1):
                        histories.append((f"{follower_name}-n{count}",
                                          follower * count))
                histories.extend((f"control-{name}", payload)
                                 for name, payload in controls)
                for state_name, state_setup, boundary in boundary_states:
                    prefix = stored + prompt + state_setup + command + boundary
                    for history_name, history in histories:
                        payload = prefix + history
                        for resize_width in resize_widths:
                            name = (
                                f"audit-semantic-history-c{cols}-r{rows}-"
                                f"m{left}-{right}-{state_name}-"
                                f"{history_name}-w{resize_width}"
                            )
                            yield Case(name, cols, rows, payload,
                                       (len(payload),),
                                       (resize_width, rows))


def semantic_resize_history_representative_cases() -> Iterator[Case]:
    """Compact persistence controls for the residual random-126 history."""
    minimized_random_0126 = bytes.fromhex(
        "1b5b3f3639681b5d31333341071b5b3b39731b5b36485a"
        "1b5d313333430768f09f9a803620f09f9a80f09f9a8030"
    )
    yield Case("random-0126-block-history-residual", 13, 6,
               minimized_random_0126, (len(minimized_random_0126),),
               (11, 10))
    selected = (
        ("semantic-history-immediate",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-ascii-n0-w4"),
        ("semantic-history-one-narrow",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-ascii-n1-w4"),
        ("semantic-history-row-changing-narrow",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-ascii-n2-w4"),
        ("semantic-history-one-unicode",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-unicode-n1-w4"),
        ("semantic-history-one-wide",
         "audit-semantic-history-c4-r2-m1-3-pending-narrow-wide-n1-w5"),
        ("semantic-history-settled-wide-one-narrow",
         "audit-semantic-history-c3-r2-m1-2-settled-wide-ascii-n1-w4"),
        ("semantic-history-cursor-motion",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-control-cursor-up-w4"),
        ("semantic-history-erase",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-control-erase-char-w4"),
        ("semantic-history-margin-hidden",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-control-margin-hide-w4"),
        ("semantic-history-semantic-marker",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-control-semantic-marker-w4"),
        ("semantic-history-aligned-resize",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-ascii-n1-w2"),
        ("semantic-history-same-width",
         "audit-semantic-history-c3-r2-m1-2-pending-narrow-ascii-n1-w3"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_resize_history_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic history controls: {missing}")
    for name, source in selected:
        case = found[source]
        resize = case.resize
        if name == "semantic-history-one-narrow":
            # Also retain the original residual's independently varying-height
            # shape without changing the matrix cardinality or random stream.
            yield Case("semantic-history-one-narrow-height-grow",
                       case.cols, case.rows, case.payload, case.chunks,
                       (resize[0], case.rows + 1) if resize else None)
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, resize)


def semantic_resize_multi_history_matrix_cases() -> Iterator[Case]:
    """Audit multiple row-scoped rectangular-wrap reflow boundaries.

    Events are created at repeated, ascending, descending, and revisited
    vertical-region bottoms so more than one physical Line can own a boundary.
    Bounded intervening prints/semantic controls and per-row erase/insert/delete
    histories precede neighboring shrink/same/grow resizes. Cardinality: 7,200.
    """
    prompt = b"\x1b]133;A\x07"
    command = b"\x1b]133;C\x07"
    wide = "\U0001f680".encode()
    dimensions = []
    for cols in (4, 6):
        for rows in (3, 4):
            dimensions.extend((
                (cols, rows, 1, cols - 1),
                (cols, rows, 2, cols),
            ))
    for rows in (3, 4):
        dimensions.append((5, rows, 2, 4))

    for cols, rows, left, right in dimensions:
        stored = b"\x1b[?69h" + f"\x1b[{left};{right}s".encode()
        paths = (
            ("single", (rows,)),
            ("repeat", (rows, rows)),
            ("ascending", tuple(range(2, rows + 1))),
            ("descending", tuple(range(rows, 1, -1))),
            ("revisit", (2, rows, 2)),
        )
        boundary_states = (
            ("pending-narrow", b"A", b"B"),
            ("settled-wide", b"", wide),
        )
        interposed = (
            ("none", b""),
            ("narrow", b"C"),
            ("wide", "\u65e5".encode()),
            ("semantic", b"\x1b]133;B\x07"),
        )
        for path_name, bottoms in paths:
            for state_name, source, boundary in boundary_states:
                for interposed_name, interposed_payload in interposed:
                    events = []
                    for event_index, bottom in enumerate(bottoms):
                        region = f"\x1b[1;{bottom}r".encode()
                        position = f"\x1b[{bottom};{right}H".encode()
                        events.append(region + position + prompt + source
                                      + command + boundary)
                        if event_index + 1 < len(bottoms):
                            events.append(interposed_payload)
                    prefix = stored + b"".join(events)
                    first_row = bottoms[0]
                    last_row = bottoms[-1]
                    resets = (
                        ("none", b""),
                        ("erase-first", f"\x1b[{first_row};{left}H".encode()
                         + b"\x1b[2K"),
                        ("erase-last", f"\x1b[{last_row};{left}H".encode()
                         + b"\x1b[2K"),
                        ("insert-first", f"\x1b[{first_row};{left}H".encode()
                         + b"\x1b[L"),
                        ("delete-first", f"\x1b[{first_row};{left}H".encode()
                         + b"\x1b[M"),
                        ("margin-toggle", b"\x1b[?69l\x1b[?69h"),
                    )
                    for reset_name, reset_payload in resets:
                        payload = prefix + reset_payload
                        for resize_width in (cols - 1, cols, cols + 1):
                            name = (
                                f"audit-semantic-multi-c{cols}-r{rows}-"
                                f"m{left}-{right}-{path_name}-{state_name}-"
                                f"{interposed_name}-{reset_name}-w{resize_width}"
                            )
                            yield Case(name, cols, rows, payload,
                                       (len(payload),),
                                       (resize_width, rows))


def semantic_resize_multi_history_representative_cases() -> Iterator[Case]:
    """Compact controls for every multi-boundary history branch."""
    selected = (
        ("semantic-multi-single-control",
         "audit-semantic-multi-c4-r3-m1-3-single-pending-narrow-none-none-w5"),
        ("semantic-multi-repeat-control",
         "audit-semantic-multi-c4-r3-m1-3-repeat-pending-narrow-none-none-w5"),
        ("semantic-multi-ascending-control",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-none-w5"),
        ("semantic-multi-descending-control",
         "audit-semantic-multi-c4-r3-m1-3-descending-pending-narrow-none-none-w5"),
        ("semantic-multi-revisit-control",
         "audit-semantic-multi-c4-r3-m1-3-revisit-pending-narrow-none-none-w5"),
        ("semantic-multi-settled-wide-control",
         "audit-semantic-multi-c4-r3-m1-3-ascending-settled-wide-none-none-w5"),
        ("semantic-multi-interposed-narrow",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-narrow-none-w5"),
        ("semantic-multi-interposed-wide",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-wide-none-w5"),
        ("semantic-multi-interposed-semantic",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-semantic-none-w5"),
        ("semantic-multi-erase-first",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-erase-first-w5"),
        ("semantic-multi-erase-last",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-erase-last-w5"),
        ("semantic-multi-insert-first",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-insert-first-w5"),
        ("semantic-multi-delete-first",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-delete-first-w5"),
        ("semantic-multi-margin-toggle",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-margin-toggle-w5"),
        ("semantic-multi-shrink",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-none-w3"),
        ("semantic-multi-same-width",
         "audit-semantic-multi-c4-r3-m1-3-ascending-pending-narrow-none-none-w4"),
        ("semantic-multi-right-aligned",
         "audit-semantic-multi-c4-r3-m2-4-ascending-pending-narrow-none-none-w3"),
        ("semantic-multi-internal-margin",
         "audit-semantic-multi-c5-r4-m2-4-descending-settled-wide-semantic-none-w6"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_resize_multi_history_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic multi-history controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def semantic_prewrapped_destination_matrix_cases() -> Iterator[Case]:
    """Audit partial-width scroll replacement of pre-wrapped rows.

    Axes: widths 3, 4, and 6; heights 3 and 4; representative left,
    internal, right, and full horizontal margins; full-height and inset
    vertical regions of height 2...4; wrapped or unwrapped destination rows;
    changed or byte-identical destination/source slices; pending-narrow,
    pending-wide, settled-wide, and no-cross bottom-edge states; one or two
    events; and neighboring shrink, same, or grow resizes.  Cardinality:
    14,400.
    """
    prompt = b"\x1b]133;A\x07"
    command = b"\x1b]133;C\x07"
    wide = "\u65e5".encode()

    for cols in (3, 4, 6):
        margins = sorted({
            (1, 1),
            (2, 2),
            (cols, cols),
            (1, 2),
            (2, 3),
            (cols - 1, cols),
            (1, cols - 1),
            (2, cols),
            (2, cols - 1),
            (1, cols),
        })
        for rows in (3, 4):
            regions = sorted({
                (1, rows, 2),
                (1, rows, rows - 1),
                (2, rows, 2),
                (2, rows - 1, max(2, rows - 2)),
            })
            regions = [entry for entry in regions
                       if entry[0] <= entry[2] < entry[1] <= rows]
            for left, right in margins:
                margin_width = right - left + 1
                margin_setup = (b"\x1b[?69h" +
                                f"\x1b[{left};{right}s".encode())
                for top, bottom, destination in regions:
                    wrapped_setup = b"".join([
                        f"\x1b[{destination - 1};{cols}H".encode(),
                        b"A",
                        b"a",
                    ])
                    unwrapped_setup = (
                        f"\x1b[{destination};1H".encode() + b"a"
                    )
                    topologies = (
                        ("prewrapped", wrapped_setup),
                        ("unwrapped", unwrapped_setup),
                    )
                    slice_modes = (
                        ("replaced", b"D" * margin_width,
                         b"S" * margin_width),
                        ("unchanged", b"U" * margin_width,
                         b"U" * margin_width),
                    )
                    boundary_states = (
                        ("pending-narrow", b"AB", True),
                        ("pending-wide", b"A" + wide, True),
                        ("settled-wide", wide, True),
                        ("no-cross", b"A", False),
                    )
                    region_setup = f"\x1b[{top};{bottom}r".encode()
                    destination_position = (
                        f"\x1b[{destination};{left}H".encode()
                    )
                    source_position = (
                        f"\x1b[{destination + 1};{left}H".encode()
                    )
                    edge_position = f"\x1b[{bottom};{right}H".encode()
                    for topology_name, topology_setup in topologies:
                        semantic_setup = topology_setup + prompt + command
                        for slice_name, destination_slice, source_slice in slice_modes:
                            slice_setup = b"".join([
                                destination_position,
                                destination_slice,
                                source_position,
                                source_slice,
                            ])
                            for state_name, boundary, _crosses in boundary_states:
                                for repeat_count in (1, 2):
                                    events = (edge_position + boundary) * repeat_count
                                    payload = b"".join([
                                        semantic_setup,
                                        slice_setup,
                                        margin_setup,
                                        region_setup,
                                        events,
                                    ])
                                    for resize_width in (cols - 1, cols, cols + 1):
                                        name = (
                                            f"audit-semantic-prewrapped-c{cols}-r{rows}-"
                                            f"m{left}-{right}-v{top}-{bottom}-"
                                            f"d{destination}-{topology_name}-{slice_name}-"
                                            f"{state_name}-n{repeat_count}-w{resize_width}"
                                        )
                                        yield Case(name, cols, rows, payload,
                                                   (len(payload),),
                                                   (resize_width, rows))


def semantic_prewrapped_destination_representative_cases() -> Iterator[Case]:
    """Compact controls for every pre-wrapped destination branch."""
    selected = (
        ("semantic-prewrapped-grow",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-prewrapped-replaced-pending-narrow-n1-w4"),
        ("semantic-prewrapped-shrink",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-prewrapped-replaced-pending-narrow-n1-w2"),
        ("semantic-prewrapped-pending-wide",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-prewrapped-replaced-pending-wide-n1-w4"),
        ("semantic-prewrapped-settled-wide",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-prewrapped-replaced-settled-wide-n1-w4"),
        ("semantic-prewrapped-repeat",
         "audit-semantic-prewrapped-c4-r4-m2-3-v1-4-d2-prewrapped-replaced-pending-narrow-n2-w5"),
        ("semantic-prewrapped-unchanged-slice",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-prewrapped-unchanged-pending-narrow-n1-w4"),
        ("semantic-prewrapped-unwrapped-control",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-unwrapped-replaced-pending-narrow-n1-w4"),
        ("semantic-prewrapped-no-cross-control",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-prewrapped-replaced-no-cross-n1-w4"),
        ("semantic-prewrapped-same-width-control",
         "audit-semantic-prewrapped-c3-r3-m2-2-v1-3-d2-prewrapped-replaced-pending-narrow-n1-w3"),
        ("semantic-prewrapped-full-width-control",
         "audit-semantic-prewrapped-c3-r3-m1-3-v1-3-d2-prewrapped-replaced-pending-narrow-n1-w4"),
        ("semantic-prewrapped-region-height-two-control",
         "audit-semantic-prewrapped-c3-r3-m2-2-v2-3-d2-prewrapped-replaced-pending-narrow-n1-w4"),
        ("semantic-prewrapped-inset-region",
         "audit-semantic-prewrapped-c4-r4-m2-3-v2-4-d2-prewrapped-replaced-pending-narrow-n1-w5"),
        ("semantic-prewrapped-last-destination",
         "audit-semantic-prewrapped-c4-r4-m2-3-v1-4-d3-prewrapped-replaced-pending-narrow-n1-w5"),
        ("semantic-prewrapped-left-margin",
         "audit-semantic-prewrapped-c4-r4-m1-2-v1-4-d2-prewrapped-replaced-pending-narrow-n1-w5"),
        ("semantic-prewrapped-right-margin",
         "audit-semantic-prewrapped-c4-r4-m3-4-v1-4-d2-prewrapped-replaced-pending-narrow-n1-w5"),
        ("semantic-prewrapped-internal-width-one",
         "audit-semantic-prewrapped-c6-r4-m2-2-v1-4-d2-prewrapped-replaced-pending-narrow-n1-w7"),
        ("semantic-prewrapped-internal-wide",
         "audit-semantic-prewrapped-c6-r4-m2-5-v1-4-d2-prewrapped-replaced-pending-narrow-n1-w7"),
        ("semantic-prewrapped-repeat-no-cross-control",
         "audit-semantic-prewrapped-c4-r4-m2-3-v1-4-d2-prewrapped-replaced-no-cross-n2-w5"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_prewrapped_destination_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic prewrapped controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def semantic_prewrapped_destination_observer_cases() -> Iterator[Case]:
    """Follow-on controls for the 16 coincident two-event public snapshots.

    Each source shape is observationally equal after its one-column growth.
    The paired neighboring-width observation exposes the retained topology.
    Cardinality: 16.
    """
    source_names: list[str] = []
    for cols in (4, 6):
        for rows in (3, 4):
            regions = sorted({
                (1, rows, 2),
                (1, rows, rows - 1),
                (2, rows, 2),
                (2, rows - 1, max(2, rows - 2)),
            })
            regions = [entry for entry in regions
                       if entry[0] <= entry[2] < entry[1] <= rows]
            for top, bottom, destination in regions:
                if destination != bottom - 1:
                    continue
                for slice_name in ("replaced", "unchanged"):
                    source_names.append(
                        f"audit-semantic-prewrapped-c{cols}-r{rows}-"
                        f"m1-{cols - 1}-v{top}-{bottom}-d{destination}-"
                        f"prewrapped-{slice_name}-pending-wide-n2-w{cols + 1}"
                    )
    wanted = set(source_names)
    found: dict[str, Case] = {}
    for case in semantic_prewrapped_destination_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic prewrapped observers: {missing}")
    for index, source in enumerate(source_names, 1):
        case = found[source]
        yield Case(f"semantic-prewrapped-follow-on-{index:02d}",
                   case.cols, case.rows, case.payload, case.chunks,
                   (case.cols - 1, case.rows))


def semantic_line_motion_boundary_matrix_cases() -> Iterator[Case]:
    """Audit wrapped-row topology across explicit vertical line motion.

    Axes: widths 3, 4, and 6; full-height and inset vertical regions;
    every shifted destination row; upward LF/IND, downward RI, printable-wrap,
    and bounded cursor-down controls; one-column, left, right, internal, and
    full horizontal margins; active or hidden horizontal-margin geometry;
    prewrapped or unwrapped destination rows; changed or byte-identical
    shifted slices; semantic anchors on destination or source rows; and
    neighboring shrink, same, or grow resizes. Cardinality: 35,280.
    """
    prompt = b"\x1b]133;A\x07"
    verticals = (
        (3, 1, 3, 2),
        (3, 2, 3, 2),
        (3, 1, 2, 2),
        (4, 1, 4, 2),
        (4, 1, 4, 3),
        (4, 2, 4, 2),
        (4, 2, 4, 3),
        (4, 1, 3, 2),
        (4, 1, 3, 3),
    )
    motions = ("lf", "ind", "ri", "print-wrap", "cud")
    for cols in (3, 4, 6):
        margins = (
            (1, 1),
            (cols, cols),
            (2, 2),
            (1, cols - 1),
            (2, cols),
            (2, cols - 1),
            (1, cols),
        )
        for rows, top, bottom, destination in verticals:
            for motion in motions:
                direction = "down" if motion == "ri" else "up"
                affected = (
                    top <= destination < bottom if direction == "up"
                    else top < destination <= bottom
                )
                if not affected:
                    continue
                source = destination + 1 if direction == "up" else destination - 1
                if not (1 <= source <= rows):
                    continue
                for left, right in margins:
                    for mode in ("active", "hidden"):
                        geometry = b"".join((
                            b"\x1b[?69h",
                            f"\x1b[{left};{right}s".encode(),
                            f"\x1b[{top};{bottom}r".encode(),
                            b"" if mode == "active" else b"\x1b[?69l",
                        ))
                        for topology in ("prewrapped", "unwrapped"):
                            topology_setup = (
                                f"\x1b[{destination - 1};{cols}H".encode() + b"AB"
                                if topology == "prewrapped" else
                                f"\x1b[{destination};1H".encode() + b"U"
                            )
                            for slice_mode in ("replaced", "unchanged"):
                                if slice_mode == "replaced":
                                    destination_cell, source_cell = b"D", b"S"
                                else:
                                    destination_cell = source_cell = b"U"
                                slices = b"".join((
                                    f"\x1b[{destination};{left}H".encode(),
                                    destination_cell,
                                    f"\x1b[{source};{left}H".encode(),
                                    source_cell,
                                ))
                                for marker in ("destination", "source"):
                                    marker_row = (destination if marker == "destination"
                                                  else source)
                                    semantic = (f"\x1b[{marker_row};1H".encode()
                                                + prompt)
                                    if motion == "ri":
                                        event = (f"\x1b[{top};{left}H".encode()
                                                 + b"\x1bM")
                                    elif motion == "lf":
                                        event = (f"\x1b[{bottom};{left}H".encode()
                                                 + b"\n")
                                    elif motion == "ind":
                                        event = (f"\x1b[{bottom};{left}H".encode()
                                                 + b"\x1bD")
                                    elif motion == "cud":
                                        event = (f"\x1b[{bottom};{left}H".encode()
                                                 + b"\x1b[B")
                                    else:
                                        event = (f"\x1b[{bottom};{right}H".encode()
                                                 + b"AB")
                                    payload = b"".join((
                                        topology_setup, slices, semantic,
                                        geometry, event,
                                    ))
                                    for resize_width in (cols - 1, cols, cols + 1):
                                        name = (
                                            f"audit-semantic-line-motion-c{cols}-r{rows}-"
                                            f"v{top}-{bottom}-d{destination}-{motion}-"
                                            f"m{left}-{right}-{mode}-{topology}-"
                                            f"{slice_mode}-{marker}-w{resize_width}"
                                        )
                                        yield Case(name, cols, rows, payload,
                                                   (len(payload),),
                                                   (resize_width, rows))


def semantic_line_motion_boundary_representative_cases() -> Iterator[Case]:
    """Compact controls for every explicit line-motion predictor leaf."""
    selected = (
        ("semantic-line-motion-hidden-control",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-lf-m1-1-hidden-prewrapped-replaced-destination-w4"),
        ("semantic-line-motion-unwrapped-control",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-lf-m1-1-active-unwrapped-replaced-destination-w4"),
        ("semantic-line-motion-print-wrap-control",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-print-wrap-m1-1-active-prewrapped-replaced-destination-w4"),
        ("semantic-line-motion-full-width-control",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-lf-m1-3-active-prewrapped-replaced-destination-w4"),
        ("semantic-line-motion-same-width-control",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-lf-m1-1-active-prewrapped-replaced-destination-w3"),
        ("semantic-line-motion-output-equivalence-control",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-lf-m2-3-active-prewrapped-replaced-destination-w2"),
        ("semantic-line-motion-ind",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-ind-m1-1-active-prewrapped-replaced-destination-w4"),
        ("semantic-line-motion-ri",
         "audit-semantic-line-motion-c3-r3-v1-3-d2-ri-m1-1-active-prewrapped-replaced-destination-w4"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_line_motion_boundary_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic line-motion controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def semantic_line_motion_boundary_observer_cases() -> Iterator[Case]:
    """Expose the 40 shrink-aligned public-output coincidences.

    The source cases use a three-column right margin and shrink to two
    columns. Their public snapshots happen to coincide despite differing
    topology. The neighboring growth observation makes every affected branch
    visible. Cardinality: 40.
    """
    verticals = (
        (3, 1, 3, 2),
        (4, 1, 4, 2),
        (4, 1, 4, 3),
        (4, 2, 4, 3),
        (4, 1, 3, 2),
    )
    source_names: list[str] = []
    for rows, top, bottom, destination in verticals:
        for motion in ("lf", "ind"):
            for slice_mode in ("replaced", "unchanged"):
                for marker in ("destination", "source"):
                    source_names.append(
                        f"audit-semantic-line-motion-c3-r{rows}-"
                        f"v{top}-{bottom}-d{destination}-{motion}-"
                        f"m2-3-active-prewrapped-{slice_mode}-{marker}-w2"
                    )
    wanted = set(source_names)
    found: dict[str, Case] = {}
    for case in semantic_line_motion_boundary_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic line-motion observers: {missing}")
    for index, source in enumerate(source_names, 1):
        case = found[source]
        yield Case(f"semantic-line-motion-follow-on-{index:02d}",
                   case.cols, case.rows, case.payload, case.chunks,
                   (case.cols + 1, case.rows))


def random268_semantic_line_motion_residual_cases() -> Iterator[Case]:
    """Freeze the minimal scrollback-backed semantic-row witness."""
    payload = b"".join((
        b"\x1b[2;6H", b"\n", b"0", b"Z", b" ", b"0", b"\n",
        b"\x1b]133;A\x07", b"\x1b[?69h", b"\x1b[2;9s", b"\n",
    ))
    yield Case("random-0268-semantic-line-motion-residual", 2, 2,
               payload, (len(payload),), (3, 1))


def semantic_later_softwrap_matrix_cases() -> Iterator[Case]:
    """Audit row-boundary witnesses followed by a new incoming soft wrap.

    Axes: widths 4 and 6; full-height and inset vertical regions of height
    3...4; first and last shifted destination rows; left, right, internal,
    one-column, wider, and full horizontal margins; wrapped or unwrapped
    destination topology at scroll time; shifted or exposed-bottom later
    targets; no incoming wrap, narrow incoming wrap, or wide incoming wrap;
    no crossing plus one or two pending-narrow, pending-wide, or settled-wide
    crossings; and neighboring shrink, same, or grow resizes. Cardinality:
    17,640.
    """
    wide = "\u65e5".encode()
    verticals = (
        (3, 1, 3, 2),
        (4, 1, 4, 2),
        (4, 1, 4, 3),
        (4, 2, 4, 2),
        (4, 2, 4, 3),
    )
    event_modes = (
        ("no-cross", b"A", 0),
        ("pending-narrow-1", b"AB", 1),
        ("pending-narrow-2", b"AB", 2),
        ("pending-wide-1", b"A" + wide, 1),
        ("pending-wide-2", b"A" + wide, 2),
        ("settled-wide-1", wide, 1),
        ("settled-wide-2", wide, 2),
    )
    for cols in (4, 6):
        margins = (
            (1, 1),
            (cols, cols),
            (2, 2),
            (1, cols - 1),
            (2, cols),
            (2, cols - 1),
            (1, cols),
        )
        for rows, top, bottom, destination in verticals:
            for left, right in margins:
                geometry = b"".join([
                    b"\x1b[?69h",
                    f"\x1b[{left};{right}s".encode(),
                    f"\x1b[{top};{bottom}r".encode(),
                ])
                destination_position = (
                    f"\x1b[{destination};{left}H".encode()
                )
                prewrapped_position = (
                    f"\x1b[{destination - 1};{right}H".encode()
                )
                prestate_modes = (
                    ("unwrapped", destination_position + b"U"),
                    ("prewrapped", prewrapped_position + b"AB"),
                )
                edge_position = f"\x1b[{bottom};{right}H".encode()
                for prestate_name, prestate in prestate_modes:
                    for target_name, target_row in (
                            ("destination", destination),
                            ("exposed", bottom)):
                        later_modes = (
                            ("no-wrap",
                             f"\x1b[{target_row};{left}H".encode() + b"E"),
                            ("narrow-wrap",
                             f"\x1b[{target_row - 1};{right}H".encode()
                             + b"CD"),
                            ("wide-wrap",
                             f"\x1b[{target_row - 1};{right}H".encode()
                             + wide),
                        )
                        for later_name, later in later_modes:
                            for event_name, event_payload, event_count in event_modes:
                                if event_count == 0:
                                    events = edge_position + event_payload
                                else:
                                    events = ((edge_position + event_payload)
                                              * event_count)
                                payload = geometry + prestate + events + later
                                for resize_width in (cols - 1, cols, cols + 1):
                                    name = (
                                        f"audit-semantic-later-wrap-c{cols}-r{rows}-"
                                        f"m{left}-{right}-v{top}-{bottom}-"
                                        f"d{destination}-{prestate_name}-{target_name}-"
                                        f"{later_name}-{event_name}-w{resize_width}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),),
                                               (resize_width, rows))


def semantic_later_softwrap_representative_cases() -> Iterator[Case]:
    """Compact controls for the random-125 over-hardening branches."""
    rocket = "\U0001f680".encode()
    wide = "\u65e5".encode()
    flag = "\U0001f1fa\U0001f1f8".encode()
    narrow = "\u00e9".encode()
    minimized_random_0125 = b"".join([
        b"\x1b[?69h",
        b"\x1b[2;5r",
        b"\x1b[2;6H",
        rocket,
        b"\x1bD",
        wide,
        rocket,
        b"\x1b[2;9s",
        flag,
        narrow,
        b"\x1b[2;6H",
        rocket,
    ])
    yield Case("random-0125-overhardening-residual", 4, 9,
               minimized_random_0125, (len(minimized_random_0125),),
               (19, 4))

    selected = (
        ("semantic-later-wrap-unwrapped",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-prewrapped",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-prewrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-wide",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-wide-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-no-wrap-control",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-no-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-no-cross-control",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-no-cross-w5"),
        ("semantic-later-wrap-repeat",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-2-w5"),
        ("semantic-later-wrap-pending-wide",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-pending-wide-1-w5"),
        ("semantic-later-wrap-pending-wide-repeat",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-pending-wide-2-w5"),
        ("semantic-later-wrap-settled-wide",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-settled-wide-1-w5"),
        ("semantic-later-wrap-exposed",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-exposed-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-same-width-control",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w4"),
        ("semantic-later-wrap-aligned-shrink-control",
         "audit-semantic-later-wrap-c4-r3-m2-3-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w3"),
        ("semantic-later-wrap-unaligned-shrink",
         "audit-semantic-later-wrap-c4-r3-m2-4-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w3"),
        ("semantic-later-wrap-full-width-control",
         "audit-semantic-later-wrap-c4-r3-m1-4-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-left-one",
         "audit-semantic-later-wrap-c4-r3-m1-1-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-right-one",
         "audit-semantic-later-wrap-c4-r3-m4-4-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-internal-one",
         "audit-semantic-later-wrap-c4-r3-m2-2-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-left-wide",
         "audit-semantic-later-wrap-c4-r3-m1-3-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-right-wide",
         "audit-semantic-later-wrap-c4-r3-m2-4-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-internal-wide",
         "audit-semantic-later-wrap-c6-r3-m2-5-v1-3-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w7"),
        ("semantic-later-wrap-inset-top",
         "audit-semantic-later-wrap-c4-r4-m2-3-v2-4-d2-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-inset-last",
         "audit-semantic-later-wrap-c4-r4-m2-3-v2-4-d3-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-full-height-last",
         "audit-semantic-later-wrap-c4-r4-m2-3-v1-4-d3-unwrapped-destination-narrow-wrap-pending-narrow-1-w5"),
        ("semantic-later-wrap-aligned-wide-exposed-control",
         "audit-semantic-later-wrap-c4-r3-m1-3-v1-3-d2-unwrapped-exposed-wide-wrap-pending-narrow-1-w3"),
        ("semantic-later-wrap-aligned-wide-count-one-last",
         "audit-semantic-later-wrap-c4-r3-m1-3-v1-3-d2-unwrapped-destination-wide-wrap-pending-narrow-1-w3"),
        ("semantic-later-wrap-aligned-wide-count-one-top-prewrapped",
         "audit-semantic-later-wrap-c4-r4-m1-3-v2-4-d2-prewrapped-destination-wide-wrap-pending-narrow-1-w3"),
        ("semantic-later-wrap-aligned-wide-count-one-top-unwrapped",
         "audit-semantic-later-wrap-c4-r4-m1-3-v2-4-d2-unwrapped-destination-wide-wrap-pending-narrow-1-w3"),
        ("semantic-later-wrap-aligned-wide-count-two-last-control",
         "audit-semantic-later-wrap-c4-r3-m1-3-v1-3-d2-unwrapped-destination-wide-wrap-pending-narrow-2-w3"),
        ("semantic-later-wrap-aligned-wide-count-two-middle",
         "audit-semantic-later-wrap-c4-r4-m1-3-v1-4-d2-unwrapped-destination-wide-wrap-pending-narrow-2-w3"),
        ("semantic-later-wrap-aligned-wide-count-two-top-prewrapped",
         "audit-semantic-later-wrap-c4-r4-m1-3-v2-4-d2-prewrapped-destination-wide-wrap-pending-narrow-2-w3"),
        ("semantic-later-wrap-aligned-wide-count-two-top-unwrapped",
         "audit-semantic-later-wrap-c4-r4-m1-3-v2-4-d2-unwrapped-destination-wide-wrap-pending-narrow-2-w3"),
        ("semantic-later-wrap-aligned-settled-wide-nontop",
         "audit-semantic-later-wrap-c4-r3-m1-3-v1-3-d2-unwrapped-destination-wide-wrap-settled-wide-1-w3"),
        ("semantic-later-wrap-aligned-settled-wide-top-unwrapped",
         "audit-semantic-later-wrap-c4-r4-m1-3-v2-4-d2-unwrapped-destination-wide-wrap-settled-wide-1-w3"),
        ("semantic-later-wrap-aligned-settled-wide-top-prewrapped-control",
         "audit-semantic-later-wrap-c4-r4-m1-3-v2-4-d2-prewrapped-destination-wide-wrap-settled-wide-1-w3"),
        ("semantic-later-wrap-aligned-settled-wide-top-prewrapped-exposed",
         "audit-semantic-later-wrap-c4-r4-m1-3-v2-4-d2-prewrapped-exposed-wide-wrap-settled-wide-1-w3"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_later_softwrap_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic later-wrap controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def semantic_hidden_margin_rewrap_matrix_cases() -> Iterator[Case]:
    """Audit a saved row boundary across horizontal-geometry transitions.

    A narrow run starts immediately above the vertical region, reaches its
    bottom, and performs zero, one, or two partial-width scrolls while leaving
    the cursor at the active right edge.  Axes: widths 2, 4, and 6; full and
    inset regions of height 2...4; left, right, internal, one-column, wider,
    and full margins; active, hidden, restored, full-active, explicitly moved,
    and carriage-returned geometry transitions; ASCII, non-ASCII narrow, and
    wide followers; and shrink, same, or grow resizes. Cardinality: 9,720.
    """
    wide = "\U0001f680".encode()
    followers = (
        ("ascii", b"Y"),
        ("unicode", "\u00e9".encode()),
        ("wide", wide),
    )
    verticals = (
        (3, 2, 3),
        (4, 2, 4),
        (5, 2, 5),
        (5, 3, 5),
    )
    for cols in (2, 4, 6):
        margins = sorted({
            (cols, cols),
            (2, cols),
            (1, 1),
            (2, 2),
            (1, cols - 1),
            (1, cols),
        })
        for rows, top, bottom in verticals:
            region_height = bottom - top + 1
            for left, right in margins:
                margin_width = right - left + 1
                geometry = b"".join([
                    b"\x1b[?69h",
                    f"\x1b[{top};{bottom}r".encode(),
                    f"\x1b[{left};{right}s".encode(),
                    f"\x1b[{top - 1};{left}H".encode(),
                ])
                transitions = (
                    ("active", b""),
                    ("hidden", b"\x1b[?69l"),
                    ("hidden-restored", b"\x1b[?69l\x1b[?69h"),
                    ("full-active", f"\x1b[1;{cols}s".encode()),
                    ("hidden-positioned",
                     b"\x1b[?69l" + f"\x1b[{bottom};{cols}H".encode()),
                    ("hidden-carriage", b"\x1b[?69l\r"),
                )
                for scroll_count in (0, 1, 2):
                    run_length = ((region_height + 1 + scroll_count)
                                  * margin_width)
                    prefix = geometry + b"X" * run_length
                    for transition_name, transition in transitions:
                        for follower_name, follower in followers:
                            payload = prefix + transition + follower
                            for resize_width in (cols - 1, cols, cols + 1):
                                name = (
                                    f"audit-semantic-hidden-rewrap-c{cols}-r{rows}-"
                                    f"m{left}-{right}-v{top}-{bottom}-"
                                    f"n{scroll_count}-{transition_name}-"
                                    f"{follower_name}-w{resize_width}"
                                )
                                yield Case(name, cols, rows, payload,
                                           (len(payload),),
                                           (resize_width, rows))


def semantic_hidden_margin_rewrap_representative_cases() -> Iterator[Case]:
    """Compact controls for the second random-125 resize residual."""
    rocket = "\U0001f680".encode()
    minimized_random_0125 = b"".join([
        b"\x1b[?69h",
        b"\x1b[2;5r",
        b"\x1b[2;9s",
        b"Z",
        rocket,
        "A\u0301".encode(),
        b"0",
        b"\x1b[?69l",
        rocket,
    ])
    yield Case("random-0125-scalar-residual", 2, 3,
               minimized_random_0125, (len(minimized_random_0125),),
               (4, 3))

    identity_geometry = b"".join([
        b"\x1b[?69h",
        b"\x1b[2;3r",
        b"\x1b[2;2s",
        b"\x1b[1;2H",
    ])
    identity_stages = (
        ("semantic-hidden-rewrap-identity-pre-scroll",
         identity_geometry + b"ABC", None),
        ("semantic-hidden-rewrap-identity-post-partial",
         identity_geometry + b"ABCD", None),
        ("semantic-hidden-rewrap-identity-post-incoming",
         identity_geometry + b"ABCD\x1b[?69lE", None),
        ("semantic-hidden-rewrap-identity-resized",
         identity_geometry + b"ABCD\x1b[?69lE", (3, 3)),
    )
    for name, payload, resize in identity_stages:
        yield Case(name, 2, 3, payload, (len(payload),), resize)

    selected = (
        ("semantic-hidden-rewrap-minimum",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-wide-w3"),
        ("semantic-hidden-rewrap-no-scroll-control",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n0-hidden-wide-w3"),
        ("semantic-hidden-rewrap-repeat",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n2-hidden-wide-w3"),
        ("semantic-hidden-rewrap-active-control",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-active-wide-w3"),
        ("semantic-hidden-rewrap-restored-control",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-restored-wide-w3"),
        ("semantic-hidden-rewrap-full-active",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-full-active-wide-w3"),
        ("semantic-hidden-rewrap-positioned-control",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-positioned-wide-w3"),
        ("semantic-hidden-rewrap-carriage-control",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-carriage-wide-w3"),
        ("semantic-hidden-rewrap-ascii",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-ascii-w3"),
        ("semantic-hidden-rewrap-unicode",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-unicode-w3"),
        ("semantic-hidden-rewrap-shrink",
         "audit-semantic-hidden-rewrap-c4-r3-m4-4-v2-3-n1-hidden-wide-w3"),
        ("semantic-hidden-rewrap-same-width-control",
         "audit-semantic-hidden-rewrap-c4-r3-m4-4-v2-3-n1-hidden-wide-w4"),
        ("semantic-hidden-rewrap-grow",
         "audit-semantic-hidden-rewrap-c4-r3-m4-4-v2-3-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-right-wide",
         "audit-semantic-hidden-rewrap-c4-r3-m2-4-v2-3-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-left-one-control",
         "audit-semantic-hidden-rewrap-c4-r3-m1-1-v2-3-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-internal-one-control",
         "audit-semantic-hidden-rewrap-c4-r3-m2-2-v2-3-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-left-wide-control",
         "audit-semantic-hidden-rewrap-c4-r3-m1-3-v2-3-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-full-width-control",
         "audit-semantic-hidden-rewrap-c4-r3-m1-4-v2-3-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-height-three",
         "audit-semantic-hidden-rewrap-c4-r4-m4-4-v2-4-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-height-four",
         "audit-semantic-hidden-rewrap-c4-r5-m4-4-v2-5-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-inset",
         "audit-semantic-hidden-rewrap-c4-r5-m4-4-v3-5-n1-hidden-wide-w5"),
        ("semantic-hidden-rewrap-branch-01",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n1-hidden-positioned-wide-w1"),
        ("semantic-hidden-rewrap-branch-02",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-positioned-wide-w1"),
        ("semantic-hidden-rewrap-branch-03",
         "audit-semantic-hidden-rewrap-c2-r3-m1-2-v2-3-n1-hidden-positioned-wide-w1"),
        ("semantic-hidden-rewrap-branch-04",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n1-hidden-positioned-wide-w2"),
        ("semantic-hidden-rewrap-branch-05",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-hidden-positioned-wide-w1"),
        ("semantic-hidden-rewrap-branch-06",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-hidden-positioned-ascii-w1"),
        ("semantic-hidden-rewrap-branch-07",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n1-hidden-unicode-w2"),
        ("semantic-hidden-rewrap-branch-08",
         "audit-semantic-hidden-rewrap-c4-r3-m1-3-v2-3-n1-hidden-wide-w4"),
        ("semantic-hidden-rewrap-branch-09",
         "audit-semantic-hidden-rewrap-c4-r3-m1-1-v2-3-n1-hidden-wide-w4"),
        ("semantic-hidden-rewrap-branch-10",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n1-hidden-wide-w2"),
        ("semantic-hidden-rewrap-branch-11",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-unicode-w1"),
        ("semantic-hidden-rewrap-branch-12",
         "audit-semantic-hidden-rewrap-c4-r3-m1-3-v2-3-n0-hidden-wide-w4"),
        ("semantic-hidden-rewrap-branch-13",
         "audit-semantic-hidden-rewrap-c4-r3-m1-1-v2-3-n0-hidden-wide-w3"),
        ("semantic-hidden-rewrap-branch-14",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-hidden-wide-w2"),
        ("semantic-hidden-rewrap-branch-15",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-hidden-unicode-w2"),
        ("semantic-hidden-rewrap-branch-16",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-hidden-wide-w1"),
        ("semantic-hidden-rewrap-branch-17",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-hidden-unicode-w1"),
        ("semantic-hidden-rewrap-branch-18",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-hidden-ascii-w1"),
        ("semantic-hidden-rewrap-branch-19",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-hidden-ascii-w1"),
        ("semantic-hidden-rewrap-branch-20",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n0-hidden-ascii-w1"),
        ("semantic-hidden-rewrap-branch-21",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n0-hidden-ascii-w2"),
        ("semantic-hidden-rewrap-branch-22",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-full-active-ascii-w1"),
        ("semantic-hidden-rewrap-branch-23",
         "audit-semantic-hidden-rewrap-c4-r3-m1-3-v2-3-n0-full-active-wide-w5"),
        ("semantic-hidden-rewrap-branch-24",
         "audit-semantic-hidden-rewrap-c4-r3-m1-3-v2-3-n1-full-active-wide-w5"),
        ("semantic-hidden-rewrap-branch-25",
         "audit-semantic-hidden-rewrap-c4-r3-m1-3-v2-3-n0-full-active-wide-w4"),
        ("semantic-hidden-rewrap-branch-26",
         "audit-semantic-hidden-rewrap-c4-r3-m1-1-v2-3-n0-full-active-wide-w3"),
        ("semantic-hidden-rewrap-branch-27",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-full-active-wide-w3"),
        ("semantic-hidden-rewrap-branch-28",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n1-full-active-wide-w3"),
        ("semantic-hidden-rewrap-branch-29",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-full-active-wide-w2"),
        ("semantic-hidden-rewrap-branch-30",
         "audit-semantic-hidden-rewrap-c2-r3-m1-1-v2-3-n0-full-active-wide-w1"),
        ("semantic-hidden-rewrap-branch-31",
         "audit-semantic-hidden-rewrap-c2-r3-m1-2-v2-3-n0-full-active-ascii-w1"),
        ("semantic-hidden-rewrap-branch-32",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n0-full-active-ascii-w1"),
        ("semantic-hidden-rewrap-branch-33",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n1-full-active-ascii-w1"),
        ("semantic-hidden-rewrap-branch-34",
         "audit-semantic-hidden-rewrap-c2-r3-m2-2-v2-3-n0-full-active-ascii-w2"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in semantic_hidden_margin_rewrap_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing semantic hidden-rewrap controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def kitty_control_pending_matrix_cases() -> Iterator[Case]:
    """Audit Kitty controls across pending, settled, and parked cursors.

    Axes: widths 1...5; wrap-pending, explicitly settled, and no-wrap parked
    edge sources; autowrap retained or toggled before/after the control; valid
    and invalid transmit, delete, query, and display controls; and ASCII,
    non-ASCII, wide, and combining followers.  Cardinality: 1,920.
    """
    esc = b"\x1b"
    st = esc + b"\\"

    def kitty(header: bytes, payload: bytes = b"") -> bytes:
        return esc + b"_G" + header + b";" + payload + st

    rgba = b"/wAA/w=="
    preload = kitty(b"a=t,f=32,s=1,v=1,i=21,q=2", rgba)
    controls = (
        ("transmit-valid", b"", kitty(b"a=T,f=32,s=1,v=1,i=22,q=2", rgba)),
        ("transmit-invalid", b"", kitty(b"a=T,f=32,s=1,v=1,i=22,q=2", b"%%%")),
        ("delete-valid", preload, kitty(b"a=d,d=i,i=21,q=2")),
        ("delete-missing", b"", kitty(b"a=d,d=i,i=999,q=2")),
        ("query-valid", b"", kitty(b"a=q,f=32,s=1,v=1,i=23,q=2", rgba)),
        ("query-invalid", b"", kitty(b"a=q,f=32,s=1,v=1,i=23,q=2", b"%%%")),
        ("display-valid", preload,
         kitty(b"a=p,i=21,p=1,x=0,y=0,c=1,r=1,q=2")),
        ("display-missing", b"",
         kitty(b"a=p,i=999,p=1,x=0,y=0,c=1,r=1,q=2")),
    )
    followers = (
        ("ascii-space", b" "),
        ("unicode", "\u00e9".encode()),
        ("wide", "\u65e5".encode()),
        ("combining", "\u0301".encode()),
    )
    for cols in range(1, 6):
        edge = f"\x1b[1;{cols}H".encode()
        pending = b"\x1b[?7h" + edge + b"A"
        settled = pending + edge
        nowrap = b"\x1b[?7l" + edge + b"A"
        state_paths = (
            ("pending-keep-on", pending, b"", b""),
            ("pending-off-before", pending, b"\x1b[?7l", b""),
            ("pending-off-after", pending, b"", b"\x1b[?7l"),
            ("pending-off-before-on-after", pending, b"\x1b[?7l", b"\x1b[?7h"),
            ("settled-keep-on", settled, b"", b""),
            ("settled-off-before", settled, b"\x1b[?7l", b""),
            ("settled-off-after", settled, b"", b"\x1b[?7l"),
            ("settled-off-before-on-after", settled, b"\x1b[?7l", b"\x1b[?7h"),
            ("nowrap-keep-off", nowrap, b"", b""),
            ("nowrap-on-before", nowrap, b"\x1b[?7h", b""),
            ("nowrap-on-after", nowrap, b"", b"\x1b[?7h"),
            ("nowrap-on-before-off-after", nowrap, b"\x1b[?7h", b"\x1b[?7l"),
        )
        for state_name, source, before, after in state_paths:
            for control_name, control_setup, control in controls:
                for follower_name, follower in followers:
                    payload = (control_setup + source + before + control
                               + after + follower)
                    name = (f"audit-kitty-control-c{cols}-{state_name}-"
                            f"{control_name}-{follower_name}")
                    yield Case(name, cols, 2, payload,
                               (len(payload),), None)


def kitty_row_advance_matrix_cases() -> Iterator[Case]:
    """Audit successful Kitty placement as a terminal row motion.

    Axes: widths and heights 1...4; normal and alternate buffers; blank,
    narrow-marker, and (where it fits) width-two-marker content; default and
    every valid vertical region; every physical cursor row; settled,
    wrap-pending, and no-wrap parked cursors; and successful transmit/display
    controls versus preload, invalid transmit, missing display, valid/missing
    delete, valid/invalid query, and malformed-action controls.  Cardinality:
    29,700.
    """
    esc = b"\x1b"
    st = esc + b"\\"

    def kitty(header: bytes, payload: bytes = b"") -> bytes:
        return esc + b"_G" + header + b";" + payload + st

    rgba = b"/wAA/w=="
    preload = kitty(b"a=t,f=32,s=1,v=1,i=31,q=2", rgba)
    controls = (
        ("transmit-valid", b"",
         kitty(b"a=T,f=32,s=1,v=1,i=32,q=2", rgba)),
        ("display-valid", preload,
         kitty(b"a=p,i=31,p=1,x=0,y=0,c=1,r=1,q=2")),
        ("preload-valid", b"", preload),
        ("transmit-invalid", b"",
         kitty(b"a=T,f=32,s=1,v=1,i=32,q=2", b"%%%")),
        ("display-missing", b"",
         kitty(b"a=p,i=999,p=1,x=0,y=0,c=1,r=1,q=2")),
        ("delete-valid", preload, kitty(b"a=d,d=i,i=31,q=2")),
        ("delete-missing", b"", kitty(b"a=d,d=i,i=999,q=2")),
        ("query-valid", b"",
         kitty(b"a=q,f=32,s=1,v=1,i=33,q=2", rgba)),
        ("query-invalid", b"",
         kitty(b"a=q,f=32,s=1,v=1,i=33,q=2", b"%%%")),
        ("malformed-action", b"", kitty(b"a=z,i=-1,q=2", b"AA==")),
    )
    wide_markers = ("\u65e5", "\u754c", "\u8a9e", "\u672c")
    for cols in range(1, 5):
        for rows in range(1, 5):
            marker_setups: list[tuple[str, bytes]] = [("blank", b"")]
            narrow_parts = [b"\x1b[?7l"]
            wide_parts = [b"\x1b[?7l"]
            for marker_row in range(1, rows + 1):
                cup = f"\x1b[{marker_row};1H".encode()
                narrow_parts.extend([cup, bytes([64 + marker_row])])
                wide_parts.extend([cup, wide_markers[marker_row - 1].encode()])
            marker_setups.append(("narrow", b"".join(narrow_parts)))
            if cols >= 2:
                marker_setups.append(("wide", b"".join(wide_parts)))
            vertical_regions: list[tuple[int, int] | None] = [None]
            vertical_regions.extend(
                (top, bottom)
                for top in range(1, rows + 1)
                for bottom in range(top + 1, rows + 1)
            )
            for buffer_name, buffer_setup in (
                ("normal", b""), ("alternate", b"\x1b[?1049h"),
            ):
                for marker_name, marker_setup in marker_setups:
                    for vertical_region in vertical_regions:
                        if vertical_region is None:
                            vertical_name = "default"
                            vertical_setup = b""
                        else:
                            top, bottom = vertical_region
                            vertical_name = f"v{top}-{bottom}"
                            vertical_setup = f"\x1b[{top};{bottom}r".encode()
                        for row in range(1, rows + 1):
                            edge = f"\x1b[{row};{cols}H".encode()
                            cursor_states = (
                                ("settled", b"\x1b[?7h" +
                                 f"\x1b[{row};1H".encode()),
                                ("pending", b"\x1b[?7h" + edge + b"A"),
                                ("parked", b"\x1b[?7l" + edge + b"A"),
                            )
                            for state_name, state_setup in cursor_states:
                                for control_name, control_setup, control in controls:
                                    payload = b"".join([
                                        control_setup, buffer_setup, marker_setup,
                                        vertical_setup, state_setup, control,
                                    ])
                                    name = (f"audit-kitty-row-c{cols}-r{rows}-"
                                            f"{buffer_name}-{marker_name}-"
                                            f"{vertical_name}-y{row}-{state_name}-"
                                            f"{control_name}")
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def kitty_row_horizontal_margin_matrix_cases() -> Iterator[Case]:
    """Audit Kitty row motion against stored horizontal geometry.

    Axes: widths 2...4; heights 1...4; normal and alternate buffers;
    physical geometry plus every active or hidden horizontal-margin pair;
    default and every valid vertical region; every physical cursor row;
    settled cursors at every column plus autowrap and no-wrap prints at the
    stored and physical right edges; and successful transmit or preloaded
    display.  Full-row markers expose the exact horizontal mutation slice.
    Cardinality: 46,620.
    """
    esc = b"\x1b"
    st = esc + b"\\"

    def kitty(header: bytes, payload: bytes = b"") -> bytes:
        return esc + b"_G" + header + b";" + payload + st

    rgba = b"/wAA/w=="
    preload = kitty(b"a=t,f=32,s=1,v=1,i=41,q=2", rgba)
    controls = (
        ("transmit", b"", kitty(b"a=T,f=32,s=1,v=1,i=42,q=2", rgba)),
        ("display", preload,
         kitty(b"a=p,i=41,p=1,x=0,y=0,c=1,r=1,q=2")),
    )
    for cols in range(2, 5):
        geometries: list[tuple[str, int, int, bytes]] = [
            ("physical", 1, cols, b""),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                enable = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                geometries.extend([
                    (f"active-{left}-{right}", left, right, enable),
                    (f"hidden-{left}-{right}", left, right,
                     enable + b"\x1b[?69l"),
                ])
        for rows in range(1, 5):
            marker_parts = [b"\x1b[?7l"]
            for marker_row in range(1, rows + 1):
                marker_parts.extend([
                    f"\x1b[{marker_row};1H".encode(),
                    bytes([64 + marker_row]) * cols,
                ])
            marker_setup = b"".join(marker_parts)
            vertical_regions: list[tuple[int, int] | None] = [None]
            vertical_regions.extend(
                (top, bottom)
                for top in range(1, rows + 1)
                for bottom in range(top + 1, rows + 1)
            )
            for buffer_name, buffer_setup in (
                ("normal", b""), ("alternate", b"\x1b[?1049h"),
            ):
                for vertical_region in vertical_regions:
                    if vertical_region is None:
                        vertical_name = "default"
                        vertical_setup = b""
                    else:
                        top, bottom = vertical_region
                        vertical_name = f"v{top}-{bottom}"
                        vertical_setup = f"\x1b[{top};{bottom}r".encode()
                    for geometry_name, left, right, geometry_setup in geometries:
                        for row in range(1, rows + 1):
                            cursor_states: list[tuple[str, bytes]] = [
                                (
                                    f"settled-x{col}",
                                    b"\x1b[?7h" + f"\x1b[{row};{col}H".encode(),
                                )
                                for col in range(1, cols + 1)
                            ]
                            stored_edge = f"\x1b[{row};{right}H".encode()
                            cursor_states.extend([
                                ("wrap-stored-edge",
                                 b"\x1b[?7h" + stored_edge + b"X"),
                                ("parked-stored-edge",
                                 b"\x1b[?7l" + stored_edge + b"X"),
                            ])
                            if right < cols:
                                physical_edge = f"\x1b[{row};{cols}H".encode()
                                cursor_states.extend([
                                    ("wrap-physical-edge",
                                     b"\x1b[?7h" + physical_edge + b"X"),
                                    ("parked-physical-edge",
                                     b"\x1b[?7l" + physical_edge + b"X"),
                                ])
                            for state_name, state_setup in cursor_states:
                                for control_name, control_setup, control in controls:
                                    payload = b"".join([
                                        control_setup, buffer_setup, marker_setup,
                                        vertical_setup, geometry_setup, state_setup,
                                        control,
                                    ])
                                    name = (f"audit-kitty-hmargin-c{cols}-r{rows}-"
                                            f"{buffer_name}-{vertical_name}-"
                                            f"{geometry_name}-y{row}-{state_name}-"
                                            f"{control_name}")
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def kitty_row_background_matrix_cases() -> Iterator[Case]:
    """Audit erase-background fill on successful Kitty row generation.

    Axes: widths and heights 1...4; normal and alternate buffers; physical
    geometry plus every active or hidden stored horizontal-margin pair;
    default and every valid vertical region; every physical cursor row;
    settled, wrap-pending, and no-wrap parked cursors; default, ANSI, and
    indexed backgrounds; successful transmit/display versus an inert query;
    and steady versus one-row-taller final geometry.  Blank initial cells
    isolate generated-row fill attributes.  Cardinality: 213,840.

    Frozen candidate 9cf60570 classification: 7,112 cell-only deltas and
    206,728 exact cases.  All setup prefixes are exact.  Every differing cell
    has the active ANSI/indexed background in the reference and default
    background in the candidate; scalar, width, foreground, and style match.
    There are 15,624 such cell-field deltas.

    Direct predictor over the generator axes: background is non-default;
    control is a successful transmit or display; state is settled; cursor row
    equals the active vertical bottom; and the geometry branch is active mode,
    or physical geometry in the normal buffer (also physical width one in the
    alternate buffer), or hidden mode whose stored right edge equals the
    physical right edge.  Exclude the one-row expansion case in a normal
    width-one buffer.  No vertical-top or height exception exists.  Steady and
    expanded variants both differ in 3,472 paired states; 168 steady variants
    are normalized by expansion; no expand-only delta exists.
    """
    esc = b"\x1b"
    st = esc + b"\\"

    def kitty(header: bytes, payload: bytes = b"") -> bytes:
        return esc + b"_G" + header + b";" + payload + st

    rgba = b"/wAA/w=="
    preload = kitty(b"a=t,f=32,s=1,v=1,i=51,q=2", rgba)
    controls = (
        ("transmit", b"", kitty(b"a=T,f=32,s=1,v=1,i=52,q=2", rgba)),
        ("display", preload,
         kitty(b"a=p,i=51,p=1,x=0,y=0,c=1,r=1,q=2")),
        ("query", b"", kitty(b"a=q,f=32,s=1,v=1,i=53,q=2", rgba)),
    )
    backgrounds = (
        ("default", b""),
        ("ansi-black", b"\x1b[40m"),
        ("indexed-99", b"\x1b[48;5;99m"),
    )
    for cols in range(1, 5):
        geometries: list[tuple[str, bytes, int, int]] = [
            ("physical", b"", 1, cols),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                geometries.extend([
                    (f"active-{left}-{right}", stored, left, right),
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l",
                     1, cols),
                ])
        for rows in range(1, 5):
            vertical_regions: list[tuple[int, int] | None] = [None]
            vertical_regions.extend(
                (top, bottom)
                for top in range(1, rows + 1)
                for bottom in range(top + 1, rows + 1)
            )
            for buffer_name, buffer_setup in (
                ("normal", b""), ("alternate", b"\x1b[?1049h"),
            ):
                for vertical_region in vertical_regions:
                    if vertical_region is None:
                        vertical_name = "default"
                        vertical_setup = b""
                    else:
                        top, bottom = vertical_region
                        vertical_name = f"v{top}-{bottom}"
                        vertical_setup = f"\x1b[{top};{bottom}r".encode()
                    for geometry_name, geometry_setup, left, right in geometries:
                        for row in range(1, rows + 1):
                            edge = f"\x1b[{row};{right}H".encode()
                            cursor_states = (
                                ("settled", b"\x1b[?7h" + edge),
                                ("pending", b"\x1b[?7h" + edge + b"A"),
                                ("parked", b"\x1b[?7l" + edge + b"A"),
                            )
                            for state_name, state_setup in cursor_states:
                                for background_name, background_setup in backgrounds:
                                    for control_name, control_setup, control in controls:
                                        for resize_name, resize in (
                                            ("steady", None),
                                            ("expand", (cols, rows + 1)),
                                        ):
                                            payload = b"".join([
                                                buffer_setup, vertical_setup,
                                                geometry_setup, control_setup,
                                                background_setup, state_setup,
                                                control,
                                            ])
                                            name = (
                                                f"audit-kitty-row-background-"
                                                f"c{cols}-r{rows}-{buffer_name}-"
                                                f"{vertical_name}-{geometry_name}-"
                                                f"y{row}-{state_name}-"
                                                f"{background_name}-{control_name}-"
                                                f"{resize_name}"
                                            )
                                            yield Case(name, cols, rows, payload,
                                                       (len(payload),), resize)


def kitty_row_background_representative_cases() -> Iterator[Case]:
    """Compact frozen controls spanning every matrix predictor branch."""
    selected = (
        "audit-kitty-row-background-c1-r1-normal-default-physical-y1-"
        "settled-indexed-99-display-steady",
        "audit-kitty-row-background-c1-r1-normal-default-physical-y1-"
        "settled-default-transmit-steady",
        "audit-kitty-row-background-c1-r1-normal-default-physical-y1-"
        "settled-ansi-black-query-steady",
        "audit-kitty-row-background-c2-r2-normal-default-physical-y1-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c2-r2-normal-default-physical-y2-"
        "pending-ansi-black-transmit-steady",
        "audit-kitty-row-background-c2-r2-normal-default-physical-y2-"
        "parked-ansi-black-transmit-steady",
        "audit-kitty-row-background-c3-r2-normal-default-active-2-2-y2-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c3-r2-normal-default-hidden-2-3-y2-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c3-r2-normal-default-hidden-1-2-y2-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c2-r2-alternate-default-physical-y2-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c1-r1-alternate-default-physical-y1-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c2-r2-alternate-default-active-1-2-y2-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c2-r2-alternate-default-hidden-1-2-y2-"
        "settled-ansi-black-transmit-steady",
        "audit-kitty-row-background-c1-r1-normal-default-physical-y1-"
        "settled-ansi-black-transmit-expand",
        "audit-kitty-row-background-c2-r1-normal-default-physical-y1-"
        "settled-ansi-black-transmit-expand",
        "audit-kitty-row-background-c3-r3-normal-v1-2-active-2-3-y2-"
        "settled-indexed-99-display-steady",
    )
    wanted = set(selected)
    found: dict[str, Case] = {}
    for case in kitty_row_background_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(selected):
                break
    if len(found) != len(selected):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing Kitty row-background controls: {missing}")
    for index, name in enumerate(selected, 436):
        case = found[name]
        yield Case(f"kitty-row-background-branch-{index}", case.cols, case.rows,
                   case.payload, case.chunks, case.resize)


def kitty_retransmit_line_generation_matrix_cases() -> Iterator[Case]:
    """Audit line-generation lifetime when a Kitty image ID is retransmitted.

    Axes: widths two through six; heights four through seven; every source and
    replacement row except the physical bottom; left, middle, and right
    columns; same versus distinct image IDs; wrap enabled or disabled; one
    column shrink, same width, or one column growth; and every final height
    from one through one row beyond the source.  Cardinality: 289,920.
    """
    esc = b"\x1b"
    st = esc + b"\\"

    def kitty(header: bytes, payload: bytes = b"") -> bytes:
        return esc + b"_G" + header + b";" + payload + st

    rgba = b"/wAA/w=="
    transmit_three = kitty(b"a=T,f=32,s=1,v=1,i=3,q=2", rgba)
    transmit_four = kitty(b"a=T,f=32,s=1,v=1,i=4,q=2", rgba)
    for cols in range(2, 7):
        column_values = sorted({1, (cols + 1) // 2, cols})
        for rows in range(4, 8):
            for first_row in range(rows - 1):
                for second_row in range(rows - 1):
                    for first_col in column_values:
                        for second_col in column_values:
                            for identity_name, second_transmit in (
                                    ("same", transmit_three),
                                    ("distinct", transmit_four)):
                                for wrap_name, wrap in (
                                        ("wrap", b"\x1b[?7h"),
                                        ("nowrap", b"\x1b[?7l")):
                                    for new_cols in sorted({
                                            cols - 1, cols, cols + 1}):
                                        for new_rows in range(1, rows + 2):
                                            parts = (
                                                wrap,
                                                f"\x1b[{first_row + 1};{first_col}H".encode(),
                                                transmit_three,
                                                f"\x1b[{second_row + 1};{second_col}H".encode(),
                                                second_transmit,
                                            )
                                            payload = b"".join(parts)
                                            name = (
                                                f"audit-kitty-retransmit-c{cols}-r{rows}-"
                                                f"y{first_row + 1}x{first_col}-"
                                                f"y{second_row + 1}x{second_col}-"
                                                f"{identity_name}-{wrap_name}-"
                                                f"to-c{new_cols}-r{new_rows}"
                                            )
                                            yield Case(
                                                name, cols, rows, payload,
                                                (len(payload),),
                                                (new_cols, new_rows))


def kitty_retransmit_line_generation_representative_cases() -> Iterator[Case]:
    """Freeze the reduced residual and replacement/reset decision branches."""
    esc = b"\x1b"
    st = esc + b"\\"

    def kitty(header: bytes, payload: bytes = b"") -> bytes:
        return esc + b"_G" + header + b";" + payload + st

    rgba = b"/wAA/w=="
    transmit_three = kitty(b"a=T,f=32,s=1,v=1,i=3,q=2", rgba)
    transmit_four = kitty(b"a=T,f=32,s=1,v=1,i=4,q=2", rgba)
    invalid_three = kitty(b"a=T,f=32,s=1,v=1,i=3,q=2", b"%%%")
    preload_three = kitty(b"a=t,f=32,s=1,v=1,i=3,q=2", rgba)
    place_one = kitty(b"a=p,i=3,p=1,x=0,y=0,c=1,r=1,q=2")
    place_two = kitty(b"a=p,i=3,p=2,x=0,y=0,c=1,r=1,q=2")
    delete_three = kitty(b"a=d,d=i,i=3,q=2")
    query_three = kitty(b"a=q,f=32,s=1,v=1,i=3,q=2", rgba)

    reduced = b"\x1b[2B" + transmit_three + b"\x1b[H" + transmit_three
    yield Case("random-0392-kitty-retransmit-line-count-residual",
               1, 4, reduced, (len(reduced),), (1, 1))

    def two_positions(first: bytes, second: bytes, between: bytes = b"",
                      *, first_row: int = 5, second_row: int = 1,
                      first_col: int = 4, second_col: int = 4,
                      wrap: bytes = b"\x1b[?7h") -> bytes:
        return b"".join((
            wrap, f"\x1b[{first_row};{first_col}H".encode(), first,
            between, f"\x1b[{second_row};{second_col}H".encode(), second,
        ))

    controls = (
        ("kitty-retransmit-visible-edge", 4, 6,
         two_positions(transmit_three, transmit_three), (4, 1)),
        ("kitty-retransmit-visible-interior-nowrap", 4, 6,
         two_positions(transmit_three, transmit_three,
                       first_col=2, second_col=3, wrap=b"\x1b[?7l"), (5, 2)),
        ("kitty-retransmit-distinct-id-control", 4, 6,
         two_positions(transmit_three, transmit_four), (4, 1)),
        ("kitty-retransmit-order-control", 4, 6,
         two_positions(transmit_three, transmit_three,
                       first_row=1, second_row=5), (4, 1)),
        ("kitty-retransmit-adjacent-control", 4, 6,
         two_positions(transmit_three, transmit_three,
                       first_row=5, second_row=4), (4, 1)),
        ("kitty-retransmit-height-mask-control", 4, 6,
         two_positions(transmit_three, transmit_three), (4, 6)),
        ("kitty-retransmit-same-row-control", 4, 6,
         two_positions(transmit_three, transmit_three,
                       first_row=3, second_row=3), (4, 1)),
        ("kitty-retransmit-query-does-not-reset", 4, 6,
         two_positions(transmit_three, transmit_three, query_three), (4, 1)),
        ("kitty-retransmit-delete-reset-control", 4, 6,
         two_positions(transmit_three, transmit_three, delete_three), (4, 1)),
        ("kitty-retransmit-invalid-control", 4, 6,
         two_positions(transmit_three, invalid_three), (4, 1)),
        ("kitty-placement-same-id-control", 4, 6,
         preload_three + two_positions(place_one, place_one), (4, 1)),
        ("kitty-placement-distinct-id-control", 4, 6,
         preload_three + two_positions(place_one, place_two), (4, 1)),
        ("kitty-transmit-then-place-control", 4, 6,
         two_positions(transmit_three, place_one), (4, 1)),
    )
    for name, cols, rows, payload, resize in controls:
        yield Case(name, cols, rows, payload, (len(payload),), resize)


def decbi_generated_blank_grapheme_matrix_cases() -> Iterator[Case]:
    """Audit grapheme attachment after DECBI-generated blank insertion.

    Axes: widths two through six; one- and two-row screens; default, active,
    and hidden horizontal geometries; every physical source column; empty,
    narrow, non-ASCII, and wide bases; direct, carriage-return, and backward
    positioning; one through three DECBI operations; combining, ZWJ, VS15,
    and narrow followers; and wrap enabled or disabled. Cardinality: 89,856.
    """
    bases = (
        ("none", b""), ("ascii", b"a"),
        ("unicode", "é".encode()), ("wide", "日".encode()),
    )
    followers = (
        ("zwj", "\u200d".encode()), ("accent", "\u0301".encode()),
        ("vs15", "\ufe0e".encode()), ("narrow", b"Z"),
    )
    movements = (
        ("none", b""), ("cr", b"\r"), ("back-one", b"\x1b[D"),
    )
    for cols in range(2, 7):
        geometries = [
            ("default", b""),
            ("active-full", b"\x1b[?69h" + f"\x1b[1;{cols}s".encode()),
            ("active-left", b"\x1b[?69h" + f"\x1b[1;{cols - 1}s".encode()),
            ("active-right", b"\x1b[?69h" + f"\x1b[2;{cols}s".encode()),
            ("active-left-one", b"\x1b[?69h\x1b[1;1s"),
            ("active-right-one", b"\x1b[?69h" +
             f"\x1b[{cols};{cols}s".encode()),
        ]
        if cols >= 3:
            internal = b"\x1b[?69h" + f"\x1b[2;{cols - 1}s".encode()
            geometries.extend((
                ("active-internal", internal),
                ("hidden-internal", internal + b"\x1b[?69l"),
            ))
        for rows in (1, 2):
            for geometry_name, geometry in geometries:
                for start in range(1, cols + 1):
                    for base_name, base in bases:
                        for movement_name, movement in movements:
                            for count in (1, 2, 3):
                                shift = b"\x1b6" * count
                                for follower_name, follower in followers:
                                    for wrap_name, wrap in (
                                            ("wrap", b"\x1b[?7h"),
                                            ("nowrap", b"\x1b[?7l")):
                                        payload = b"".join((
                                            wrap, geometry,
                                            f"\x1b[1;{start}H".encode(),
                                            base, movement, shift, follower,
                                        ))
                                        name = (
                                            f"audit-decbi-grapheme-c{cols}-r{rows}-"
                                            f"{geometry_name}-x{start}-{base_name}-"
                                            f"{movement_name}-n{count}-"
                                            f"{follower_name}-{wrap_name}"
                                        )
                                        yield Case(name, cols, rows, payload,
                                                   (len(payload),), None)


def decbi_generated_blank_grapheme_representative_cases() -> Iterator[Case]:
    """Freeze the reduced residual and compact ownership controls."""
    zwj = "\u200d".encode()
    accent = "\u0301".encode()
    vs15 = "\ufe0e".encode()

    def make(cols: int, geometry: bytes, start: int, base: bytes,
             movement: bytes, count: int, follower: bytes,
             wrap: bytes = b"\x1b[?7h") -> bytes:
        return b"".join((
            wrap, geometry, f"\x1b[1;{start}H".encode(), base,
            movement, b"\x1b6" * count, follower,
        ))

    reduced = b"a\r\x1b6" + zwj
    yield Case("random-0421-decbi-generated-blank-zwj-residual",
               1, 1, reduced, (len(reduced),), None)
    controls = (
        ("decbi-blank-default-cr", 3, b"", 1, b"a", b"\r", 1, zwj, b"\x1b[?7h"),
        ("decbi-blank-default-repeated", 3, b"", 2, b"a", b"\r", 2, accent, b"\x1b[?7h"),
        ("decbi-blank-default-direct", 2, b"", 1, b"a", b"", 2, zwj, b"\x1b[?7h"),
        ("decbi-blank-default-back-one", 2, b"", 1, b"a", b"\x1b[D", 1, zwj, b"\x1b[?7h"),
        ("decbi-blank-wide-wrap", 3, b"", 3, "日".encode(), b"\r", 1, zwj, b"\x1b[?7h"),
        ("decbi-blank-active-full", 2, b"\x1b[?69h\x1b[1;2s", 1, b"a", b"", 2, zwj, b"\x1b[?7h"),
        ("decbi-blank-active-left", 2, b"\x1b[?69h\x1b[1;1s", 1, b"a", b"", 2, zwj, b"\x1b[?7h"),
        ("decbi-blank-active-right", 2, b"\x1b[?69h\x1b[2;2s", 2, b"a", b"", 2, zwj, b"\x1b[?7h"),
        ("decbi-blank-active-internal", 3, b"\x1b[?69h\x1b[2;2s", 2, b"a", b"", 2, zwj, b"\x1b[?7h"),
        ("decbi-blank-active-right-one", 3, b"\x1b[?69h\x1b[3;3s", 3, b"a", b"", 2, zwj, b"\x1b[?7h"),
        ("decbi-blank-hidden-internal", 3, b"\x1b[?69h\x1b[2;2s\x1b[?69l", 2, b"a", b"", 2, zwj, b"\x1b[?7h"),
        ("decbi-blank-no-base-control", 3, b"", 1, b"", b"\r", 1, zwj, b"\x1b[?7h"),
        ("decbi-blank-vs15-control", 3, b"", 1, b"a", b"\r", 1, vs15, b"\x1b[?7h"),
        ("decbi-blank-narrow-control", 3, b"", 1, b"a", b"\r", 1, b"Z", b"\x1b[?7h"),
        ("decbi-blank-insufficient-shift-control", 4, b"", 3, b"a", b"\r", 1, zwj, b"\x1b[?7h"),
        ("decbi-blank-wide-nowrap-edge-control", 3, b"", 3, "日".encode(), b"\r", 1, zwj, b"\x1b[?7l"),
        ("decbi-blank-no-shift-control", 3, b"", 1, b"a", b"\r", 0, zwj, b"\x1b[?7h"),
    )
    for name, cols, geometry, start, base, movement, count, follower, wrap in controls:
        payload = make(cols, geometry, start, base, movement, count,
                       follower, wrap)
        yield Case(name, cols, 1, payload, (len(payload),), None)


def ht_lastwrite_matrix_cases() -> Iterator[Case]:
    """Audit HT's effect on the preceding printable grapheme.

    Axes: widths 1...4; heights 1...3 and every source row; ASCII and
    non-ASCII width-one leads plus CJK and emoji width-two leads; direct,
    explicitly settled, right-edge pending, no-wrap parked, and forced-wrap
    source states; default or cleared tab stops; and Mn, ZWJ, or ordinary
    narrow followers.  Cardinality: 2,880.
    """
    leads = (
        ("ascii", b"A", 1),
        ("unicode", "\u00e9".encode(), 1),
        ("cjk", "\u65e5".encode(), 2),
        ("emoji", "\U0001f680".encode(), 2),
    )
    followers = (
        ("mn", "\u0301".encode()),
        ("zwj", "\u200d".encode()),
        ("narrow", b"Z"),
    )
    for cols in range(1, 5):
        for rows in range(1, 4):
            for row in range(1, rows + 1):
                for lead_name, lead, width in leads:
                    left = max(1, cols - width + 1)
                    direct = (b"\x1b[?7h" +
                              f"\x1b[{row};1H".encode() + lead)
                    edge = f"\x1b[{row};{left}H".encode()
                    physical_edge = f"\x1b[{row};{cols}H".encode()
                    states = (
                        ("direct", direct),
                        ("settled", direct + f"\x1b[{row};1H".encode()),
                        ("pending", b"\x1b[?7h" + edge + lead),
                        ("parked", b"\x1b[?7l" + edge + lead),
                        ("wrapped", b"\x1b[?7h" + physical_edge + b"X" + lead),
                    )
                    for state_name, state_setup in states:
                        for tab_name, tab_setup in (
                            ("default-tabs", b""),
                            ("cleared-tabs", b"\x1b[3g"),
                        ):
                            for follower_name, follower in followers:
                                payload = (tab_setup + state_setup + b"\t" +
                                           follower)
                                name = (f"audit-ht-lastwrite-c{cols}-r{rows}-"
                                        f"y{row}-{lead_name}-{state_name}-"
                                        f"{tab_name}-{follower_name}")
                                yield Case(name, cols, rows, payload,
                                           (len(payload),), None)


def dl_single_content_matrix_cases() -> Iterator[Case]:
    """Audit DECLRMM DL's cursor-anchored virtual content window.

    Axes: heights 2...6; every valid vertical-margin pair; every physical
    cursor row; DL counts 1...height+1; and one distinct marker placed on
    each physical row in turn.  Width is one, DECLRMM is active, and all
    other cells are blank.  Cardinality: 5,880.
    """
    for rows in range(2, 7):
        for top in range(1, rows):
            for bottom in range(top + 1, rows + 1):
                for cursor_row in range(1, rows + 1):
                    for delete_count in range(1, rows + 2):
                        for marker_row in range(1, rows + 1):
                            payload = b"".join([
                                b"\x1b[?69h",
                                f"\x1b[{top};{bottom}r".encode(),
                                f"\x1b[{marker_row};1H".encode(),
                                b"a",
                                f"\x1b[{cursor_row};1H".encode(),
                                f"\x1b[{delete_count}M".encode(),
                            ])
                            name = (f"audit-dl-content-r{rows}-v{top}-{bottom}-"
                                    f"y{cursor_row}-n{delete_count}-"
                                    f"marker{marker_row}")
                            yield Case(name, 1, rows, payload,
                                        (len(payload),), None)


def selector_after_forward_motion_matrix_cases() -> Iterator[Case]:
    """Audit VS16 width growth after horizontal cursor motion.

    Axes: widths 3...6; default, active full/left/right/internal/one-column,
    and hidden-internal horizontal geometry; every physical starting column;
    two VS16-expanding narrow bases plus narrow and fixed-wide controls; ten
    forward, backward, absolute, and no-motion paths; VS15 or VS16; and with
    or without a following wide observer.  Cardinality: 23,040.
    """
    bases = (
        ("digit", b"0"),
        ("heart", "\u2764".encode()),
        ("ascii", b"A"),
        ("cjk", "\u65e5".encode()),
    )
    selectors = (
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
    )
    observers = (
        ("none", b""),
        ("wide", "\U0001f469\u200d\U0001f4bb".encode()),
    )
    for cols in range(3, 7):
        active_full = b"\x1b[?69h" + f"\x1b[1;{cols}s".encode()
        active_left = b"\x1b[?69h" + f"\x1b[1;{cols - 1}s".encode()
        active_right = b"\x1b[?69h" + f"\x1b[2;{cols}s".encode()
        active_internal = (b"\x1b[?69h"
                           + f"\x1b[2;{cols - 1}s".encode())
        active_left_one = b"\x1b[?69h\x1b[1;1s"
        active_right_one = (b"\x1b[?69h"
                            + f"\x1b[{cols};{cols}s".encode())
        geometries = (
            ("default", b""),
            ("active-full", active_full),
            ("active-left", active_left),
            ("active-right", active_right),
            ("active-internal", active_internal),
            ("active-left-one", active_left_one),
            ("active-right-one", active_right_one),
            ("hidden-internal", active_internal + b"\x1b[?69l"),
        )
        for geometry_name, geometry in geometries:
            for start in range(1, cols + 1):
                moves = (
                    ("none", b""),
                    ("decfi1", b"\x1b9"),
                    ("decfi2", b"\x1b9\x1b9"),
                    ("cuf1", b"\x1b[C"),
                    ("cuf2", b"\x1b[2C"),
                    ("cht1", b"\x1b[I"),
                    ("cub1", b"\x1b[D"),
                    ("decbi1", b"\x1b6"),
                    ("cup-same", f"\x1b[1;{start}H".encode()),
                    ("cup-next", f"\x1b[1;{start + 1}H".encode()),
                )
                for base_name, base in bases:
                    for move_name, move in moves:
                        for selector_name, selector in selectors:
                            for observer_name, observer in observers:
                                payload = b"".join((
                                    b"\x1b[?7h", geometry,
                                    f"\x1b[1;{start}H".encode(),
                                    base, move, selector, observer,
                                ))
                                name = (
                                    f"audit-selector-motion-c{cols}-"
                                    f"{geometry_name}-x{start}-{base_name}-"
                                    f"{move_name}-{selector_name}-"
                                    f"{observer_name}"
                                )
                                yield Case(name, cols, 2, payload,
                                           (len(payload),), None)


def selector_after_forward_motion_representative_cases() -> Iterator[Case]:
    """Freeze the random-0239 witness and compact motion controls."""
    reduced = (b"0\x1b9" + "\ufe0f".encode()
               + "\U0001f469\u200d\U0001f4bb".encode())
    yield Case("random-0239-selector-motion-scalar-residual", 4, 1,
               reduced, (len(reduced),), None)

    selected = (
        ("selector-motion-decfi-cursor",
         "audit-selector-motion-c4-default-x1-digit-decfi1-vs16-none"),
        ("selector-motion-decfi-wide-observer",
         "audit-selector-motion-c4-default-x1-digit-decfi1-vs16-wide"),
        ("selector-motion-decfi-repeated",
         "audit-selector-motion-c5-default-x1-digit-decfi2-vs16-none"),
        ("selector-motion-cuf-one",
         "audit-selector-motion-c4-default-x1-heart-cuf1-vs16-none"),
        ("selector-motion-cuf-two",
         "audit-selector-motion-c5-default-x1-heart-cuf2-vs16-wide"),
        ("selector-motion-cht",
         "audit-selector-motion-c4-default-x1-digit-cht1-vs16-none"),
        ("selector-motion-vs15-control",
         "audit-selector-motion-c4-default-x1-digit-decfi1-vs15-wide"),
        ("selector-motion-ascii-control",
         "audit-selector-motion-c4-default-x1-ascii-decfi1-vs16-wide"),
        ("selector-motion-fixed-wide-control",
         "audit-selector-motion-c4-default-x1-cjk-decfi1-vs16-wide"),
        ("selector-motion-none-control",
         "audit-selector-motion-c4-default-x1-digit-none-vs16-wide"),
        ("selector-motion-cub-control",
         "audit-selector-motion-c4-default-x2-digit-cub1-vs16-wide"),
        ("selector-motion-decbi-control",
         "audit-selector-motion-c4-default-x2-digit-decbi1-vs16-wide"),
        ("selector-motion-cup-same-control",
         "audit-selector-motion-c4-default-x1-digit-cup-same-vs16-wide"),
        ("selector-motion-cup-next-control",
         "audit-selector-motion-c4-default-x1-digit-cup-next-vs16-wide"),
        ("selector-motion-active-full",
         "audit-selector-motion-c4-active-full-x1-digit-decfi1-vs16-wide"),
        ("selector-motion-active-internal",
         "audit-selector-motion-c4-active-internal-x2-digit-decfi1-vs16-wide"),
        ("selector-motion-active-left-one",
         "audit-selector-motion-c4-active-left-one-x1-digit-decfi1-vs16-wide"),
        ("selector-motion-active-right-one",
         "audit-selector-motion-c4-active-right-one-x4-digit-decfi1-vs16-wide"),
        ("selector-motion-hidden-internal",
         "audit-selector-motion-c4-hidden-internal-x1-digit-decfi1-vs16-wide"),
        ("selector-motion-geometry-branch-01",
         "audit-selector-motion-c3-default-x1-digit-decfi2-vs16-none"),
        ("selector-motion-geometry-branch-02",
         "audit-selector-motion-c3-active-left-x3-digit-none-vs16-none"),
        ("selector-motion-geometry-branch-03",
         "audit-selector-motion-c3-active-left-x3-digit-none-vs16-wide"),
        ("selector-motion-geometry-branch-04",
         "audit-selector-motion-c3-active-left-x3-digit-decfi2-vs16-none"),
        ("selector-motion-geometry-branch-05",
         "audit-selector-motion-c3-active-left-x3-digit-cup-same-vs16-none"),
        ("selector-motion-geometry-branch-06",
         "audit-selector-motion-c3-active-left-x3-digit-cup-next-vs16-none"),
        ("selector-motion-geometry-branch-07",
         "audit-selector-motion-c3-active-right-x1-digit-none-vs15-none"),
        ("selector-motion-geometry-branch-08",
         "audit-selector-motion-c3-active-right-x1-digit-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-09",
         "audit-selector-motion-c3-active-right-x1-digit-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-10",
         "audit-selector-motion-c3-active-right-x1-digit-decbi1-vs15-none"),
        ("selector-motion-geometry-branch-11",
         "audit-selector-motion-c3-active-right-x1-ascii-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-12",
         "audit-selector-motion-c3-active-internal-x1-digit-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-13",
         "audit-selector-motion-c3-active-internal-x1-ascii-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-14",
         "audit-selector-motion-c3-active-left-one-x1-digit-decfi2-vs16-none"),
        ("selector-motion-geometry-branch-15",
         "audit-selector-motion-c3-active-left-one-x1-digit-decfi2-vs16-wide"),
        ("selector-motion-geometry-branch-16",
         "audit-selector-motion-c3-active-left-one-x2-digit-decfi2-vs16-none"),
        ("selector-motion-geometry-branch-17",
         "audit-selector-motion-c3-active-right-one-x1-digit-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-18",
         "audit-selector-motion-c3-active-right-one-x1-digit-decbi1-vs15-none"),
        ("selector-motion-geometry-branch-19",
         "audit-selector-motion-c3-active-right-one-x1-cjk-decbi1-vs15-none"),
        ("selector-motion-geometry-branch-20",
         "audit-selector-motion-c3-hidden-internal-x1-digit-none-vs15-none"),
        ("selector-motion-geometry-branch-21",
         "audit-selector-motion-c3-hidden-internal-x1-digit-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-22",
         "audit-selector-motion-c3-hidden-internal-x1-digit-decfi1-vs16-none"),
        ("selector-motion-geometry-branch-23",
         "audit-selector-motion-c3-hidden-internal-x1-digit-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-24",
         "audit-selector-motion-c3-hidden-internal-x1-digit-decfi2-vs16-none"),
        ("selector-motion-geometry-branch-25",
         "audit-selector-motion-c3-hidden-internal-x1-ascii-none-vs15-none"),
        ("selector-motion-geometry-branch-26",
         "audit-selector-motion-c3-hidden-internal-x2-digit-none-vs15-none"),
        ("selector-motion-geometry-branch-27",
         "audit-selector-motion-c4-active-left-x4-digit-decfi2-vs16-none"),
        ("selector-motion-geometry-branch-28",
         "audit-selector-motion-c4-active-right-x1-digit-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-29",
         "audit-selector-motion-c4-active-right-one-x1-digit-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-30",
         "audit-selector-motion-c4-active-right-one-x1-digit-decfi1-vs16-none"),
        ("selector-motion-geometry-branch-31",
         "audit-selector-motion-c4-active-right-one-x1-digit-decfi1-vs16-wide"),
        ("selector-motion-geometry-branch-32",
         "audit-selector-motion-c4-active-right-one-x1-cjk-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-33",
         "audit-selector-motion-c4-active-right-one-x1-cjk-decbi1-vs15-none"),
        ("selector-motion-geometry-branch-34",
         "audit-selector-motion-c4-hidden-internal-x1-digit-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-35",
         "audit-selector-motion-c5-active-right-one-x1-digit-decfi1-vs15-none"),
        ("selector-motion-geometry-branch-36",
         "audit-selector-motion-c5-active-right-one-x1-ascii-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-37",
         "audit-selector-motion-c5-active-right-one-x1-cjk-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-38",
         "audit-selector-motion-c5-hidden-internal-x1-digit-decfi2-vs15-none"),
        ("selector-motion-geometry-branch-39",
         "audit-selector-motion-c5-hidden-internal-x1-digit-decfi2-vs16-none"),
        ("selector-motion-geometry-branch-40",
         "audit-selector-motion-c6-active-right-one-x1-cjk-decfi2-vs15-none"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in selector_after_forward_motion_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing selector-motion controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def selector_forward_reverse_matrix_cases() -> Iterator[Case]:
    """Audit selector width ownership across compound horizontal motion.

    Axes: widths three, four, and six; default, active full/left/right/internal,
    and hidden-internal horizontal geometry; every physical start column;
    two selector-expandable bases plus narrow and fixed-wide controls; seven
    no-op, tab-like, and relative forward paths; five backward paths; both
    presentation selectors; no, narrow, and wide observers; and wrap on/off.
    Cardinality: 131,040.
    """
    bases = (
        ("digit", b"0"),
        ("heart", "\u2764".encode()),
        ("ascii", b"A"),
        ("cjk", "\u65e5".encode()),
    )
    forwards = (
        ("none", b""),
        ("cht1", b"\x1b[I"),
        ("cht2-counted", b"\x1b[2I"),
        ("cht2-repeated", b"\x1b[I\x1b[I"),
        ("ht", b"\t"),
        ("cuf2", b"\x1b[2C"),
        ("decfi2", b"\x1b9\x1b9"),
    )
    reverses = (
        ("none", b""),
        ("decbi1", b"\x1b6"),
        ("decbi2", b"\x1b6\x1b6"),
        ("cub1", b"\x1b[D"),
        ("bs1", b"\b"),
    )
    selectors = (
        ("text", "\ufe0e".encode()),
        ("emoji", "\ufe0f".encode()),
    )
    observers = (
        ("none", b""),
        ("narrow", b"Z"),
        ("wide", "\U0001f469\u200d\U0001f4bb".encode()),
    )
    for cols in (3, 4, 6):
        active_full = b"\x1b[?69h" + f"\x1b[1;{cols}s".encode()
        active_left = b"\x1b[?69h" + f"\x1b[1;{cols - 1}s".encode()
        active_right = b"\x1b[?69h" + f"\x1b[2;{cols}s".encode()
        active_internal = (b"\x1b[?69h" +
                           f"\x1b[2;{cols - 1}s".encode())
        geometries = (
            ("default", b""),
            ("active-full", active_full),
            ("active-left", active_left),
            ("active-right", active_right),
            ("active-internal", active_internal),
            ("hidden-internal", active_internal + b"\x1b[?69l"),
        )
        for geometry_name, geometry in geometries:
            for start in range(1, cols + 1):
                position = f"\x1b[1;{start}H".encode()
                for base_name, base in bases:
                    for forward_name, forward in forwards:
                        for reverse_name, reverse in reverses:
                            for selector_name, selector in selectors:
                                for observer_name, observer in observers:
                                    for wrap_name, wrap in (
                                        ("wrap", b"\x1b[?7h"),
                                        ("nowrap", b"\x1b[?7l"),
                                    ):
                                        payload = b"".join((
                                            wrap, geometry, position, base,
                                            forward, reverse, selector, observer,
                                        ))
                                        name = (
                                            f"audit-selector-forward-reverse-"
                                            f"c{cols}-{geometry_name}-x{start}-"
                                            f"{base_name}-{forward_name}-"
                                            f"{reverse_name}-{selector_name}-"
                                            f"{observer_name}-{wrap_name}"
                                        )
                                        yield Case(name, cols, 2, payload,
                                                   (len(payload),), None)


def selector_forward_reverse_representative_cases() -> Iterator[Case]:
    """Freeze the random-0777 residual and every predictor outcome leaf."""
    reduced = (b"0\x1b[2I\x1b6" + "\ufe0f".encode() +
               "A\u0301".encode())
    yield Case("random-0777-selector-forward-reverse-residual", 4, 1,
               reduced, (len(reduced),), None)

    selected = (
        ("selector-forward-reverse-scalar-observer",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-counted-decbi1-emoji-narrow-wrap"),
        ("selector-forward-reverse-counted-cursor",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-counted-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-heart",
         "audit-selector-forward-reverse-c4-default-x1-heart-cht1-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-literal-tab",
         "audit-selector-forward-reverse-c4-default-x1-digit-ht-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-cuf-cub",
         "audit-selector-forward-reverse-c4-default-x1-digit-cuf2-cub1-emoji-none-wrap"),
        ("selector-forward-reverse-decfi-decbi",
         "audit-selector-forward-reverse-c4-default-x1-digit-decfi2-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-double-left-cursor",
         "audit-selector-forward-reverse-c3-default-x2-digit-none-decbi2-emoji-none-wrap"),
        ("selector-forward-reverse-single-left-cursor",
         "audit-selector-forward-reverse-c3-active-left-x2-digit-cht1-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-repeated-noop-cursor",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-repeated-none-emoji-none-wrap"),
        ("selector-forward-reverse-repeat-narrow-nowrap",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-repeated-none-emoji-narrow-nowrap"),
        ("selector-forward-reverse-repeat-narrow-wrap",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-repeated-none-emoji-narrow-wrap"),
        ("selector-forward-reverse-repeat-wide-nowrap",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-repeated-none-emoji-wide-nowrap"),
        ("selector-forward-reverse-repeat-wide-wrap",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-repeated-none-emoji-wide-wrap"),
        ("selector-forward-reverse-return-to-owner-control",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht1-decbi2-emoji-none-wrap"),
        ("selector-forward-reverse-forward-only-control",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-counted-none-emoji-none-wrap"),
        ("selector-forward-reverse-single-back-control",
         "audit-selector-forward-reverse-c4-default-x1-digit-none-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-bs-control",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht1-bs1-emoji-none-wrap"),
        ("selector-forward-reverse-cuf-bs-control",
         "audit-selector-forward-reverse-c4-default-x1-digit-cuf2-bs1-emoji-none-wrap"),
        ("selector-forward-reverse-ascii-control",
         "audit-selector-forward-reverse-c4-default-x1-ascii-cht2-counted-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-fixed-wide-control",
         "audit-selector-forward-reverse-c4-default-x1-cjk-cht2-counted-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-text-selector-control",
         "audit-selector-forward-reverse-c4-default-x1-digit-cht2-counted-decbi1-text-none-wrap"),
        ("selector-forward-reverse-hidden-geometry",
         "audit-selector-forward-reverse-c6-hidden-internal-x1-digit-cht2-counted-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-nowrap",
         "audit-selector-forward-reverse-c6-default-x1-digit-cht2-counted-decbi1-emoji-none-nowrap"),
        ("selector-forward-reverse-active-right",
         "audit-selector-forward-reverse-c6-active-right-x1-digit-cht2-counted-decbi1-emoji-none-wrap"),
        ("selector-forward-reverse-double-left-observer",
         "audit-selector-forward-reverse-c3-default-x2-digit-none-decbi2-emoji-narrow-wrap"),
        ("selector-forward-reverse-single-left-observer",
         "audit-selector-forward-reverse-c3-active-left-x2-digit-cht1-decbi1-emoji-narrow-wrap"),
        ("selector-forward-reverse-double-right-cursor",
         "audit-selector-forward-reverse-c6-default-x1-digit-cht1-decbi2-emoji-none-wrap"),
        ("selector-forward-reverse-double-right-observer",
         "audit-selector-forward-reverse-c6-default-x1-digit-cht1-decbi2-emoji-narrow-wrap"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in selector_forward_reverse_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing selector forward/reverse controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def selector_motion_observer_matrix_cases() -> Iterator[Case]:
    """Audit the public observer boundary after selector width growth.

    Axes: widths 1...8; heights one and two; every starting column; wrap and
    no-wrap; five VS16-expanding bases plus four narrow/fixed-wide controls;
    ten horizontal motion paths; VS15 and VS16; and no, narrow, or wide
    observers.  Cardinality: 77,760.
    """
    bases = (
        ("digit", b"0"),
        ("hash", b"#"),
        ("star", b"*"),
        ("heart", "\u2764".encode()),
        ("plane", "\u2708".encode()),
        ("ascii", b"A"),
        ("unicode", "\u00e9".encode()),
        ("cjk", "\u65e5".encode()),
        ("woman", "\U0001f469".encode()),
    )
    selectors = (
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
    )
    observers = (
        ("none", b""),
        ("ascii", b"Z"),
        ("wide", "\U0001f469\u200d\U0001f4bb".encode()),
    )
    for cols in range(1, 9):
        for rows in (1, 2):
            for start in range(1, cols + 1):
                for wrap_name, wrap in (
                        ("wrap", b"\x1b[?7h"),
                        ("nowrap", b"\x1b[?7l")):
                    moves = (
                        ("none", b""),
                        ("decfi1", b"\x1b9"),
                        ("decfi2", b"\x1b9\x1b9"),
                        ("cuf1", b"\x1b[C"),
                        ("cuf2", b"\x1b[2C"),
                        ("cub1", b"\x1b[D"),
                        ("decbi1", b"\x1b6"),
                        ("cup-same", f"\x1b[1;{start}H".encode()),
                        ("cup-next", f"\x1b[1;{start + 1}H".encode()),
                        ("cht1", b"\x1b[I"),
                    )
                    for base_name, base in bases:
                        for move_name, move in moves:
                            for selector_name, selector in selectors:
                                for observer_name, observer in observers:
                                    payload = b"".join((
                                        wrap,
                                        f"\x1b[1;{start}H".encode(),
                                        base, move, selector, observer,
                                    ))
                                    name = (
                                        f"audit-selector-observer-c{cols}-"
                                        f"r{rows}-x{start}-{wrap_name}-"
                                        f"{base_name}-{move_name}-"
                                        f"{selector_name}-{observer_name}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def selector_motion_observer_representative_cases() -> Iterator[Case]:
    """Freeze one compact public control for each predictor leaf."""
    selected = (
        ("selector-observer-nonexpanding-control",
         "audit-selector-observer-c4-r1-x1-wrap-ascii-decfi1-vs16-none"),
        ("selector-observer-motion-control",
         "audit-selector-observer-c4-r1-x1-wrap-digit-none-vs16-none"),
        ("selector-observer-none-delta",
         "audit-selector-observer-c4-r1-x1-wrap-digit-decfi1-vs16-none"),
        ("selector-observer-interior-delta",
         "audit-selector-observer-c5-r1-x1-wrap-digit-cuf1-vs16-wide"),
        ("selector-observer-boundary-ascii-wrap",
         "audit-selector-observer-c4-r1-x2-wrap-digit-decfi1-vs16-ascii"),
        ("selector-observer-boundary-ascii-nowrap",
         "audit-selector-observer-c4-r1-x2-nowrap-digit-decfi1-vs16-ascii"),
        ("selector-observer-boundary-wide-wrap",
         "audit-selector-observer-c4-r1-x2-wrap-digit-decfi1-vs16-wide"),
        ("selector-observer-boundary-wide-nowrap",
         "audit-selector-observer-c4-r1-x2-nowrap-digit-decfi1-vs16-wide"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in selector_motion_observer_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing selector-observer controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def selector_reposition_left_matrix_cases() -> Iterator[Case]:
    """Audit selector ownership after moving left of the prior glyph.

    Axes: widths 3, 4, and 6; heights one and two; every interior starting
    column; wrap and no-wrap; default and hidden-internal geometry; two
    VS16-expanding bases plus narrow and fixed-wide controls; no motion,
    forward motion, carriage return, absolute row/column positioning, and
    one- or two-column backward motion; VS15 or VS16; and with or without a
    following wide observer. Cardinality: 9,408.
    """
    bases = (
        ("digit", b"0"),
        ("heart", "\u2764".encode()),
        ("ascii", b"A"),
        ("unicode", "\u00e9".encode()),
        ("cjk", "\u65e5".encode()),
        ("woman", "\U0001f469".encode()),
    )
    moves = (
        ("none", b""),
        ("cuf1", b"\x1b[C"),
        ("cr", b"\r"),
        ("cup1", b"\x1b[1;1H"),
        ("cha1", b"\x1b[G"),
        ("cub1", b"\x1b[D"),
        ("cub2", b"\x1b[2D"),
    )
    selectors = (
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
    )
    observers = (
        ("none", b""),
        ("wide", "\u2764\ufe0f".encode()),
    )
    for cols in (3, 4, 6):
        geometries = (
            ("default", b""),
            ("hidden-internal", b"\x1b[?69h"
             + f"\x1b[2;{cols - 1}s".encode() + b"\x1b[?69l"),
        )
        for rows in (1, 2):
            for start in range(2, cols):
                for wrap_name, wrap in (
                        ("wrap", b"\x1b[?7h"),
                        ("nowrap", b"\x1b[?7l")):
                    for geometry_name, geometry in geometries:
                        for base_name, base in bases:
                            for move_name, move in moves:
                                for selector_name, selector in selectors:
                                    for observer_name, observer in observers:
                                        payload = b"".join((
                                            wrap, geometry,
                                            f"\x1b[1;{start}H".encode(),
                                            base, move, selector, observer,
                                        ))
                                        name = (
                                            f"audit-selector-reposition-c{cols}-"
                                            f"r{rows}-x{start}-{wrap_name}-"
                                            f"{geometry_name}-{base_name}-"
                                            f"{move_name}-{selector_name}-"
                                            f"{observer_name}"
                                        )
                                        yield Case(name, cols, rows, payload,
                                                   (len(payload),), None)


def selector_reposition_left_representative_cases() -> Iterator[Case]:
    """Freeze the random-0286 witness and every new predictor leaf."""
    reduced = b"".join((
        b"\x1b9", b"0", b"\r", "\ufe0f".encode(),
        "\u2764\ufe0f".encode(),
    ))
    yield Case("random-0286-selector-reposition-scalar-residual", 3, 1,
               reduced, (len(reduced),), None)

    selected = (
        ("selector-reposition-nonexpandable-control",
         "audit-selector-reposition-c4-r1-x2-wrap-default-ascii-cr-vs16-wide"),
        ("selector-reposition-vs15-control",
         "audit-selector-reposition-c4-r1-x2-wrap-default-digit-cr-vs15-wide"),
        ("selector-reposition-owner-control",
         "audit-selector-reposition-c4-r1-x2-wrap-default-digit-cub1-vs16-wide"),
        ("selector-reposition-cr",
         "audit-selector-reposition-c4-r1-x2-wrap-default-digit-cr-vs16-wide"),
        ("selector-reposition-cup",
         "audit-selector-reposition-c4-r1-x2-wrap-default-digit-cup1-vs16-wide"),
        ("selector-reposition-cha",
         "audit-selector-reposition-c4-r1-x2-nowrap-hidden-internal-heart-cha1-vs16-none"),
        ("selector-reposition-cub-two",
         "audit-selector-reposition-c6-r2-x4-wrap-hidden-internal-heart-cub2-vs16-none"),
        ("selector-reposition-forward-boundary-observer",
         "audit-selector-reposition-c4-r2-x2-wrap-default-digit-cuf1-vs16-wide"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in selector_reposition_left_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing selector reposition controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def selector_after_vertical_reposition_matrix_cases() -> Iterator[Case]:
    """Audit VS width growth after vertical cursor relocation.

    The core crosses four widths, three heights, every owner coordinate,
    wrap/no-wrap, two expanding bases plus narrow and fixed-wide controls,
    eighteen actual/no-op vertical and absolute relocation paths, VS15/VS16,
    and no/narrow observers.  A geometry supplement crosses default, active,
    and hidden horizontal-margin layouts. Cardinality: 84,672.
    """
    bases = (
        ("digit", b"0"),
        ("heart", "\u2764".encode()),
        ("ascii", b"A"),
        ("cjk", "\u65e5".encode()),
    )
    selectors = (("vs15", "\ufe0e".encode()),
                 ("vs16", "\ufe0f".encode()))
    observers = (("none", b""), ("narrow", b"Z"))

    def relocations(rows: int, owner_row: int, owner_col: int
                    ) -> tuple[tuple[str, bytes], ...]:
        other_row = owner_row % rows + 1
        after_column = owner_col + 1
        return (
            ("none", b""),
            ("cup-same", f"\x1b[{owner_row};{owner_col}H".encode()),
            ("cup-other-owner", f"\x1b[{other_row};{owner_col}H".encode()),
            ("cup-other-left", f"\x1b[{other_row};1H".encode()),
            ("cup-other-after", f"\x1b[{other_row};{after_column}H".encode()),
            ("vpa-other", f"\x1b[{other_row}d".encode()),
            ("cuu1", b"\x1b[A"),
            ("cud1", b"\x1b[B"),
            ("ind", b"\x1bD"),
            ("lf", b"\n"),
            ("ri", b"\x1bM"),
            ("nel", b"\x1bE"),
            ("decstbm-reset", b"\x1b[r"),
            ("decstbm-full", f"\x1b[1;{rows}r".encode()),
            ("decstbm-partial", f"\x1b[1;{max(2, rows - 1)}r".encode()),
            ("origin-enable", b"\x1b[?6h"),
            ("origin-disable", b"\x1b[?6l"),
            ("cr", b"\r"),
        )

    for cols in (2, 3, 4, 6):
        for rows in (2, 3, 4):
            for owner_row in range(1, rows + 1):
                for owner_col in range(1, cols + 1):
                    for wrap_name, wrap in (("wrap", b"\x1b[?7h"),
                                             ("nowrap", b"\x1b[?7l")):
                        for base_name, base in bases:
                            for relocation_name, relocation in relocations(
                                    rows, owner_row, owner_col):
                                for selector_name, selector in selectors:
                                    for observer_name, observer in observers:
                                        payload = b"".join((
                                            wrap,
                                            f"\x1b[{owner_row};{owner_col}H".encode(),
                                            base, relocation, selector, observer,
                                        ))
                                        name = (
                                            f"audit-selector-vertical-core-c{cols}-"
                                            f"r{rows}-y{owner_row}-x{owner_col}-"
                                            f"{wrap_name}-{base_name}-"
                                            f"{relocation_name}-{selector_name}-"
                                            f"{observer_name}"
                                        )
                                        yield Case(name, cols, rows, payload,
                                                   (len(payload),), None)

    cols = 4
    rows = 3
    geometries = (
        ("default", b""),
        ("active-full", b"\x1b[?69h\x1b[1;4s"),
        ("active-left", b"\x1b[?69h\x1b[1;3s"),
        ("active-right", b"\x1b[?69h\x1b[2;4s"),
        ("active-internal", b"\x1b[?69h\x1b[2;3s"),
        ("hidden-internal", b"\x1b[?69h\x1b[2;3s\x1b[?69l"),
    )
    for geometry_name, geometry in geometries:
        for owner_col in range(1, cols + 1):
            for wrap_name, wrap in (("wrap", b"\x1b[?7h"),
                                     ("nowrap", b"\x1b[?7l")):
                for base_name, base in (("digit", b"0"), ("ascii", b"A")):
                    for relocation_name, relocation in relocations(
                            rows, 2, owner_col):
                        for selector_name, selector in selectors:
                            for observer_name, observer in observers:
                                payload = b"".join((
                                    wrap, geometry,
                                    f"\x1b[2;{owner_col}H".encode(), base,
                                    relocation, selector, observer,
                                ))
                                name = (
                                    f"audit-selector-vertical-geometry-"
                                    f"{geometry_name}-x{owner_col}-{wrap_name}-"
                                    f"{base_name}-{relocation_name}-"
                                    f"{selector_name}-{observer_name}"
                                )
                                yield Case(name, cols, rows, payload,
                                           (len(payload),), None)


def selector_after_vertical_reposition_representative_cases() -> Iterator[Case]:
    """Freeze the random-0359 residual and every predictor leaf."""
    reduced = b" \x1bD0\x1b[r" + "\ufe0f".encode() + b"Z"
    yield Case("random-0359-selector-vertical-scalar-residual", 14, 8,
               reduced, (len(reduced),), None)

    selected = (
        ("selector-vertical-core-down-cursor", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-cud1-vs16-none"),
        ("selector-vertical-core-down-converged", "audit-selector-vertical-core-c2-r2-y1-x1-nowrap-digit-cud1-vs16-narrow"),
        ("selector-vertical-core-down-observer", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-cud1-vs16-narrow"),
        ("selector-vertical-region-cursor", "audit-selector-vertical-core-c2-r2-y2-x1-wrap-digit-decstbm-reset-vs16-none"),
        ("selector-vertical-region-observer", "audit-selector-vertical-core-c2-r2-y2-x1-wrap-digit-decstbm-reset-vs16-narrow"),
        ("selector-vertical-up-cursor", "audit-selector-vertical-core-c2-r2-y2-x1-wrap-digit-cuu1-vs16-none"),
        ("selector-vertical-up-converged", "audit-selector-vertical-core-c2-r2-y2-x1-nowrap-digit-cuu1-vs16-narrow"),
        ("selector-vertical-up-observer", "audit-selector-vertical-core-c2-r2-y2-x1-wrap-digit-cuu1-vs16-narrow"),
        ("selector-vertical-scroll-cursor", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-cup-other-owner-vs16-none"),
        ("selector-vertical-scroll-converged", "audit-selector-vertical-core-c2-r2-y1-x1-nowrap-digit-cup-other-after-vs16-narrow"),
        ("selector-vertical-scroll-observer", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-cup-other-owner-vs16-narrow"),
        ("selector-vertical-exterior-nowrap-cursor", "audit-selector-vertical-geometry-active-left-x4-nowrap-digit-cup-other-owner-vs16-none"),
        ("selector-vertical-exterior-nowrap-converged", "audit-selector-vertical-geometry-active-left-x4-nowrap-digit-cup-other-owner-vs16-narrow"),
        ("selector-vertical-exterior-nowrap-observer", "audit-selector-vertical-geometry-active-left-x4-nowrap-digit-cup-other-left-vs16-narrow"),
        ("selector-vertical-exterior-wrap-internal-cursor", "audit-selector-vertical-geometry-active-internal-x4-wrap-digit-cuu1-vs16-none"),
        ("selector-vertical-exterior-wrap-internal-observer", "audit-selector-vertical-geometry-active-internal-x4-wrap-digit-cuu1-vs16-narrow"),
        ("selector-vertical-exterior-wrap-left-overadvance-cursor", "audit-selector-vertical-geometry-active-left-x4-wrap-digit-cup-other-left-vs16-none"),
        ("selector-vertical-exterior-wrap-left-overadvance-observer", "audit-selector-vertical-geometry-active-left-x4-wrap-digit-cup-other-left-vs16-narrow"),
        ("selector-vertical-exterior-wrap-left-underadvance-cursor", "audit-selector-vertical-geometry-active-left-x4-wrap-digit-cuu1-vs16-none"),
        ("selector-vertical-exterior-wrap-left-underadvance-observer", "audit-selector-vertical-geometry-active-left-x4-wrap-digit-cuu1-vs16-narrow"),
        ("selector-vertical-exterior-wrap-left-absolute-other-control", "audit-selector-vertical-geometry-active-left-x4-wrap-digit-cup-other-owner-vs16-none"),
        ("selector-vertical-exterior-wrap-internal-absolute-left-control", "audit-selector-vertical-geometry-active-internal-x4-wrap-digit-cup-other-left-vs16-none"),
        ("selector-vertical-geometry-interior-cursor", "audit-selector-vertical-geometry-default-x1-wrap-digit-cup-other-owner-vs16-none"),
        ("selector-vertical-geometry-nowrap-converged", "audit-selector-vertical-geometry-default-x3-nowrap-digit-cup-other-after-vs16-narrow"),
        ("selector-vertical-geometry-wrap-converged", "audit-selector-vertical-geometry-active-left-x3-wrap-digit-cup-other-after-vs16-narrow"),
        ("selector-vertical-geometry-interior-observer", "audit-selector-vertical-geometry-default-x1-wrap-digit-cup-other-owner-vs16-narrow"),
        ("selector-vertical-negative-base", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-ascii-none-vs16-none"),
        ("selector-vertical-negative-down-clamped", "audit-selector-vertical-core-c2-r2-y2-x1-wrap-digit-cud1-vs16-none"),
        ("selector-vertical-negative-up-clamped", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-cuu1-vs16-none"),
        ("selector-vertical-negative-geometry-control", "audit-selector-vertical-geometry-default-x1-wrap-digit-none-vs16-none"),
        ("selector-vertical-negative-exterior-control", "audit-selector-vertical-geometry-active-left-x4-nowrap-digit-none-vs16-none"),
        ("selector-vertical-negative-exterior-wrap", "audit-selector-vertical-geometry-active-left-x4-wrap-digit-none-vs16-none"),
        ("selector-vertical-negative-geometry-edge", "audit-selector-vertical-geometry-default-x4-wrap-digit-none-vs16-none"),
        ("selector-vertical-negative-nonvertical", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-none-vs16-none"),
        ("selector-vertical-negative-physical-edge", "audit-selector-vertical-core-c2-r2-y1-x2-wrap-digit-none-vs16-none"),
        ("selector-vertical-negative-same-row-home", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-decstbm-reset-vs16-none"),
        ("selector-vertical-negative-vs15", "audit-selector-vertical-core-c2-r2-y1-x1-wrap-digit-none-vs15-none"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in selector_after_vertical_reposition_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing selector vertical controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def active_margin_pending_backspace_matrix_cases() -> Iterator[Case]:
    """Audit BS after a pending print at a stored horizontal right edge.

    Axes: widths 4, 6, and 10; every row of heights one through three;
    default, active-full, hidden-internal, active-left, active-right, and
    active-internal geometry; pending narrow, pending wide, settled,
    no-wrap parked, pending-then-hidden, and pending-then-no-wrap states;
    reverse wrap on/off; one or two backspaces; and no, narrow, or wide
    observers. Cardinality: 7,776.
    """
    for cols in (4, 6, 10):
        geometries = (
            ("default", b"", 1, cols),
            ("active-full",
             b"\x1b[?69h" + f"\x1b[1;{cols}s".encode(), 1, cols),
            ("hidden-internal",
             b"\x1b[?69h" + f"\x1b[2;{cols - 1}s".encode()
             + b"\x1b[?69l", 1, cols),
            ("active-left",
             b"\x1b[?69h" + f"\x1b[1;{cols - 1}s".encode(),
             1, cols - 1),
            ("active-right",
             b"\x1b[?69h" + f"\x1b[2;{cols}s".encode(),
             2, cols),
            ("active-internal",
             b"\x1b[?69h" + f"\x1b[2;{cols - 1}s".encode(),
             2, cols - 1),
        )
        for rows in range(1, 4):
            for row in range(1, rows + 1):
                for geometry_name, geometry, _left, right in geometries:
                    position_right = f"\x1b[{row};{right}H".encode()
                    position_wide = f"\x1b[{row};{right - 1}H".encode()
                    states = (
                        ("pending-narrow", b"\x1b[?7h" + position_right + b"A"),
                        ("pending-wide", b"\x1b[?7h" + position_wide
                         + "\u65e5".encode()),
                        ("settled-right", b"\x1b[?7h" + position_right),
                        ("nowrap-narrow", b"\x1b[?7l" + position_right + b"A"),
                        ("pending-hide", b"\x1b[?7h" + position_right
                         + b"A\x1b[?69l"),
                        ("pending-nowrap", b"\x1b[?7h" + position_right
                         + b"A\x1b[?7l"),
                    )
                    for state_name, state in states:
                        for reverse_wrap, reverse_setup in (
                            (False, b"\x1b[?45l"),
                            (True, b"\x1b[?45h"),
                        ):
                            for backspaces in (1, 2):
                                for observer_name, observer in (
                                    ("none", b""),
                                    ("narrow", b"Z"),
                                    ("wide", "\u65e5".encode()),
                                ):
                                    payload = (geometry + reverse_setup + state
                                               + b"\b" * backspaces + observer)
                                    name = (
                                        f"audit-active-margin-pending-bs-"
                                        f"c{cols}-r{rows}-y{row}-{geometry_name}-"
                                        f"{state_name}-rw{int(reverse_wrap)}-"
                                        f"bs{backspaces}-{observer_name}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def active_margin_pending_backspace_representative_cases() -> Iterator[Case]:
    """Freeze random-0291 and every bounded pending-BS predictor branch."""
    reduced = b"".join((
        b"\x1b[?69h", b"\x1b[2;9s", b"\t", b"a", b"\b",
        "\u65e5".encode(),
    ))
    yield Case("random-0291-active-margin-pending-backspace", 10, 2,
               reduced, (len(reduced),), None)

    selected = (
        ("pending-bs-physical-edge-control",
         "audit-active-margin-pending-bs-c4-r2-y1-active-right-pending-narrow-rw0-bs1-none"),
        ("pending-bs-settled-control",
         "audit-active-margin-pending-bs-c4-r2-y1-active-left-settled-right-rw0-bs1-none"),
        ("pending-bs-nowrap-parked-control",
         "audit-active-margin-pending-bs-c4-r2-y1-active-left-nowrap-narrow-rw0-bs1-none"),
        ("pending-bs-outside-reverse-control",
         "audit-active-margin-pending-bs-c4-r2-y1-active-left-pending-narrow-rw1-bs1-none"),
        ("pending-bs-outside-clamped-control",
         "audit-active-margin-pending-bs-c4-r2-y1-active-internal-pending-narrow-rw0-bs2-none"),
        ("pending-bs-outside-visible",
         "audit-active-margin-pending-bs-c4-r2-y1-active-left-pending-narrow-rw0-bs1-none"),
        ("pending-bs-wide-owner-visible",
         "audit-active-margin-pending-bs-c6-r2-y1-active-internal-pending-wide-rw0-bs1-none"),
        ("pending-bs-nowrap-toggle-visible",
         "audit-active-margin-pending-bs-c6-r2-y1-active-internal-pending-nowrap-rw0-bs1-none"),
        ("pending-bs-addressable-normal-control",
         "audit-active-margin-pending-bs-c4-r2-y1-active-left-pending-hide-rw0-bs1-none"),
        ("pending-bs-addressable-reverse-visible",
         "audit-active-margin-pending-bs-c4-r2-y1-active-left-pending-hide-rw1-bs1-none"),
        ("pending-bs-wide-observer-coincidence",
         "audit-active-margin-pending-bs-c4-r1-y1-active-internal-pending-narrow-rw0-bs1-wide"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in active_margin_pending_backspace_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing pending BS controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def ht_selector_cursor_width_matrix_cases() -> Iterator[Case]:
    """Audit selector width growth after a literal horizontal tab.

    Axes: physical widths 3, 8, 9, and 11; one-row and two-row/top-row
    geometry; default, active full/left/right/internal, and hidden-internal
    horizontal bounds; every effective owner column; default, cleared, and
    one custom tab-stop layout; two VS16-expandable narrow bases plus narrow
    and fixed-wide controls; VS15/VS16; no, narrow, or wide observers; and
    wrap/no-wrap. Cardinality: 48,960.
    """
    bases = (
        ("digit", b"0"),
        ("heart", "\u2764".encode()),
        ("ascii", b"A"),
        ("cjk", "\u65e5".encode()),
    )
    selectors = (
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
    )
    observers = (
        ("none", b""),
        ("narrow", b"Z"),
        ("wide", "\u65e5".encode()),
    )
    for cols in (3, 8, 9, 11):
        custom_stop = (cols + 1) // 2
        tab_layouts = (
            ("default", b""),
            ("cleared", b"\x1b[3g"),
            ("custom", b"\x1b[3g"
             + f"\x1b[1;{custom_stop}H".encode() + b"\x1bH"),
        )
        geometries = (
            ("default", b"", 1, cols),
            ("active-full",
             b"\x1b[?69h" + f"\x1b[1;{cols}s".encode(), 1, cols),
            ("active-left",
             b"\x1b[?69h" + f"\x1b[1;{cols - 1}s".encode(),
             1, cols - 1),
            ("active-right",
             b"\x1b[?69h" + f"\x1b[2;{cols}s".encode(),
             2, cols),
            ("active-internal",
             b"\x1b[?69h" + f"\x1b[2;{cols - 1}s".encode(),
             2, cols - 1),
            ("hidden-internal",
             b"\x1b[?69h" + f"\x1b[2;{cols - 1}s".encode()
             + b"\x1b[?69l", 1, cols),
        )
        for rows, row in ((1, 1), (2, 1)):
            for geometry_name, geometry, left, right in geometries:
                for start in range(left, right + 1):
                    position = f"\x1b[{row};{start}H".encode()
                    for tab_name, tab_setup in tab_layouts:
                        for base_name, base in bases:
                            for selector_name, selector in selectors:
                                for observer_name, observer in observers:
                                    for wrap_name, wrap in (
                                        ("wrap", b"\x1b[?7h"),
                                        ("nowrap", b"\x1b[?7l"),
                                    ):
                                        payload = (wrap + tab_setup + geometry
                                                   + position + base + b"\t"
                                                   + selector + observer)
                                        name = (
                                            f"audit-ht-selector-width-c{cols}-"
                                            f"r{rows}-y{row}-{geometry_name}-"
                                            f"x{start}-{tab_name}-{base_name}-"
                                            f"{selector_name}-{observer_name}-"
                                            f"{wrap_name}"
                                        )
                                        yield Case(name, cols, rows, payload,
                                                   (len(payload),), None)


def ht_selector_cursor_width_representative_cases() -> Iterator[Case]:
    """Freeze random-0291's second residual and every HT predictor leaf."""
    reduced = b"0\t" + "\ufe0f".encode() + "\u65e5".encode()
    yield Case("random-0291-ht-selector-cursor-width-residual", 11, 1,
               reduced, (len(reduced),), None)

    selected = (
        ("ht-selector-nonexpanding-control",
         "audit-ht-selector-width-c11-r1-y1-default-x1-default-ascii-vs16-none-wrap"),
        ("ht-selector-fixed-wide-control",
         "audit-ht-selector-width-c11-r1-y1-default-x1-default-cjk-vs16-none-wrap"),
        ("ht-selector-vs15-control",
         "audit-ht-selector-width-c11-r1-y1-default-x1-default-digit-vs15-none-wrap"),
        ("ht-selector-no-progress-control",
         "audit-ht-selector-width-c11-r1-y1-default-x10-default-digit-vs16-none-wrap"),
        ("ht-selector-pending-normalization-control",
         "audit-ht-selector-width-c11-r1-y1-default-x11-default-digit-vs16-none-wrap"),
        ("ht-selector-stage-visible",
         "audit-ht-selector-width-c11-r1-y1-default-x1-default-digit-vs16-none-wrap"),
        ("ht-selector-active-visible",
         "audit-ht-selector-width-c11-r1-y1-active-internal-x2-default-heart-vs16-none-wrap"),
        ("ht-selector-hidden-visible",
         "audit-ht-selector-width-c11-r1-y1-hidden-internal-x1-default-digit-vs16-none-wrap"),
        ("ht-selector-cleared-visible",
         "audit-ht-selector-width-c11-r1-y1-default-x1-cleared-digit-vs16-none-wrap"),
        ("ht-selector-custom-visible",
         "audit-ht-selector-width-c11-r1-y1-default-x1-custom-digit-vs16-none-wrap"),
        ("ht-selector-narrow-wrap-visible",
         "audit-ht-selector-width-c11-r1-y1-default-x1-cleared-digit-vs16-narrow-wrap"),
        ("ht-selector-narrow-interior-visible",
         "audit-ht-selector-width-c11-r1-y1-default-x1-default-digit-vs16-narrow-nowrap"),
        ("ht-selector-narrow-edge-convergence",
         "audit-ht-selector-width-c11-r1-y1-default-x1-cleared-digit-vs16-narrow-nowrap"),
        ("ht-selector-wide-nowrap-visible",
         "audit-ht-selector-width-c11-r1-y1-default-x1-cleared-digit-vs16-wide-nowrap"),
        ("ht-selector-wide-interior-visible",
         "audit-ht-selector-width-c11-r1-y1-default-x1-default-digit-vs16-wide-wrap"),
        ("ht-selector-wide-edge-convergence",
         "audit-ht-selector-width-c11-r1-y1-default-x1-cleared-digit-vs16-wide-wrap"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in ht_selector_cursor_width_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing HT selector controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)

    cht_source = (
        "audit-selector-observer-c8-r1-x1-wrap-digit-cht1-vs16-none"
    )
    for case in selector_motion_observer_matrix_cases():
        if case.name == cht_source:
            yield Case("ht-selector-cht-control", case.cols, case.rows,
                       case.payload, case.chunks, case.resize)
            break
    else:
        raise AssertionError("missing HT selector CHT control")


def _active_margin_irm_orphan_tail_case(
    name: str,
    *,
    cols: int = 10,
    geometry: str = "active-internal",
    insert_phase: str = "both",
    tail: str = "wide-head",
    inserted: str = "wide",
    history: str = "il2",
    marker: str = "outside-narrow",
    shifts: int = 1,
    observer: str = "wrapped-wide",
    wrap: bool = True,
    interposed: str = "none",
) -> Case:
    """Build one bounded IRM orphan-tail transition without random state."""
    rows = 3
    geometry_profiles = {
        "default": (b"", 1, cols),
        "active-full": (
            b"\x1b[?69h" + f"\x1b[1;{cols}s".encode(), 1, cols),
        "active-left": (
            b"\x1b[?69h" + f"\x1b[1;{cols - 1}s".encode(),
            1, cols - 1),
        "active-right": (
            b"\x1b[?69h" + f"\x1b[2;{cols}s".encode(), 2, cols),
        "active-internal": (
            b"\x1b[?69h" + f"\x1b[2;{cols - 1}s".encode(),
            2, cols - 1),
        "hidden-internal": (
            b"\x1b[?69h" + f"\x1b[2;{cols - 1}s".encode()
            + b"\x1b[?69l", 1, cols),
    }
    geometry_bytes, left, right = geometry_profiles[geometry]
    wide = "\u65e5".encode()
    if tail == "wide-head":
        seed = b"A" * max(0, right - 3) + wide + b"Z"
    elif tail == "continuation":
        seed = b"A" * max(0, right - 4) + wide + b"ZZ"
    elif tail == "narrow":
        seed = b"A" * max(0, right - 2) + b"YZ"
    elif tail == "blank":
        seed = b"A" * max(0, right - 3)
    else:
        raise AssertionError(tail)

    seed_insert = insert_phase in ("both", "seed-only")
    observer_insert = insert_phase in ("both", "observer-only")
    payload: list[bytes] = [b"\x1b[4h" if seed_insert else b"\x1b[4l"]
    seed_row = 2 if history == "aligned-none" else 1
    payload.extend((f"\x1b[{seed_row};1H".encode(), seed, geometry_bytes))
    insert_col = min(max(left + 2, 1), max(1, right - 3))
    payload.append(f"\x1b[{seed_row};{insert_col}H".encode())
    inserted_values = {
        "wide": wide,
        "narrow": b"Q",
        "blank": b"\x1b[@",
        "none": b"",
    }
    payload.append(inserted_values[inserted])

    if history == "il1":
        payload.append(b"\x1b[L")
        source_row, destination_row = 1, 2
    elif history == "il2":
        payload.append(b"\x1b[2L")
        source_row, destination_row = 2, 3
    elif history == "none":
        source_row, destination_row = 2, 3
    elif history == "aligned-none":
        source_row, destination_row = 1, 2
    else:
        raise AssertionError(history)

    marker_col = max(1, left - 1)
    if marker == "outside-narrow":
        payload.extend((f"\x1b[{source_row};{marker_col}H".encode(), b"0"))
    elif marker == "outside-wide":
        payload.extend((f"\x1b[{source_row};{marker_col}H".encode(), wide))
    elif marker == "inside-narrow":
        payload.extend((f"\x1b[{source_row};{left}H".encode(), b"0"))
    elif marker == "none":
        payload.append(f"\x1b[{source_row};{left}H".encode())
    else:
        raise AssertionError(marker)
    payload.append(b"\x1b6" * shifts)

    if interposed == "kitty":
        payload.append(
            b"\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\x1b\\")
    elif interposed == "narrow-destination":
        payload.append(f"\x1b[{destination_row};{left}H".encode() + b"N")
    elif interposed == "wide-destination":
        payload.append(f"\x1b[{destination_row};{left}H".encode() + wide)
    elif interposed == "blank-destination":
        payload.append(
            f"\x1b[{destination_row};{left}H".encode() + b"\x1b[@")
    elif interposed != "none":
        raise AssertionError(interposed)

    payload.extend((b"\x1b[4h" if observer_insert else b"\x1b[4l",
                    b"\x1b[?7h" if wrap else b"\x1b[?7l"))
    if observer == "wrapped-wide":
        payload.append(f"\x1b[{source_row};{right}H".encode() + wide)
    elif observer == "wrapped-narrow":
        payload.append(f"\x1b[{source_row};{right}H".encode() + b"NN")
    elif observer == "pending-narrow":
        payload.append(f"\x1b[{source_row};{right}H".encode() + b"N")
    elif observer == "direct-wide":
        payload.append(f"\x1b[{destination_row};{left}H".encode() + wide)
    elif observer == "direct-narrow":
        payload.append(f"\x1b[{destination_row};{left}H".encode() + b"N")
    elif observer == "direct-blank":
        payload.append(
            f"\x1b[{destination_row};{left}H".encode() + b"\x1b[@")
    elif observer != "none":
        raise AssertionError(observer)

    combined = b"".join(payload)
    return Case(name, cols, rows, combined, (len(combined),), None)


def active_margin_irm_orphan_tail_matrix_cases() -> Iterator[Case]:
    """Audit printable insertion against an exterior orphan wide head.

    The core product crosses physical width, active/hidden/default horizontal
    geometry, insert-mode phase, four right-tail topologies, four seed
    mutations, displaced/aligned/no row histories, four source shapes, and
    zero through two rectangular shifts.  A focused observer product crosses
    wrapped, pending, direct, and absent writes; wrap mode; and inert, blank,
    narrow, or wide interposed destination actions.  One-axis controls retain
    every negative independently. Cardinality: 55,552.
    """
    axes: tuple[tuple[str, tuple[object, ...]], ...] = (
        ("cols", (8, 10, 12)),
        ("geometry", ("default", "active-full", "active-left",
                      "active-right", "active-internal", "hidden-internal")),
        ("insert_phase", ("both", "seed-only", "observer-only", "off")),
        ("tail", ("wide-head", "continuation", "narrow", "blank")),
        ("inserted", ("wide", "narrow", "blank", "none")),
        ("history", ("il1", "il2", "none", "aligned-none")),
        ("marker", ("outside-narrow", "outside-wide", "inside-narrow", "none")),
        ("shifts", (0, 1, 2)),
        ("observer", ("wrapped-wide", "wrapped-narrow", "pending-narrow",
                      "direct-wide", "direct-narrow", "direct-blank", "none")),
        ("wrap", (True, False)),
        ("interposed", ("none", "kitty", "narrow-destination",
                        "wide-destination", "blank-destination")),
    )
    values = {key: choices for key, choices in axes}
    base: dict[str, object] = {
        "cols": 10,
        "geometry": "active-internal",
        "insert_phase": "both",
        "tail": "wide-head",
        "inserted": "wide",
        "history": "il2",
        "marker": "outside-narrow",
        "shifts": 1,
        "observer": "wrapped-wide",
        "wrap": True,
        "interposed": "none",
    }
    for key, choices in axes:
        for value in choices:
            settings = dict(base)
            settings[key] = value
            name = f"audit-irm-orphan-axis-{key}-{value}"
            yield _active_margin_irm_orphan_tail_case(name, **settings)  # type: ignore[arg-type]

    core_keys = ("cols", "geometry", "insert_phase", "tail", "inserted",
                 "history", "marker", "shifts")
    for core_values in itertools.product(
        *(values[key] for key in core_keys)
    ):
        settings = dict(base)
        settings.update(zip(core_keys, core_values))
        name = "audit-irm-orphan-core-" + "-".join(map(str, core_values))
        yield _active_margin_irm_orphan_tail_case(name, **settings)  # type: ignore[arg-type]

    observer_keys = ("cols", "observer", "wrap", "interposed")
    for observer_values in itertools.product(
        *(values[key] for key in observer_keys)
    ):
        settings = dict(base)
        settings.update(zip(observer_keys, observer_values))
        name = "audit-irm-orphan-observer-" + "-".join(
            map(str, observer_values))
        yield _active_margin_irm_orphan_tail_case(name, **settings)  # type: ignore[arg-type]


def active_margin_irm_orphan_tail_representative_cases() -> Iterator[Case]:
    """Freeze the third random-0291 residual and every predictor branch."""
    residual = _active_margin_irm_orphan_tail_case(
        "random-0291-irm-orphan-wide-tail-residual")
    yield residual

    positive_core = (
        ("active-left", "both", "wide-head", "wide", "outside-narrow", 2),
        ("active-left", "both", "wide-head", "wide", "inside-narrow", 2),
        ("active-left", "both", "wide-head", "wide", "none", 1),
        ("active-left", "both", "wide-head", "narrow", "none", 2),
        ("active-left", "both", "wide-head", "blank", "none", 2),
        ("active-left", "both", "continuation", "wide", "none", 2),
        ("active-left", "observer-only", "wide-head", "blank", "none", 2),
        ("active-internal", "both", "wide-head", "wide", "outside-narrow", 1),
        ("active-internal", "both", "wide-head", "wide", "outside-wide", 2),
        ("active-internal", "both", "wide-head", "wide", "inside-narrow", 2),
        ("active-internal", "both", "wide-head", "wide", "none", 1),
        ("active-internal", "both", "wide-head", "narrow", "outside-narrow", 2),
        ("active-internal", "both", "wide-head", "narrow", "none", 2),
        ("active-internal", "both", "wide-head", "blank", "outside-narrow", 2),
        ("active-internal", "both", "wide-head", "blank", "none", 2),
        ("active-internal", "both", "continuation", "wide", "outside-narrow", 2),
        ("active-internal", "both", "continuation", "wide", "none", 2),
        ("active-internal", "observer-only", "wide-head", "blank", "outside-narrow", 2),
        ("active-internal", "observer-only", "wide-head", "blank", "none", 2),
    )
    for index, (geometry, phase, tail, inserted, marker, shifts) in enumerate(
        positive_core
    ):
        if (geometry, phase, tail, inserted, marker, shifts) == (
            "active-internal", "both", "wide-head", "wide",
            "outside-narrow", 1,
        ):
            continue
        yield _active_margin_irm_orphan_tail_case(
            f"irm-orphan-core-positive-{index + 1}", geometry=geometry,
            insert_phase=phase, tail=tail, inserted=inserted,
            marker=marker, shifts=shifts)

    negative_axes: tuple[tuple[str, dict[str, object]], ...] = (
        ("default-geometry", {"geometry": "default"}),
        ("full-geometry", {"geometry": "active-full"}),
        ("physical-right", {"geometry": "active-right"}),
        ("hidden-geometry", {"geometry": "hidden-internal"}),
        ("seed-only-insert", {"insert_phase": "seed-only"}),
        ("insert-disabled", {"insert_phase": "off"}),
        ("narrow-tail", {"tail": "narrow"}),
        ("blank-tail", {"tail": "blank"}),
        ("no-seed-mutation", {"inserted": "none"}),
        ("unaligned-history", {"history": "none"}),
        ("alternate-source", {"marker": "outside-wide"}),
        ("no-shift", {"shifts": 0}),
        ("pending-only", {"observer": "pending-narrow"}),
        ("blank-insertion", {"observer": "direct-blank"}),
        ("nowrap", {"wrap": False}),
        ("blank-interposed", {"observer": "none",
                              "interposed": "blank-destination"}),
    )
    for label, settings in negative_axes:
        yield _active_margin_irm_orphan_tail_case(
            f"irm-orphan-negative-{label}", **settings)  # type: ignore[arg-type]

    yield _active_margin_irm_orphan_tail_case(
        "irm-orphan-positive-direct-print", observer="direct-narrow")
    yield _active_margin_irm_orphan_tail_case(
        "irm-orphan-positive-wrapped-print", observer="wrapped-narrow")
    yield _active_margin_irm_orphan_tail_case(
        "irm-orphan-positive-interposed-print", observer="none",
        interposed="narrow-destination")


_RANDOM322_CORE_TRANSITIONS = (
    (3, "bottom-minus1", "dl1", "wide", "narrow", "dl1"),
    (3, "bottom-minus1", "dl2", "wide", "narrow", "dl1"),
    (3, "bottom", "dl1", "narrow", "narrow", "dl2"),
    (3, "bottom", "dl1", "wide", "none", "dl2"),
    (3, "bottom", "dl1", "wide", "narrow", "dl2"),
    (3, "bottom", "dl2", "narrow", "narrow", "dl1"),
    (3, "bottom", "dl2", "narrow", "narrow", "dl2"),
    (3, "bottom", "dl2", "wide", "none", "dl1"),
    (3, "bottom", "dl2", "wide", "none", "dl2"),
    (3, "bottom", "dl2", "wide", "narrow", "dl1"),
    (3, "bottom", "dl2", "wide", "narrow", "dl2"),
    (4, "bottom-minus1", "dl1", "wide", "narrow", "dl2"),
    (4, "bottom-minus1", "dl2", "wide", "narrow", "dl1"),
    (4, "bottom-minus1", "dl2", "wide", "narrow", "dl2"),
    (4, "bottom", "dl1", "narrow", "narrow", "dl3"),
    (4, "bottom", "dl1", "wide", "none", "dl3"),
    (4, "bottom", "dl1", "wide", "narrow", "dl3"),
    (4, "bottom", "dl2", "narrow", "narrow", "dl2"),
    (4, "bottom", "dl2", "narrow", "narrow", "dl3"),
    (4, "bottom", "dl2", "wide", "none", "dl2"),
    (4, "bottom", "dl2", "wide", "none", "dl3"),
    (4, "bottom", "dl2", "wide", "narrow", "dl2"),
    (4, "bottom", "dl2", "wide", "narrow", "dl3"),
)

_RANDOM322_GEOMETRY_COUNTS = (
    (3, "dl1", "dl1"),
    (3, "dl2", "dl1"),
    (4, "dl1", "dl2"),
    (4, "dl2", "dl1"),
    (4, "dl2", "dl2"),
    (5, "dl1", "dl3"),
    (5, "dl2", "dl2"),
    (5, "dl2", "dl3"),
    (6, "dl2", "dl3"),
)


def _random322_dl_background_case(
    name: str, group: str, axes: dict[str, object],
) -> Case:
    """Build one deterministic DL-background history transition."""
    wide = "\u65e5".encode()
    background_name = str(axes["background"])
    backgrounds = {
        "default": (b"", b""),
        "indexed": (b"\x1b[48;5;22m", b""),
        "rgb": (b"\x1b[48:2::3:4m", b""),
        "rgb-reset": (b"\x1b[48:2::3:4m", b"\x1b[49m"),
    }
    background, reset = backgrounds[background_name]
    contents = {"none": b"", "narrow": b"A", "wide": wide}
    line_operations = {
        "none": b"", "dl1": b"\x1b[M", "dl2": b"\x1b[2M",
        "dl3": b"\x1b[3M", "il1": b"\x1b[L",
    }

    if group == "core":
        cols = 2
        rows = int(axes["rows"])
        geometry_name = str(axes["geometry"])
        geometries = {
            "default": (b"", b""),
            "mode-only": (b"\x1b[?69h", b""),
            "active-full": (b"\x1b[?69h", f"\x1b[1;{cols}s".encode()),
            "active-left": (b"\x1b[?69h", b"\x1b[1;1s"),
            "active-right": (
                b"\x1b[?69h", f"\x1b[{cols};{cols}s".encode()),
            "hidden-right": (
                b"\x1b[?69h",
                f"\x1b[{cols};{cols}s".encode() + b"\x1b[?69l"),
        }
        mode, margin = geometries[geometry_name]
        requested_row = {
            "top": 1,
            "bottom-minus1": max(1, rows - 1),
            "bottom": rows,
        }[str(axes["start"])]
        wrap = b"\x1b[?7h" if axes["wrap"] == "wrap" else b"\x1b[?7l"
        payload = b"".join((
            background, mode, f"\x1b[{requested_row};1H".encode(),
            contents[str(axes["seed"])], margin, wrap,
            line_operations[str(axes["first"])],
            contents[str(axes["middle"])], contents[str(axes["follower"])],
            reset, line_operations[str(axes["final"])],
        ))
    elif group == "geometry":
        cols = int(axes["cols"])
        rows = int(axes["rows"])
        left = int(axes["left"])
        right = int(axes["right"])
        wrap = b"\x1b[?7h" if axes["wrap"] == "wrap" else b"\x1b[?7l"
        payload = b"".join((
            background, b"\x1b[?69h", f"\x1b[{rows - 1};1H".encode(),
            contents[str(axes["seed"])], f"\x1b[{left};{right}s".encode(),
            wrap, line_operations[str(axes["first"])], wide, b"A", reset,
            line_operations[str(axes["final"])],
        ))
    else:
        raise AssertionError(group)
    return Case(name, cols, rows, payload, (len(payload),), None)


def active_margin_dl_background_history_matrix_cases() -> Iterator[Case]:
    """Bound the random-0322 erase-background history transition.

    The core product crosses background lifetime, active/hidden/default
    horizontal geometry, two screen heights and three cursor-row relations,
    empty/narrow/wide seed and wrap content, prior DL/IL history, follower
    presence, final DL count, and autowrap.  The geometry supplement crosses
    widths two through six, every horizontal margin, heights three through
    six, background reset, seed presence, both prior DL counts, three final
    counts, and wrap mode. Cardinality: 85,968.
    """
    core_axes: dict[str, tuple[object, ...]] = {
        "background": ("default", "indexed", "rgb", "rgb-reset"),
        "geometry": ("default", "mode-only", "active-full", "active-left",
                     "active-right", "hidden-right"),
        "rows": (3, 4),
        "start": ("top", "bottom-minus1", "bottom"),
        "seed": ("none", "narrow", "wide"),
        "first": ("none", "dl1", "dl2", "il1"),
        "middle": ("none", "narrow", "wide"),
        "follower": ("none", "narrow"),
        "final": ("dl1", "dl2", "dl3"),
        "wrap": ("wrap", "nowrap"),
    }
    core_keys = tuple(core_axes)
    for values in itertools.product(*(core_axes[key] for key in core_keys)):
        axes = dict(zip(core_keys, values))
        suffix = "-".join(map(str, values))
        yield _random322_dl_background_case(
            f"audit-random322-dl-background-core-{suffix}", "core", axes)

    for cols in range(2, 7):
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                geometry_axes: dict[str, tuple[object, ...]] = {
                    "rows": (3, 4, 5, 6),
                    "background": ("default", "rgb", "rgb-reset"),
                    "seed": ("none", "wide"),
                    "first": ("none", "dl1", "dl2"),
                    "final": ("dl1", "dl2", "dl3"),
                    "wrap": ("wrap", "nowrap"),
                }
                geometry_keys = tuple(geometry_axes)
                for values in itertools.product(
                    *(geometry_axes[key] for key in geometry_keys)
                ):
                    axes = dict(zip(geometry_keys, values))
                    axes.update({"cols": cols, "left": left, "right": right})
                    suffix = "-".join(map(str, (cols, left, right, *values)))
                    yield _random322_dl_background_case(
                        f"audit-random322-dl-background-geometry-{suffix}",
                        "geometry", axes)


def active_margin_dl_background_history_representative_cases() -> Iterator[Case]:
    """Freeze all 32 positive predictor leaves plus negative controls."""
    for index, (rows, start, first, middle, follower, final) in enumerate(
        _RANDOM322_CORE_TRANSITIONS
    ):
        axes: dict[str, object] = {
            "background": "rgb",
            "geometry": "active-right",
            "rows": rows,
            "start": start,
            "seed": "wide",
            "first": first,
            "middle": middle,
            "follower": follower,
            "final": final,
            "wrap": "wrap",
        }
        label = ("random-0322-dl-background-residual" if
                 (rows, start, first, middle, follower, final) ==
                 (4, "bottom-minus1", "dl2", "wide", "narrow", "dl2")
                 else f"random322-dl-background-core-leaf-{index + 1}")
        yield _random322_dl_background_case(label, "core", axes)

    for index, (rows, first, final) in enumerate(_RANDOM322_GEOMETRY_COUNTS):
        axes = {
            "cols": 3,
            "left": 2,
            "right": 3,
            "rows": rows,
            "background": "rgb",
            "seed": "wide",
            "first": first,
            "final": final,
            "wrap": "wrap",
        }
        yield _random322_dl_background_case(
            f"random322-dl-background-geometry-leaf-{index + 1}",
            "geometry", axes)

    negative_settings: tuple[tuple[str, dict[str, object]], ...] = (
        ("default-background", {"background": "default"}),
        ("hidden-margin", {"geometry": "hidden-right"}),
        ("full-margin", {"geometry": "active-full"}),
        ("empty-seed", {"seed": "none"}),
        ("no-prior-delete", {"first": "none"}),
        ("prior-insert", {"first": "il1"}),
        ("no-wrap-content", {"wrap": "nowrap"}),
        ("no-middle-content", {"middle": "none"}),
    )
    base_axes: dict[str, object] = {
        "background": "rgb",
        "geometry": "active-right",
        "rows": 4,
        "start": "bottom-minus1",
        "seed": "wide",
        "first": "dl2",
        "middle": "wide",
        "follower": "narrow",
        "final": "dl2",
        "wrap": "wrap",
    }
    for label, mutation in negative_settings:
        axes = dict(base_axes)
        axes.update(mutation)
        yield _random322_dl_background_case(
            f"random322-dl-background-negative-{label}", "core", axes)


def active_margin_dl_content_generation_discriminator_cases() -> Iterator[Case]:
    """Freeze content retention and whole-row invalidation for random 0322."""
    active_partial = b"".join((
        b"\x1b[48:2::3:4m", b"\x1b[?69h", b"\x1b[2;2s",
        b"\x1b[2;2HA", b"\x1b[2;2H", b"\x1b[2L", b"\x1b[49m",
        b"\x1b[3;2HBC", b"\x1b[2;2H", b"\x1b[2M",
    ))
    yield Case(
        "random322-active-partial-scroll-preserves-virtual-content-generation",
        2, 3, active_partial, (len(active_partial),), None)

    full_width = active_partial.replace(b"\x1b[2;2s", b"\x1b[1;2s", 1)
    yield Case(
        "random322-full-width-scroll-clears-virtual-content-generation",
        2, 3, full_width, (len(full_width),), None)


def variation_selector_lastwrite_matrix_cases() -> Iterator[Case]:
    """Audit VS15/VS16 against the preceding grapheme and cursor history.

    Axes: widths 1...4; heights 1...2 and every source row; nine narrow,
    wide, RI, symbol, and ZWJ lead classes; direct wrap/no-wrap, fitted-edge
    wrap/no-wrap, forced-wrap, and explicitly settled states; VS15 or VS16;
    and with or without an ordinary narrow follower.  Cardinality: 2,880.
    """
    leads = (
        ("ascii", b"A", 1),
        ("unicode", "\u00e9".encode(), 1),
        ("cjk", "\u65e5".encode(), 2),
        ("rocket", "\U0001f680".encode(), 2),
        ("grinning", "\U0001f600".encode(), 2),
        ("flag", "\U0001f1fa\U0001f1f8".encode(), 2),
        ("heart", "\u2764".encode(), 1),
        ("plane", "\u2708".encode(), 1),
        ("woman", "\U0001f469".encode(), 2),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode(), 2),
    )
    selectors = (("vs15", "\ufe0e".encode()),
                 ("vs16", "\ufe0f".encode()))
    for cols in range(1, 5):
        for rows in range(1, 3):
            for row in range(1, rows + 1):
                for lead_name, lead, width in leads:
                    edge = max(1, cols - width + 1)
                    direct = f"\x1b[{row};1H".encode() + lead
                    edge_setup = f"\x1b[{row};{edge}H".encode() + lead
                    states = (
                        ("direct-wrap", b"\x1b[?7h" + direct),
                        ("direct-nowrap", b"\x1b[?7l" + direct),
                        ("edge-wrap", b"\x1b[?7h" + edge_setup),
                        ("edge-nowrap", b"\x1b[?7l" + edge_setup),
                        ("wrapped", b"\x1b[?7h" +
                         f"\x1b[{row};{cols}H".encode() + b"X" + lead),
                        ("settled", b"\x1b[?7h" + direct +
                         f"\x1b[{row};1H".encode()),
                    )
                    for state_name, state_setup in states:
                        for selector_name, selector in selectors:
                            for suffix_name, suffix in (("none", b""),
                                                        ("narrow", b"Z")):
                                payload = state_setup + selector + suffix
                                name = (f"audit-vs-lastwrite-c{cols}-r{rows}-"
                                        f"y{row}-{lead_name}-{state_name}-"
                                        f"{selector_name}-{suffix_name}")
                                yield Case(name, cols, rows, payload,
                                           (len(payload),), None)


def post_zwj_wide_matrix_cases() -> Iterator[Case]:
    """Audit a wide printable after ZWJ on an ineligible narrow base.

    Axes: widths 1...4; default geometry and every active/hidden stored
    horizontal margin; every physical starting column; Mn or ZWJ as the first
    zero-width follower; woman, rocket, laptop, CJK, or RI flag as the wide
    printable; and Mn or ZWJ as the final follower.  DECAWM is disabled and
    the base is a narrow `0`.  Cardinality: 2,800.
    """
    wide_followers = (
        ("woman", "\U0001f469".encode()),
        ("rocket", "\U0001f680".encode()),
        ("laptop", "\U0001f4bb".encode()),
        ("cjk", "\u65e5".encode()),
        ("flag", "\U0001f1fa\U0001f1f8".encode()),
    )
    zero_width = (("mn", "\u0301".encode()),
                  ("zwj", "\u200d".encode()))
    for cols in range(1, 5):
        geometries = [("default", b"")]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                geometries.extend([
                    (f"active-{left}-{right}", stored),
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l"),
                ])
        for geometry_name, geometry_setup in geometries:
            for cursor_col in range(1, cols + 1):
                parked = (geometry_setup + b"\x1b[?7l" +
                          f"\x1b[1;{cursor_col}H".encode() + b"0")
                for first_name, first in zero_width:
                    for wide_name, wide in wide_followers:
                        for final_name, final in zero_width:
                            payload = parked + first + wide + final
                            name = (f"audit-post-zwj-wide-c{cols}-"
                                    f"{geometry_name}-x{cursor_col}-"
                                    f"{first_name}-{wide_name}-{final_name}")
                            yield Case(name, cols, 1, payload,
                                       (len(payload),), None)


def parked_wide_selector_owner_matrix_cases() -> Iterator[Case]:
    """Audit selector ownership after a parked wide follower is rejected.

    The family crosses widths 1...4; default geometry and every active/hidden
    stored horizontal margin; every physical starting column; wrap on/off;
    presentation-eligible, ineligible narrow, and fixed-wide bases; no join,
    Mn, or ZWJ; rejected wide and matching narrow/empty controls; and selector,
    combining, joiner, or printable observers. Cardinality: 189,000.
    """
    bases = (
        ("digit", b"0"),
        ("hash", b"#"),
        ("star", b"*"),
        ("copyright", "\u00a9".encode()),
        ("heart", "\u2764".encode()),
        ("plane", "\u2708".encode()),
        ("ascii", b"A"),
        ("unicode", "\u00e9".encode()),
        ("cjk", "\u65e5".encode()),
    )
    joins = (
        ("none", b""),
        ("mn", "\u0301".encode()),
        ("zwj", "\u200d".encode()),
    )
    followers = (
        ("none", b""),
        ("narrow", b"Z"),
        ("cjk", "\u65e5".encode()),
        ("rocket", "\U0001f680".encode()),
        ("laptop", "\U0001f4bb".encode()),
    )
    observers = (
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
        ("mn", "\u0301".encode()),
        ("zwj", "\u200d".encode()),
        ("narrow", b"X"),
    )
    for cols in range(1, 5):
        geometries: list[tuple[str, bytes]] = [("default", b"")]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                geometries.extend([
                    (f"active-{left}-{right}", stored),
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l"),
                ])
        for geometry_name, geometry_setup in geometries:
            for start_col in range(1, cols + 1):
                position = f"\x1b[1;{start_col}H".encode()
                for wrap_name, wrap_setup in (
                    ("wrap", b"\x1b[?7h"),
                    ("nowrap", b"\x1b[?7l"),
                ):
                    for base_name, base in bases:
                        for join_name, join in joins:
                            for follower_name, follower in followers:
                                for observer_name, observer in observers:
                                    payload = (geometry_setup + wrap_setup +
                                               position + base + join +
                                               follower + observer)
                                    name = (
                                        f"audit-parked-selector-c{cols}-"
                                        f"{geometry_name}-x{start_col}-"
                                        f"{wrap_name}-{base_name}-{join_name}-"
                                        f"{follower_name}-{observer_name}"
                                    )
                                    yield Case(name, cols, 2, payload,
                                               (len(payload),), None)


def c1_grapheme_owner_matrix_cases() -> Iterator[Case]:
    """Audit grapheme ownership across ignored raw C1 controls.

    This bounded grammar family uses widths 1, 2, and 4; representative
    default, active, and hidden margin geometries; edge and interior starts;
    wrap on/off; six base classes; all 32 C1 bytes; and selector, combining,
    joiner, or printable followers. Cardinality: 57,600.
    """
    bases = (
        ("digit", b"0"),
        ("copyright", "\u00a9".encode()),
        ("heart", "\u2764".encode()),
        ("ascii", b"A"),
        ("unicode", "\u00e9".encode()),
        ("cjk", "\u65e5".encode()),
    )
    followers = (
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
        ("mn", "\u0301".encode()),
        ("zwj", "\u200d".encode()),
        ("narrow", b"X"),
    )
    for cols in (1, 2, 4):
        profiles: list[tuple[str, bytes]] = [
            ("default", b""),
            ("active-full", b"\x1b[?69h" +
             f"\x1b[1;{cols}s".encode()),
        ]
        if cols >= 2:
            profiles.extend([
                ("active-left", b"\x1b[?69h" +
                 f"\x1b[1;{cols - 1}s".encode()),
                ("active-right", b"\x1b[?69h" +
                 f"\x1b[2;{cols}s".encode()),
                ("hidden-left", b"\x1b[?69h" +
                 f"\x1b[1;{cols - 1}s".encode() + b"\x1b[?69l"),
            ])
        if cols >= 4:
            profiles.append(
                ("active-internal", b"\x1b[?69h" +
                 f"\x1b[2;{cols - 1}s".encode()))
        starts = sorted({1, cols, max(1, (cols + 1) // 2)})
        for geometry_name, geometry_setup in profiles:
            for start_col in starts:
                position = f"\x1b[1;{start_col}H".encode()
                for wrap_name, wrap_setup in (
                    ("wrap", b"\x1b[?7h"),
                    ("nowrap", b"\x1b[?7l"),
                ):
                    for base_name, base in bases:
                        for c1 in range(0x80, 0xA0):
                            for follower_name, follower in followers:
                                payload = (geometry_setup + wrap_setup +
                                           position + base + bytes((c1,)) +
                                           follower)
                                name = (
                                    f"audit-c1-owner-c{cols}-{geometry_name}-"
                                    f"x{start_col}-{wrap_name}-{base_name}-"
                                    f"c1{c1:02x}-{follower_name}"
                                )
                                yield Case(name, cols, 2, payload,
                                           (len(payload),), None)


def random439_grapheme_owner_representative_cases() -> Iterator[Case]:
    """Freeze both minimized random-0439 ownership polarities and controls."""
    nowrap = b"\x1b[?7l"
    zwj = "\u200d".encode()
    cjk = "\u65e5".encode()
    laptop = "\U0001f4bb".encode()
    woman_laptop = "\U0001f469\u200d\U0001f4bb".encode()
    vs15 = "\ufe0e".encode()
    vs16 = "\ufe0f".encode()
    mn = "\u0301".encode()
    parked_cases = (
        ("random-0439-parked-wide-selector", nowrap + b"0" +
         woman_laptop + vs16, 1),
        ("random-0439-parked-zwj-cjk-vs16", nowrap + b"0" + zwj +
         cjk + vs16, 1),
        ("random-0439-parked-zwj-cjk-vs15", nowrap + b"0" + zwj +
         cjk + vs15, 1),
        ("random-0439-wrap-control", b"\x1b[?7h0" + zwj + cjk + vs16, 1),
        ("random-0439-no-join-control", nowrap + b"0" + cjk + vs16, 1),
        ("random-0439-narrow-follower-control", nowrap + b"0" + zwj +
         b"Z" + vs16, 1),
        ("random-0439-mn-observer-control", nowrap + b"0" + zwj +
         cjk + mn, 1),
        ("random-0439-ascii-owner-control", nowrap + b"A" + zwj +
         cjk + vs16, 1),
        ("random-0439-interior-control", nowrap + b"0" + zwj +
         cjk + vs16, 2),
    )
    for name, payload, cols in parked_cases:
        yield Case(name, cols, 2, payload, (len(payload),), None)

    active = (b"\x1b[?69h\x1b[2;2s\x1b[?7l\x1b[1;2H" +
              b"0" + zwj + cjk + vs16)
    yield Case("random-0439-active-edge", 3, 2, active,
               (len(active),), None)
    hidden = (b"\x1b[?69h\x1b[2;2s\x1b[?69l\x1b[?7l\x1b[1;2H" +
              b"0" + zwj + cjk + vs16)
    yield Case("random-0439-hidden-margin-control", 3, 2, hidden,
               (len(hidden),), None)

    c1_cases = (
        ("random-0439-c1-vs16", "\u00a9".encode() + b"\x92" + vs16),
        ("random-0439-c1-mn", b"A\x80" + mn),
        ("random-0439-c1-zwj", "\u2764".encode() + b"\x9c" + zwj),
        ("random-0439-c1-vs15", b"0\x8f" + vs15),
        ("random-0439-c1-narrow-control", b"0\x92X"),
        ("random-0439-no-c1-control", "\u00a9".encode() + vs16),
    )
    for name, payload in c1_cases:
        yield Case(name, 4, 2, payload, (len(payload),), None)


def _semantic_kitty_resize_block_case(
    name: str,
    *,
    cols: int = 6,
    rows: int = 4,
    origin: str = "on",
    first_motion: str = "cht2",
    seed: str = "wide",
    vregion: str = "top2",
    second_motion: str = "ht",
    premarker: str = "combining",
    marker: str = "A",
    geometry: str = "active-right",
    post: str = "unicode",
    line_motion: str = "lf",
    kitty: str = "display-id",
    wrap: str = "wrap",
    resize: str = "one",
) -> Case:
    """Build one semantic-block/graphics hidden-row resize transition."""
    wide = "\u65e5".encode()
    combining = "A\u0301".encode()
    parts: list[bytes] = [
        b"\x1b[?7h" if wrap == "wrap" else b"\x1b[?7l",
        b"\x1b[?6h" if origin == "on" else b"\x1b[?6l",
    ]
    first_motions = {
        "cht1": b"\x1b[I",
        "cht2": b"\x1b[2I",
        "none": b"",
    }
    seeds = {
        "wide": wide,
        "narrow": b"A",
        "combining": combining,
        "none": b"",
    }
    parts.extend((first_motions[first_motion], seeds[seed]))

    vertical_regions = {
        "top2": f"\x1b[2;{rows + 1}r".encode(),
        "full": f"\x1b[1;{rows}r".encode(),
        "internal": f"\x1b[2;{max(2, rows - 1)}r".encode(),
    }
    second_motions = {
        "ht": b"\t",
        "space": b" ",
        "cr": b"\r",
        "none": b"",
    }
    contents = {
        "combining": combining,
        "narrow": b"A",
        "wide": wide,
        "none": b"",
    }
    markers = {
        "A": b"\x1b]133;A\x07",
        "B": b"\x1b]133;B\x07",
        "C": b"\x1b]133;C\x07",
        "D": b"\x1b]133;D;0\x07",
        "none": b"",
    }
    parts.extend((vertical_regions[vregion], second_motions[second_motion],
                  contents[premarker], markers[marker]))

    geometries = {
        "default": b"",
        "active-full": (b"\x1b[?69h" + f"\x1b[1;{cols}s".encode()),
        "active-left": (b"\x1b[?69h" +
                        f"\x1b[1;{max(1, cols - 1)}s".encode()),
        "active-right": (b"\x1b[?69h" + f"\x1b[2;{cols}s".encode()),
        "active-internal": (b"\x1b[?69h" +
                            f"\x1b[2;{max(2, cols - 1)}s".encode()),
        "hidden-internal": (b"\x1b[?69h" +
                            f"\x1b[2;{max(2, cols - 1)}s".encode() +
                            b"\x1b[?69l"),
    }
    posts = {
        "unicode": "\u00e9".encode(),
        "narrow": b"A",
        "wide": wide,
        "none": b"",
    }
    line_motions = {
        "lf": b"\n",
        "ind": b"\x1bD",
        "crlf": b"\r\n",
        "none": b"",
    }
    kitty_values = {
        "display-id":
            b"\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\x1b\\",
        "display-no-id":
            b"\x1b_Ga=T,f=32,s=1,v=1,q=2;/wAA/w==\x1b\\",
        "transmit":
            b"\x1b_Ga=t,f=32,s=1,v=1,i=3,q=2;/wAA/w==\x1b\\",
        "none": b"",
    }
    parts.extend((geometries[geometry], posts[post],
                  line_motions[line_motion], kitty_values[kitty]))
    payload = b"".join(parts)
    resize_values: dict[str, tuple[int, int] | None] = {
        "one": (1, 1),
        "width-one": (1, rows),
        "height-one": (cols, 1),
        "shrink": (max(1, cols - 2), max(1, rows - 1)),
        "same": (cols, rows),
        "grow": (cols + 2, rows + 2),
        "none": None,
    }
    return Case(name, cols, rows, payload, (len(payload),),
                resize_values[resize])


def semantic_kitty_resize_block_settings() -> Iterator[dict[str, object]]:
    """Yield the de-duplicated bounded axes for random-0448."""
    axes: dict[str, tuple[object, ...]] = {
        "cols": (4, 5, 6, 8),
        "rows": (3, 4, 5, 6),
        "origin": ("on", "off"),
        "first_motion": ("cht1", "cht2", "none"),
        "seed": ("wide", "narrow", "combining", "none"),
        "vregion": ("top2", "full", "internal"),
        "second_motion": ("ht", "space", "cr", "none"),
        "premarker": ("combining", "narrow", "wide", "none"),
        "marker": ("A", "B", "C", "D", "none"),
        "geometry": ("default", "active-full", "active-left",
                     "active-right", "active-internal", "hidden-internal"),
        "post": ("unicode", "narrow", "wide", "none"),
        "line_motion": ("lf", "ind", "crlf", "none"),
        "kitty": ("display-id", "display-no-id", "transmit", "none"),
        "wrap": ("wrap", "nowrap"),
        "resize": ("one", "width-one", "height-one", "shrink",
                   "same", "grow", "none"),
    }
    base: dict[str, object] = {
        "cols": 6, "rows": 4, "origin": "on",
        "first_motion": "cht2", "seed": "wide", "vregion": "top2",
        "second_motion": "ht", "premarker": "combining", "marker": "A",
        "geometry": "active-right", "post": "unicode",
        "line_motion": "lf", "kitty": "display-id", "wrap": "wrap",
        "resize": "one",
    }
    seen: set[tuple[object, ...]] = set()

    def emit(settings: dict[str, object]) -> Iterator[dict[str, object]]:
        key = tuple(settings[name] for name in base)
        if key not in seen:
            seen.add(key)
            yield settings

    for key, choices in axes.items():
        for value in choices:
            settings = dict(base)
            settings[key] = value
            yield from emit(settings)

    geometry_keys = ("cols", "rows", "origin", "vregion", "geometry",
                     "wrap", "resize")
    for values in itertools.product(*(axes[key] for key in geometry_keys)):
        settings = dict(base)
        settings.update(zip(geometry_keys, values))
        yield from emit(settings)

    state_keys = ("first_motion", "seed", "second_motion", "premarker",
                  "post", "line_motion", "kitty", "wrap", "resize")
    state_values = {
        **axes,
        "kitty": ("display-id", "transmit", "none"),
        "resize": ("one", "width-one", "same", "grow", "none"),
    }
    for values in itertools.product(*(state_values[key] for key in state_keys)):
        settings = dict(base)
        settings.update(zip(state_keys, values))
        yield from emit(settings)

    marker_keys = ("marker", "geometry", "line_motion", "kitty", "resize")
    for values in itertools.product(*(axes[key] for key in marker_keys)):
        settings = dict(base)
        settings.update(zip(marker_keys, values))
        yield from emit(settings)


def semantic_kitty_resize_block_matrix_cases() -> Iterator[Case]:
    """Bound hidden row topology, semantic anchors, graphics, and resize."""
    for index, settings in enumerate(semantic_kitty_resize_block_settings()):
        name = f"audit-semantic-kitty-resize-{index:06d}"
        yield _semantic_kitty_resize_block_case(name, **settings)  # type: ignore[arg-type]


def semantic_kitty_resize_block_representative_cases() -> Iterator[Case]:
    """Freeze the random-0448 minimum and one control per state branch."""
    controls: tuple[tuple[str, dict[str, object]], ...] = (
        ("random-0448-semantic-kitty-resize", {}),
        ("random-0448-no-resize", {"resize": "none"}),
        ("random-0448-same-resize", {"resize": "same"}),
        ("random-0448-width-only-resize", {"resize": "width-one"}),
        ("random-0448-height-only-resize", {"resize": "height-one"}),
        ("random-0448-grow-resize", {"resize": "grow"}),
        ("random-0448-origin-off", {"origin": "off"}),
        ("random-0448-full-region", {"vregion": "full"}),
        ("random-0448-no-first-motion", {"first_motion": "none"}),
        ("random-0448-narrow-seed", {"seed": "narrow"}),
        ("random-0448-no-second-motion", {"second_motion": "none"}),
        ("random-0448-no-premark-content", {"premarker": "none"}),
        ("random-0448-nonstart-marker", {"marker": "B"}),
        ("random-0448-default-geometry", {"geometry": "default"}),
        ("random-0448-active-full", {"geometry": "active-full"}),
        ("random-0448-hidden-geometry", {"geometry": "hidden-internal"}),
        ("random-0448-no-post-content", {"post": "none"}),
        ("random-0448-no-line-motion", {"line_motion": "none"}),
        ("random-0448-transmit-only", {"kitty": "transmit"}),
        ("random-0448-display-no-id", {"kitty": "display-no-id"}),
        ("random-0448-nowrap", {"wrap": "nowrap"}),
    )
    for name, settings in controls:
        yield _semantic_kitty_resize_block_case(name, **settings)  # type: ignore[arg-type]


def _decfi_grapheme_owner_case(
    name: str,
    *,
    cols: int = 7,
    rows: int = 1,
    row_position: str = "top",
    geometry: str = "default",
    wrap: str = "nowrap",
    seed: str = "cjk",
    backmove: str = "decbi",
    precontent: str = "combining",
    forward: str = "cht2",
    shift: str = "decfi",
    follower: str = "emoji-zwj-emoji",
) -> Case:
    """Build one DECFI row-shift/grapheme-owner transition."""
    row = (1 if row_position == "top" else rows if row_position == "bottom"
           else (rows + 1) // 2)
    if geometry in ("default", "active-full", "hidden-internal"):
        left, right = 1, cols
    elif geometry == "active-left":
        left, right = 1, max(1, cols - 1)
    elif geometry == "active-right":
        left, right = min(2, cols), cols
    else:
        left, right = min(2, cols), max(min(2, cols), cols - 1)
    geometries = {
        "default": b"",
        "active-full": b"\x1b[?69h" + f"\x1b[1;{cols}s".encode(),
        "active-left": b"\x1b[?69h" + f"\x1b[1;{right}s".encode(),
        "active-right": b"\x1b[?69h" + f"\x1b[{left};{cols}s".encode(),
        "active-internal": b"\x1b[?69h" + f"\x1b[{left};{right}s".encode(),
        "hidden-internal": (
            b"\x1b[?69h" + f"\x1b[2;{max(2, cols - 1)}s".encode()
            + b"\x1b[?69l"
        ),
    }
    contents = {
        "cjk": "\u65e5".encode(),
        "emoji": "\U0001f469".encode(),
        "heart-vs16": "\u2764\ufe0f".encode(),
        "narrow": b"A",
        "combining": "A\u0301".encode(),
        "none": b"",
    }
    precontents = {
        "combining": "A\u0301".encode(),
        "narrow": b"A",
        "space": b" ",
        "wide": "\u65e5".encode(),
        "none": b"",
    }
    followers = {
        "emoji-zwj-emoji": "\U0001f469\u200d\U0001f4bb".encode(),
        "emoji-zwj-cjk": "\U0001f469\u200d\u65e5".encode(),
        "cjk-zwj-emoji": "\u65e5\u200d\U0001f469".encode(),
        "plain-emoji": "\U0001f469".encode(),
        "plain-cjk": "\u65e5".encode(),
        "zwj": "\u200d".encode(),
        "combining": "\u0301".encode(),
        "vs16": "\ufe0f".encode(),
        "narrow": b"Z",
    }
    start = max(left, right - 1)
    back_target = max(left, start - 1)
    backmoves = {
        "decbi": b"\x1b6",
        "cub1": b"\x1b[D",
        "bs": b"\b",
        "cup-left": f"\x1b[{row};{back_target}H".encode(),
        "none": b"",
    }
    forwards = {
        "cht2": b"\x1b[2I",
        "cht1": b"\x1b[I",
        "ht": b"\t",
        "cup-right": f"\x1b[{row};{right}H".encode(),
        "cuf-max": b"\x1b[99C",
        "none": b"",
    }
    shifts = {
        "decfi": b"\x1b9",
        "dch1": b"\x1b[P",
        "cuf1": b"\x1b[C",
        "none": b"",
    }
    payload = b"".join((
        b"\x1b[?7l" if wrap == "nowrap" else b"\x1b[?7h",
        geometries[geometry],
        f"\x1b[{row};{start}H".encode(), contents[seed],
        f"\x1b[{row};{start}H".encode(), backmoves[backmove],
        precontents[precontent], forwards[forward], shifts[shift],
        followers[follower],
    ))
    return Case(name, cols, rows, payload, (len(payload),), None)


def decfi_grapheme_owner_settings() -> Iterator[dict[str, object]]:
    """Yield the de-duplicated bounded axes for random-0457."""
    base: dict[str, object] = {
        "cols": 7, "rows": 1, "row_position": "top",
        "geometry": "default", "wrap": "nowrap", "seed": "cjk",
        "backmove": "decbi", "precontent": "combining",
        "forward": "cht2", "shift": "decfi",
        "follower": "emoji-zwj-emoji",
    }
    axes: dict[str, tuple[object, ...]] = {
        "cols": (3, 4, 5, 6, 7, 8, 9),
        "rows": (1, 2, 4, 6),
        "row_position": ("top", "middle", "bottom"),
        "geometry": ("default", "active-full", "active-left",
                     "active-right", "active-internal", "hidden-internal"),
        "wrap": ("nowrap", "wrap"),
        "seed": ("cjk", "emoji", "heart-vs16", "narrow", "combining", "none"),
        "backmove": ("decbi", "cub1", "bs", "cup-left", "none"),
        "precontent": ("combining", "narrow", "space", "wide", "none"),
        "forward": ("cht2", "cht1", "ht", "cup-right", "cuf-max", "none"),
        "shift": ("decfi", "dch1", "cuf1", "none"),
        "follower": ("emoji-zwj-emoji", "emoji-zwj-cjk",
                     "cjk-zwj-emoji", "plain-emoji", "plain-cjk", "zwj",
                     "combining", "vs16", "narrow"),
    }
    seen: set[tuple[object, ...]] = set()

    def emit(settings: dict[str, object]) -> Iterator[dict[str, object]]:
        key = tuple(settings[name] for name in base)
        if key not in seen:
            seen.add(key)
            yield settings

    for key, choices in axes.items():
        for value in choices:
            settings = dict(base)
            settings[key] = value
            yield from emit(settings)

    topology_keys = ("cols", "geometry", "wrap", "seed", "precontent",
                     "follower")
    for values in itertools.product(*(axes[key] for key in topology_keys)):
        settings = dict(base)
        settings.update(zip(topology_keys, values))
        yield from emit(settings)

    motion_values: dict[str, tuple[object, ...]] = {
        "cols": (5, 7, 9),
        "geometry": ("default", "active-left", "active-right",
                     "active-internal"),
        "wrap": axes["wrap"],
        "backmove": axes["backmove"],
        "precontent": axes["precontent"],
        "forward": axes["forward"],
        "shift": axes["shift"],
        "follower": axes["follower"],
    }
    motion_keys = tuple(motion_values)
    for values in itertools.product(*(motion_values[key] for key in motion_keys)):
        settings = dict(base)
        settings.update(zip(motion_keys, values))
        yield from emit(settings)

    row_values: dict[str, tuple[object, ...]] = {
        "cols": (5, 7), "rows": axes["rows"],
        "row_position": axes["row_position"],
        "geometry": ("default", "active-right", "active-internal"),
    }
    row_keys = tuple(row_values)
    for values in itertools.product(*(row_values[key] for key in row_keys)):
        settings = dict(base)
        settings.update(zip(row_keys, values))
        yield from emit(settings)


def decfi_grapheme_owner_matrix_cases() -> Iterator[Case]:
    """Bound grapheme ownership after a DECFI row-slice shift."""
    for index, settings in enumerate(decfi_grapheme_owner_settings()):
        yield _decfi_grapheme_owner_case(
            f"audit-decfi-grapheme-owner-{index:06d}",
            **settings,  # type: ignore[arg-type]
        )


def decfi_grapheme_owner_representative_cases() -> Iterator[Case]:
    """Freeze the random-0457 witness and the principal branch controls."""
    controls: tuple[tuple[str, dict[str, object]], ...] = (
        ("random-0457-decfi-grapheme-owner", {}),
        ("random-0457-wrap-control", {"wrap": "wrap"}),
        ("random-0457-active-full", {"geometry": "active-full"}),
        ("random-0457-active-left", {"geometry": "active-left"}),
        ("random-0457-active-right", {"geometry": "active-right"}),
        ("random-0457-active-internal", {"geometry": "active-internal"}),
        ("random-0457-hidden-control", {"geometry": "hidden-internal"}),
        ("random-0457-no-shift-control", {"shift": "none"}),
        ("random-0457-dch-control", {"shift": "dch1"}),
        ("random-0457-no-backmove-control", {"backmove": "none"}),
        ("random-0457-cub-backmove", {"backmove": "cub1"}),
        ("random-0457-no-forward-control", {"forward": "none"}),
        ("random-0457-absolute-forward", {"forward": "cup-right"}),
        ("random-0457-no-seed-control", {"seed": "none"}),
        ("random-0457-narrow-seed", {"seed": "narrow"}),
        ("random-0457-plain-wide-follower-control", {"follower": "plain-emoji"}),
        ("random-0457-narrow-follower-control", {"follower": "narrow"}),
        ("random-0457-joiner-follower", {"follower": "zwj"}),
        ("random-0457-combining-follower", {"follower": "combining"}),
        ("random-0457-wide-precontent-control", {"precontent": "wide"}),
        ("random-0457-no-precontent-control", {"precontent": "none"}),
        ("random-0457-middle-row", {"rows": 4, "row_position": "middle"}),
        ("random-0457-bottom-row", {"rows": 4, "row_position": "bottom"}),
        ("random-0457-width-three", {"cols": 3}),
    )
    for name, settings in controls:
        yield _decfi_grapheme_owner_case(
            name, **settings,  # type: ignore[arg-type]
        )


def _dl_grapheme_owner_case(
    name: str,
    *,
    cols: int = 8,
    rows: int = 3,
    region: str = "default",
    delete_at: str = "top",
    delete_count: int = 2,
    source_relation: str = "mapped",
    geometry: str = "default",
    wrap: str = "wrap",
    source: str = "rocket",
    destination: str = "flag",
    owner_position: str = "right",
    destination_path: str = "direct",
    line_op: str = "dl",
    follower: str = "zwj",
) -> Case:
    """Build one delete-line/grapheme-owner replacement transition."""
    if region in ("default", "full"):
        top, bottom = 1, rows
    elif region == "top-inset":
        top, bottom = 2, rows
    elif region == "bottom-inset":
        top, bottom = 1, rows - 1
    else:
        top, bottom = 2, rows - 1
        if top >= bottom:
            top, bottom = 1, rows
    region_bytes = b"" if region == "default" else f"\x1b[{top};{bottom}r".encode()
    delete_row = (top if delete_at == "top" else bottom if delete_at == "bottom"
                  else (top + bottom) // 2)
    if source_relation == "mapped":
        source_row = delete_row + delete_count
    elif source_relation == "current":
        source_row = delete_row
    elif source_relation == "next":
        source_row = delete_row + 1
    else:
        source_row = bottom
    source_row = max(1, min(rows, source_row))

    if geometry in ("default", "active-full", "hidden-internal"):
        left, right = 1, cols
    elif geometry == "active-left":
        left, right = 1, max(1, cols - 1)
    elif geometry == "active-right":
        left, right = min(2, cols), cols
    else:
        left, right = min(2, cols), max(min(2, cols), cols - 1)
    geometries = {
        "default": b"",
        "active-full": b"\x1b[?69h" + f"\x1b[1;{cols}s".encode(),
        "active-left": b"\x1b[?69h" + f"\x1b[1;{right}s".encode(),
        "active-right": b"\x1b[?69h" + f"\x1b[{left};{cols}s".encode(),
        "active-internal": b"\x1b[?69h" + f"\x1b[{left};{right}s".encode(),
        "hidden-internal": (
            b"\x1b[?69h" + f"\x1b[2;{max(2, cols - 1)}s".encode()
            + b"\x1b[?69l"
        ),
    }
    shapes = {
        "rocket": "\U0001f680".encode(),
        "cjk": "\u65e5".encode(),
        "flag": "\U0001f1fa\U0001f1f8".encode(),
        "heart-vs16": "\u2764\ufe0f".encode(),
        "narrow-a": b"A",
        "narrow-z": b"Z",
        "combining-a": "A\u0301".encode(),
        "space": b" ",
        "none": b"",
    }
    if owner_position == "right":
        owner_col = max(left, right - 1)
    elif owner_position == "left":
        owner_col = left
    else:
        owner_col = max(left, min(right - 1, (left + right) // 2))
    source_content = shapes[source]
    destination_content = shapes[destination]
    if destination_path == "direct":
        destination_setup = (
            f"\x1b[{delete_row};{owner_col}H".encode() + destination_content
        )
    elif destination_path == "prefix":
        destination_setup = (
            f"\x1b[{delete_row};{left}H".encode()
            + b"A" * max(0, owner_col - left) + destination_content
        )
    elif destination_path == "reposition":
        destination_setup = (
            f"\x1b[{delete_row};{owner_col}H".encode() + destination_content
            + f"\x1b[{delete_row};{right}H".encode()
        )
    else:
        destination_setup = f"\x1b[{delete_row};{right}H".encode()
    line_ops = {
        "dl": f"\x1b[{delete_count}M".encode(),
        "il": f"\x1b[{delete_count}L".encode(),
        "dch": f"\x1b[{delete_count}P".encode(),
        "none": b"",
    }
    followers = {
        "zwj": "\u200d".encode(),
        "combining": "\u0301".encode(),
        "vs15": "\ufe0e".encode(),
        "vs16": "\ufe0f".encode(),
        "emoji-zwj-emoji": "\U0001f469\u200d\U0001f4bb".encode(),
        "narrow": b"Q",
    }
    payload = b"".join((
        b"\x1b[?7h" if wrap == "wrap" else b"\x1b[?7l",
        geometries[geometry], region_bytes,
        f"\x1b[{source_row};{owner_col}H".encode(), source_content,
        destination_setup, line_ops[line_op], followers[follower],
    ))
    return Case(name, cols, rows, payload, (len(payload),), None)


def dl_grapheme_owner_settings() -> Iterator[dict[str, object]]:
    """Yield the de-duplicated bounded axes for random-0571."""
    base: dict[str, object] = {
        "cols": 8, "rows": 3, "region": "default", "delete_at": "top",
        "delete_count": 2, "source_relation": "mapped",
        "geometry": "default", "wrap": "wrap", "source": "rocket",
        "destination": "flag", "owner_position": "right",
        "destination_path": "direct", "line_op": "dl", "follower": "zwj",
    }
    axes: dict[str, tuple[object, ...]] = {
        "cols": (4, 6, 8, 10), "rows": (3, 4, 5, 6),
        "region": ("default", "full", "top-inset", "bottom-inset", "internal"),
        "delete_at": ("top", "middle", "bottom"),
        "delete_count": (1, 2, 3),
        "source_relation": ("mapped", "current", "next", "bottom"),
        "geometry": ("default", "active-full", "active-left", "active-right",
                     "active-internal", "hidden-internal"),
        "wrap": ("wrap", "nowrap"),
        "source": ("rocket", "cjk", "flag", "heart-vs16", "narrow-a",
                   "combining-a", "space", "none"),
        "destination": ("rocket", "cjk", "flag", "heart-vs16", "narrow-a",
                        "narrow-z", "combining-a", "space", "none"),
        "owner_position": ("right", "middle", "left"),
        "destination_path": ("direct", "prefix", "reposition", "none"),
        "line_op": ("dl", "il", "dch", "none"),
        "follower": ("zwj", "combining", "vs15", "vs16",
                     "emoji-zwj-emoji", "narrow"),
    }
    seen: set[tuple[object, ...]] = set()

    def emit(settings: dict[str, object]) -> Iterator[dict[str, object]]:
        key = tuple(settings[name] for name in base)
        if key not in seen:
            seen.add(key)
            yield settings

    for key, choices in axes.items():
        for value in choices:
            settings = dict(base)
            settings[key] = value
            yield from emit(settings)

    identity_keys = ("cols", "geometry", "wrap", "source", "destination",
                     "owner_position", "follower")
    for values in itertools.product(*(axes[key] for key in identity_keys)):
        settings = dict(base)
        settings.update(zip(identity_keys, values))
        yield from emit(settings)

    path_values: dict[str, tuple[object, ...]] = {
        "cols": (6, 8, 10),
        "geometry": ("default", "active-left", "active-right", "active-internal"),
        "wrap": axes["wrap"], "source": axes["source"],
        "destination": axes["destination"],
        "destination_path": axes["destination_path"],
        "follower": axes["follower"],
    }
    path_keys = tuple(path_values)
    for values in itertools.product(*(path_values[key] for key in path_keys)):
        settings = dict(base)
        settings.update(zip(path_keys, values))
        yield from emit(settings)

    motion_values: dict[str, tuple[object, ...]] = {
        "rows": axes["rows"], "region": axes["region"],
        "delete_at": axes["delete_at"], "delete_count": axes["delete_count"],
        "source_relation": axes["source_relation"], "line_op": axes["line_op"],
        "geometry": ("default", "active-internal", "hidden-internal"),
    }
    motion_keys = tuple(motion_values)
    for values in itertools.product(*(motion_values[key] for key in motion_keys)):
        settings = dict(base)
        settings.update(zip(motion_keys, values))
        yield from emit(settings)


def dl_grapheme_owner_matrix_cases() -> Iterator[Case]:
    """Bound grapheme ownership when DL replaces a destination row or slice."""
    for index, settings in enumerate(dl_grapheme_owner_settings()):
        yield _dl_grapheme_owner_case(
            f"audit-dl-grapheme-owner-{index:06d}",
            **settings,  # type: ignore[arg-type]
        )


def dl_grapheme_owner_representative_cases() -> Iterator[Case]:
    """Freeze the random-0571 witness and principal identity controls."""
    controls: tuple[tuple[str, dict[str, object]], ...] = (
        ("random-0571-dl-grapheme-owner", {}),
        ("random-0571-nowrap", {"wrap": "nowrap"}),
        ("random-0571-same-owner-control", {"destination": "rocket"}),
        ("random-0571-different-wide-owner", {"destination": "cjk"}),
        ("random-0571-no-destination-owner", {"destination": "none"}),
        ("random-0571-no-source-owner", {"source": "none"}),
        ("random-0571-source-cjk", {"source": "cjk"}),
        ("random-0571-base-scalar-equivalence-a",
         {"source": "narrow-a", "destination": "combining-a"}),
        ("random-0571-base-scalar-equivalence-b",
         {"source": "combining-a", "destination": "narrow-a"}),
        ("random-0571-different-narrow-owner", {"destination": "narrow-z"}),
        ("random-0571-active-full", {"geometry": "active-full"}),
        ("random-0571-active-left-control", {"geometry": "active-left"}),
        ("random-0571-active-right", {"geometry": "active-right"}),
        ("random-0571-active-internal-control", {"geometry": "active-internal"}),
        ("random-0571-hidden-geometry", {"geometry": "hidden-internal"}),
        ("random-0571-left-owner-position", {"owner_position": "left"}),
        ("random-0571-middle-owner-position", {"owner_position": "middle"}),
        ("random-0571-prefix-destination", {"destination_path": "prefix"}),
        ("random-0571-repositioned-destination", {"destination_path": "reposition"}),
        ("random-0571-no-destination-path", {"destination_path": "none"}),
        ("random-0571-il-control", {"line_op": "il"}),
        ("random-0571-dch-control", {"line_op": "dch"}),
        ("random-0571-no-line-op-control", {"line_op": "none"}),
        ("random-0571-current-source-control", {"source_relation": "current"}),
        ("random-0571-next-source-control", {"source_relation": "next"}),
        ("random-0571-bottom-source", {"source_relation": "bottom"}),
        ("random-0571-delete-at-bottom-control", {"delete_at": "bottom"}),
        ("random-0571-delete-count-one", {"delete_count": 1}),
        ("random-0571-delete-count-three-control", {"delete_count": 3}),
        ("random-0571-delete-count-three-mapped", {"rows": 4, "delete_count": 3}),
        ("random-0571-internal-region", {"rows": 5, "region": "internal"}),
        ("random-0571-combining-follower", {"follower": "combining"}),
        ("random-0571-cluster-follower-control", {"follower": "emoji-zwj-emoji"}),
        ("random-0571-selector-control", {"follower": "vs16"}),
        ("random-0571-narrow-follower-control", {"follower": "narrow"}),
    )
    for name, settings in controls:
        yield _dl_grapheme_owner_case(
            name, **settings,  # type: ignore[arg-type]
        )


def post_zwj_cluster_boundary_matrix_cases() -> Iterator[Case]:
    """Bound emoji joining after complete and ineligible grapheme clusters.

    Axes: widths 1...4; default geometry plus every active and hidden stored
    horizontal-margin pair; every physical starting column; DECAWM on/off;
    seven narrow, wide, emoji, ZWJ, RI, flag, and keycap lead classes; no ZWJ,
    one ZWJ, or two ZWJs; and eight narrow, wide, presentation-selected emoji,
    RI, and ZWJ-sequence followers.  Height is two and the start row is one so
    right-edge cases can wrap without immediately scrolling.  Cardinality:
    47,040.
    """
    bases = (
        ("ascii", b"A"),
        ("cjk", "\u65e5".encode()),
        ("woman", "\U0001f469".encode()),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode()),
        ("ri-single", "\U0001f1fa".encode()),
        ("ri-flag", "\U0001f1fa\U0001f1f8".encode()),
        ("keycap", "1\ufe0f\u20e3".encode()),
    )
    joins = (
        ("none", b""),
        ("zwj", "\u200d".encode()),
        ("zwj-zwj", "\u200d\u200d".encode()),
    )
    followers = (
        ("ascii", b"Z"),
        ("cjk", "\u65e5".encode()),
        ("heart", "\u2764".encode()),
        ("heart-vs15", "\u2764\ufe0e".encode()),
        ("heart-vs16", "\u2764\ufe0f".encode()),
        ("rocket", "\U0001f680".encode()),
        ("ri-flag", "\U0001f1fa\U0001f1f8".encode()),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode()),
    )
    for cols in range(1, 5):
        geometries: list[tuple[str, bytes]] = [("default", b"")]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h" +
                          f"\x1b[{left};{right}s".encode())
                geometries.extend([
                    (f"active-{left}-{right}", stored),
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l"),
                ])
        for geometry_name, geometry_setup in geometries:
            for start_col in range(1, cols + 1):
                position = f"\x1b[1;{start_col}H".encode()
                for wrap_name, wrap_setup in (
                    ("wrap", b"\x1b[?7h"),
                    ("nowrap", b"\x1b[?7l"),
                ):
                    for base_name, base in bases:
                        for join_name, join in joins:
                            for follower_name, follower in followers:
                                payload = (geometry_setup + wrap_setup + position
                                           + base + join + follower)
                                name = (
                                    f"audit-post-zwj-boundary-c{cols}-"
                                    f"{geometry_name}-x{start_col}-{wrap_name}-"
                                    f"{base_name}-{join_name}-{follower_name}"
                                )
                                yield Case(name, cols, 2, payload,
                                           (len(payload),), None)


def post_zwj_cluster_boundary_representative_cases() -> Iterator[Case]:
    """Freeze the reduced random-0071 witness and close controls."""
    zwj = "\u200d".encode()
    heart_vs16 = "\u2764\ufe0f".encode()
    flag = "\U0001f1fa\U0001f1f8".encode()
    witness = flag + zwj + heart_vs16
    yield Case("random-0071-ri-flag-zwj-emoji", 3, 1, witness,
               (len(witness),), None)
    yield Case("random-0071-ri-flag-zwj-emoji-bytewise", 3, 1, witness,
               (1,) * len(witness), None)
    ri_single = "\U0001f1fa".encode() + zwj + heart_vs16
    yield Case("random-0071-ri-single-zwj-emoji", 3, 1, ri_single,
               (len(ri_single),), None)
    keycap = "1\ufe0f\u20e3".encode() + zwj + heart_vs16
    yield Case("random-0071-keycap-zwj-emoji", 3, 1, keycap,
               (len(keycap),), None)
    eligible = "\U0001f469".encode() + zwj + heart_vs16
    yield Case("random-0071-eligible-emoji-zwj-control", 3, 1, eligible,
               (len(eligible),), None)
    doubled = "\U0001f469".encode() + zwj + zwj + heart_vs16
    yield Case("random-0071-double-zwj-control", 3, 1, doubled,
               (len(doubled),), None)
    fixed_wide = "\u65e5".encode() + zwj + heart_vs16
    yield Case("random-0071-fixed-wide-zwj-control", 4, 1, fixed_wide,
               (len(fixed_wide),), None)
    separated = flag + heart_vs16
    yield Case("random-0071-no-zwj-control", 4, 1, separated,
               (len(separated),), None)
    residual_setup = (b"\x1b[?69h\x1b[2;2s\x1b[?7h\x1b[1;2H")
    heart_vs15 = "\u2764\ufe0e".encode()
    eligible_residual = (residual_setup + "\U0001f469".encode()
                         + zwj + heart_vs15)
    yield Case("random-0071-vs15-narrows-active-edge", 2, 2,
               eligible_residual, (len(eligible_residual),), None)
    joined_residual = (residual_setup
                       + "\U0001f469\u200d\U0001f4bb".encode()
                       + zwj + heart_vs15)
    yield Case("random-0071-vs15-narrows-joined-active-edge", 2, 2,
               joined_residual, (len(joined_residual),), None)
    eligible_vs16 = (residual_setup + "\U0001f469".encode()
                     + zwj + heart_vs16)
    yield Case("random-0071-vs16-active-edge-control", 2, 2,
               eligible_vs16, (len(eligible_vs16),), None)
    nowrap_setup = (b"\x1b[?69h\x1b[2;2s\x1b[?7l\x1b[1;2H")
    nowrap_residual = (nowrap_setup + "\U0001f469".encode()
                       + zwj + heart_vs15)
    yield Case("random-0071-vs15-nowrap-active-edge-control", 2, 2,
               nowrap_residual, (len(nowrap_residual),), None)


def reverse_wrap_bs_reflow_matrix_cases() -> Iterator[Case]:
    """Bound reverse-wrap/BS logical-line state across a following reflow."""
    positions = (
        ("none", b""),
        ("cr", b"\r"),
        ("cup-home", b"\x1b[H"),
        ("cub1", b"\x1b[D"),
    )
    for cols in range(1, 5):
        for rows in range(1, 3):
            for length in range(1, 2 * cols + 3):
                text = b"a" * (length - 1) + b"Z"
                for reverse_wrap, mode in (
                    (False, b"\x1b[?45l"),
                    (True, b"\x1b[?45h"),
                ):
                    for position_name, position in positions:
                        for backspaces in (1, 2):
                            payload = (mode + text + position
                                       + b"\b" * backspaces)
                            for resize_cols in range(1, 7):
                                for resize_rows in range(1, 3):
                                    name = (
                                        f"audit-reverse-wrap-bs-reflow-"
                                        f"c{cols}r{rows}-n{length}-"
                                        f"rw{int(reverse_wrap)}-{position_name}-"
                                        f"bs{backspaces}-to-"
                                        f"c{resize_cols}r{resize_rows}"
                                    )
                                    yield Case(
                                        name, cols, rows, payload,
                                        (len(payload),),
                                        (resize_cols, resize_rows),
                                    )


def reverse_wrap_bs_vertical_region_matrix_cases() -> Iterator[Case]:
    """Bound reverse-wrap BS against every small vertical region.

    Axes: widths 1...4; heights 1...5; default geometry plus every valid
    vertical top/bottom pair; absolute and origin-relative cursor addressing;
    every requested row; reverse wrap on/off; one or two backspaces; and
    blank, narrow-marker, or width-two-marker rows.  A final narrow printable
    exposes the destination selected by BS.  Cardinality: 9,600.

    Frozen candidate e35b7e1a486b3b21df8cf9acc7b1d53f378eca06136b669dae3d6dda81924a93:
    360 deltas and 9,240 exact cases.  Deltas occur exactly for an explicit
    vertical region, absolute addressing, reverse wrap enabled, and a
    requested row above the region top.  Width, content, and BS count do not
    change membership.
    """
    wide_markers = ("\u65e5", "\u754c", "\u8a9e", "\u672c", "\u7a7a")
    for cols in range(1, 5):
        for rows in range(1, 6):
            marker_setups: list[tuple[str, bytes]] = [("blank", b"")]
            narrow_parts = [b"\x1b[?7l"]
            wide_parts = [b"\x1b[?7l"]
            for marker_row in range(1, rows + 1):
                position = f"\x1b[{marker_row};1H".encode()
                narrow_parts.extend([
                    position, bytes([64 + marker_row]) * cols,
                ])
                wide_content = (wide_markers[marker_row - 1].encode() *
                                (cols // 2))
                if cols == 1:
                    wide_content = wide_markers[marker_row - 1].encode()
                elif cols % 2:
                    wide_content += bytes([96 + marker_row])
                wide_parts.extend([position, wide_content])
            marker_setups.extend([
                ("narrow", b"".join(narrow_parts)),
                ("wide", b"".join(wide_parts)),
            ])
            vertical_regions: list[tuple[str, bytes, int]] = [
                ("default", b"", 1),
            ]
            vertical_regions.extend(
                (
                    f"v{top}-{bottom}",
                    f"\x1b[{top};{bottom}r".encode(),
                    top,
                )
                for top in range(1, rows)
                for bottom in range(top + 1, rows + 1)
            )
            for vertical_name, vertical_setup, _top in vertical_regions:
                for origin_name, origin_setup in (
                    ("absolute", b"\x1b[?6l"),
                    ("origin", b"\x1b[?6h"),
                ):
                    for requested_row in range(1, rows + 1):
                        position = f"\x1b[{requested_row};1H".encode()
                        for reverse_wrap, reverse_wrap_setup in (
                            (False, b"\x1b[?45l"),
                            (True, b"\x1b[?45h"),
                        ):
                            for backspaces in (1, 2):
                                for marker_name, marker_setup in marker_setups:
                                    payload = b"".join([
                                        marker_setup, vertical_setup,
                                        origin_setup, position, b"\x1b[?7h",
                                        reverse_wrap_setup,
                                        b"\b" * backspaces, b"Z",
                                    ])
                                    name = (
                                        f"audit-reverse-wrap-bs-vregion-"
                                        f"c{cols}-r{rows}-{vertical_name}-"
                                        f"{origin_name}-y{requested_row}-"
                                        f"rw{int(reverse_wrap)}-"
                                        f"bs{backspaces}-{marker_name}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def reverse_wrap_bs_vertical_region_representative_cases() -> Iterator[Case]:
    """Compact controls for the reverse-wrap vertical-region predictor."""
    minimum = b"\x1b[2;3r\x1b[?45h\bZ"
    yield Case("reverse-wrap-vregion-minimum", 1, 3, minimum,
               (len(minimum),), None)
    yield Case("reverse-wrap-vregion-height-two", 1, 2, minimum,
               (len(minimum),), None)
    selected = (
        ("reverse-wrap-vregion-default",
         "audit-reverse-wrap-bs-vregion-c2-r4-default-absolute-y1-rw1-bs1-narrow"),
        ("reverse-wrap-vregion-at-top",
         "audit-reverse-wrap-bs-vregion-c2-r4-v2-4-absolute-y2-rw1-bs1-blank"),
        ("reverse-wrap-vregion-origin",
         "audit-reverse-wrap-bs-vregion-c2-r4-v2-4-origin-y1-rw1-bs1-blank"),
        ("reverse-wrap-vregion-mode-off",
         "audit-reverse-wrap-bs-vregion-c2-r4-v2-4-absolute-y1-rw0-bs1-blank"),
        ("reverse-wrap-vregion-above-nontop-bs1",
         "audit-reverse-wrap-bs-vregion-c1-r4-v3-4-absolute-y2-rw1-bs1-blank"),
        ("reverse-wrap-vregion-above-nontop-bs2",
         "audit-reverse-wrap-bs-vregion-c1-r4-v3-4-absolute-y2-rw1-bs2-blank"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in reverse_wrap_bs_vertical_region_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(
            f"missing reverse-wrap vertical-region controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def dch_lastwrite_matrix_cases() -> Iterator[Case]:
    """Bound DCH ownership refresh over content shapes and stored margins."""
    followers = (
        ("mn", "\u0301".encode()),
        ("zwj", "\u200d".encode()),
        ("vs16", "\ufe0f".encode()),
    )
    sources = (
        ("space", b" ", 1),
        ("ascii", b"A", 1),
        ("heart", "\u2764".encode(), 1),
        ("cjk", "\u65e5".encode(), 2),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode(), 2),
    )
    for cols in range(2, 7):
        geometries: list[tuple[str, bytes, int, int]] = [
            ("default", b"", 1, cols),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h"
                          + f"\x1b[{left};{right}s".encode())
                geometries.append(
                    (f"active-{left}-{right}", stored, left, right))
                geometries.append(
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l",
                     1, cols))
        for geometry_name, setup, left, right in geometries:
            for delete_start in range(left, right + 1):
                for delete_count in range(1, right - delete_start + 1):
                    at_delete = f"\x1b[1;{delete_start}H".encode()
                    dch = f"\x1b[{delete_count}P".encode()
                    for follower_name, follower in followers:
                        payload = (setup + at_delete + b"Z"
                                   + at_delete + dch + follower)
                        name = (
                            f"audit-dch-lastwrite-c{cols}-{geometry_name}-"
                            f"d{delete_start}-n{delete_count}-empty-"
                            f"{follower_name}"
                        )
                        yield Case(name, cols, 1, payload,
                                   (len(payload),), None)
                    for source_name, source, source_width in sources:
                        last_source_col = right - source_width + 1
                        first_source_col = delete_start + delete_count
                        for source_col in range(first_source_col,
                                                last_source_col + 1):
                            at_source = f"\x1b[1;{source_col}H".encode()
                            for state in ("moved-current", "stale-source"):
                                for follower_name, follower in followers:
                                    if state == "moved-current":
                                        payload = (setup + at_delete + b"Z"
                                                   + at_source + source
                                                   + at_delete + dch + follower)
                                    else:
                                        payload = (setup + at_source + source
                                                   + at_delete + b"Z"
                                                   + at_delete + dch + follower)
                                    name = (
                                        f"audit-dch-lastwrite-c{cols}-"
                                        f"{geometry_name}-d{delete_start}-"
                                        f"n{delete_count}-{source_name}-"
                                        f"p{source_col}-{state}-{follower_name}"
                                    )
                                    yield Case(name, cols, 1, payload,
                                               (len(payload),), None)


def cud_after_edge_matrix_cases() -> Iterator[Case]:
    """Bound vertical cursor-down state transitions after right-edge setup."""
    followers = [
        ("ascii", b"a"),
        ("nonascii-narrow", "\u00e9".encode()),
        ("heart", "\u2764".encode()),
        ("heart-vs16", "\u2764\ufe0f".encode()),
        ("wide", "\u65e5".encode()),
        ("mn", "\u0301".encode()),
    ]
    for cols in range(1, 7):
        geometries: list[tuple[str, bytes, int]] = [("default", b"", cols)]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h"
                          + f"\x1b[{left};{right}s".encode())
                geometries.append((f"active-{left}-{right}", stored, right))
                geometries.append((f"hidden-{left}-{right}",
                                   stored + b"\x1b[?69l", cols))
        for geometry_name, geometry_setup, effective_right in geometries:
            for rows in range(1, 5):
                counts = (("one", 1), ("two", 2),
                          ("height-plus-one", rows + 1))
                for source_row in range(1, rows + 1):
                    position = f"\x1b[{source_row};{effective_right}H".encode()
                    states = [
                        ("settled", position),
                        ("pending", position + b"Z"),
                        ("nowrap-parked", b"\x1b[?7l" + position + b"Z"),
                    ]
                    for count_name, count in counts:
                        move = f"\x1b[{count}B".encode()
                        for state_name, state_setup in states:
                            for follower_name, follower in followers:
                                payload = (geometry_setup + state_setup
                                           + move + follower)
                                name = (
                                    f"audit-cud-after-edge-c{cols}-r{rows}-"
                                    f"{geometry_name}-y{source_row}-"
                                    f"n{count_name}-{state_name}-{follower_name}"
                                )
                                yield Case(name, cols, rows, payload,
                                           (len(payload),), None)


def vertical_cursor_after_edge_matrix_cases() -> Iterator[Case]:
    """Focused pending-edge audit for next, preceding, and upward motion."""
    followers = [
        ("ascii", b"a"),
        ("nonascii-narrow", "\u00e9".encode()),
        ("heart", "\u2764".encode()),
        ("heart-vs16", "\u2764\ufe0f".encode()),
        ("wide", "\u65e5".encode()),
        ("mn", "\u0301".encode()),
    ]
    operations = [
        ("next-line", "E"),
        ("preceding-line", "F"),
        ("cursor-up", "A"),
    ]
    for cols in (1, 2, 6):
        geometries: list[tuple[str, bytes, int]] = [
            ("default", b"", cols),
            ("active-full", b"\x1b[?69h" + f"\x1b[1;{cols}s".encode(), cols),
        ]
        if cols > 1:
            internal = b"\x1b[?69h\x1b[1;1s"
            geometries.extend([
                ("active-internal", internal, 1),
                ("hidden-internal", internal + b"\x1b[?69l", cols),
            ])
        for geometry_name, geometry_setup, edge in geometries:
            for rows in (1, 2, 4):
                for source_row in range(1, rows + 1):
                    pending = (geometry_setup + b"\x1b[?7h"
                               + f"\x1b[{source_row};{edge}H".encode() + b"Z")
                    for count in (1, 2):
                        for operation_name, final in operations:
                            operation = f"\x1b[{count}{final}".encode()
                            for follower_name, follower in followers:
                                payload = pending + operation + follower
                                name = (
                                    f"audit-vertical-cursor-after-edge-c{cols}-"
                                    f"r{rows}-{geometry_name}-y{source_row}-"
                                    f"n{count}-{operation_name}-{follower_name}"
                                )
                                yield Case(name, cols, rows, payload,
                                           (len(payload),), None)


def cursor_up_selector_ownership_matrix_cases() -> Iterator[Case]:
    """Exhaust selector ownership after upward motion from edge states."""
    variants = [
        ("heart", "\u2764".encode()),
        ("heart-vs15", "\u2764\ufe0e".encode()),
        ("heart-vs16", "\u2764\ufe0f".encode()),
        ("plane", "\u2708".encode()),
        ("plane-vs15", "\u2708\ufe0e".encode()),
        ("plane-vs16", "\u2708\ufe0f".encode()),
        ("ascii", b"A"),
        ("nonascii-narrow", "\u00e9".encode()),
        ("fixed-wide", "\u65e5".encode()),
    ]
    for cols in range(1, 7):
        geometries: list[tuple[str, bytes, int, int]] = [
            ("default", b"", 1, cols),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h"
                          + f"\x1b[{left};{right}s".encode())
                geometries.append(
                    (f"active-{left}-{right}", stored, left, right))
                geometries.append(
                    (f"hidden-{left}-{right}", stored + b"\x1b[?69l",
                     1, cols))
        for geometry_name, geometry_setup, effective_left, effective_right in geometries:
            for rows in range(1, 5):
                counts = (("one", 1), ("two", 2),
                          ("height-plus-one", rows + 1))
                for source_row in range(1, rows + 1):
                    for count_name, count in counts:
                        target_row = max(1, source_row - count)
                        for state_name in ("settled", "pending", "nowrap-parked"):
                            if state_name == "pending":
                                destination_row = min(rows, target_row + 1)
                                destination_col = effective_left
                            else:
                                destination_row = target_row
                                destination_col = effective_right
                            destinations: list[tuple[str, bytes]] = [
                                ("blank", b""),
                                ("ascii", b"\x1b[?7l"
                                 + f"\x1b[{destination_row};{destination_col}H".encode()
                                 + b"D\x1b[?7h"),
                                ("heart", b"\x1b[?7l"
                                 + f"\x1b[{destination_row};{destination_col}H".encode()
                                 + "\u2764".encode() + b"\x1b[?7h"),
                            ]
                            if destination_col < cols:
                                destinations.append(
                                    ("wide-lead", b"\x1b[?7l"
                                     + f"\x1b[{destination_row};{destination_col}H".encode()
                                     + "\u65e5".encode() + b"\x1b[?7h"))
                            if destination_col > 1:
                                destinations.append(
                                    ("wide-continuation", b"\x1b[?7l"
                                     + f"\x1b[{destination_row};{destination_col - 1}H".encode()
                                     + "\u65e5".encode() + b"\x1b[?7h"))
                            state_mode = (b"\x1b[?7l" if state_name == "nowrap-parked"
                                          else b"\x1b[?7h")
                            source = (state_mode
                                      + f"\x1b[{source_row};{effective_right}H".encode()
                                      + (b"Z" if state_name != "settled" else b""))
                            move = f"\x1b[{count}A".encode()
                            for destination_name, destination_prefix in destinations:
                                prefix = destination_prefix + geometry_setup + source + move
                                for variant_name, variant in variants:
                                    payload = prefix + variant
                                    name = (
                                        f"audit-cursor-up-selector-c{cols}-r{rows}-"
                                        f"{geometry_name}-y{source_row}-n{count_name}-"
                                        f"{state_name}-{destination_name}-{variant_name}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def cursor_down_vertical_region_matrix_cases() -> Iterator[Case]:
    """Audit row clamping across physical and configured vertical bounds."""
    cols = 3
    horizontal_geometries = [
        ("default", b"", cols, cols),
        ("active-internal", b"\x1b[?69h\x1b[2;2s", 2, 1),
        ("hidden-internal", b"\x1b[?69h\x1b[2;2s\x1b[?69l", cols, cols),
    ]
    followers = (("none", b""), ("nonascii-narrow", "\u00e9".encode()))
    for rows in range(1, 9):
        vertical_geometries: list[tuple[str, bytes, int, int]] = [
            ("default", b"", 1, rows),
        ]
        for top in range(1, rows):
            for bottom in range(top + 1, rows + 1):
                if top == 1 and bottom == rows:
                    continue
                vertical_geometries.append(
                    (f"region-{top}-{bottom}",
                     f"\x1b[{top};{bottom}r".encode(), top, bottom))
        for vertical_name, vertical_setup, top, bottom in vertical_geometries:
            origins = [
                ("absolute", b"", range(1, rows + 1), False),
                ("origin", b"\x1b[?6h", range(top, bottom + 1), True),
            ]
            for origin_name, origin_setup, source_rows, is_origin in origins:
                for horizontal_name, horizontal_setup, edge, origin_edge in horizontal_geometries:
                    for source_row in source_rows:
                        row_arg = source_row - top + 1 if is_origin else source_row
                        col_arg = origin_edge if is_origin else edge
                        position = f"\x1b[{row_arg};{col_arg}H".encode()
                        states = [
                            ("settled", b"\x1b[?7h" + position),
                            ("pending", b"\x1b[?7h" + position + b"Z"),
                            ("nowrap-parked", b"\x1b[?7l" + position + b"Z"),
                        ]
                        counts = (("one", 1), ("two", 2),
                                  ("height-plus-one", rows + 1))
                        for state_name, state_setup in states:
                            for count_name, count in counts:
                                move = f"\x1b[{count}B".encode()
                                for follower_name, follower in followers:
                                    payload = (vertical_setup + horizontal_setup
                                               + origin_setup + state_setup
                                               + move + follower)
                                    name = (
                                        f"audit-cursor-down-region-r{rows}-"
                                        f"{vertical_name}-{origin_name}-"
                                        f"{horizontal_name}-y{source_row}-"
                                        f"{state_name}-n{count_name}-{follower_name}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def selector_repetition_matrix_cases() -> Iterator[Case]:
    """Exhaust repeated selector handling across small edge geometries.

    Axes: widths 1...4; default plus every active and hidden stored
    horizontal-margin pair; every physical start column; DECAWM on and off;
    eight narrow, wide, and joined base classes; and seven nonempty selector
    sequences.  Cardinality: 15,680.
    """
    bases = (
        ("ascii", b"A"),
        ("heart", "\u2764".encode()),
        ("plane", "\u2708".encode()),
        ("cjk", "\u65e5".encode()),
        ("rocket", "\U0001f680".encode()),
        ("grinning", "\U0001f600".encode()),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode()),
        ("flag", "\U0001f1fa\U0001f1f8".encode()),
    )
    vs15 = "\ufe0e".encode()
    vs16 = "\ufe0f".encode()
    selectors = (
        ("vs15", vs15),
        ("vs16", vs16),
        ("vs15-vs15", vs15 + vs15),
        ("vs16-vs16", vs16 + vs16),
        ("vs15-vs16", vs15 + vs16),
        ("vs16-vs15", vs16 + vs15),
        ("vs16-vs15-vs16", vs16 + vs15 + vs16),
    )
    for cols in range(1, 5):
        geometries: list[tuple[str, bytes]] = [("default", b"")]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h"
                          + f"\x1b[{left};{right}s".encode())
                geometries.append((f"active-{left}-{right}", stored))
                geometries.append((f"hidden-{left}-{right}",
                                   stored + b"\x1b[?69l"))
        for geometry_name, geometry_setup in geometries:
            for start_col in range(1, cols + 1):
                position = f"\x1b[1;{start_col}H".encode()
                for wrap_name, wrap_mode in (
                    ("wrap", b"\x1b[?7h"),
                    ("nowrap", b"\x1b[?7l"),
                ):
                    for base_name, base in bases:
                        for selector_name, selector in selectors:
                            payload = (geometry_setup + wrap_mode + position
                                       + base + selector)
                            name = (
                                f"audit-selector-repetition-c{cols}-"
                                f"{geometry_name}-x{start_col}-{wrap_name}-"
                                f"{base_name}-{selector_name}"
                            )
                            yield Case(name, cols, 2, payload,
                                       (len(payload),), None)


def vs16_overwrite_wide_matrix_cases() -> Iterator[Case]:
    """Bound selectors after a narrow overwrite of a prior wide cell."""
    wide_sources = (
        ("cjk", "\u65e5".encode()),
        ("rocket", "\U0001f680".encode()),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode()),
        ("ri-flag", "\U0001f1fa\U0001f1f8".encode()),
        ("grinning", "\U0001f600".encode()),
    )
    bases = (
        ("heart", "\u2764".encode()),
        ("plane", "\u2708".encode()),
        ("ascii", b"A"),
    )
    selectors = (
        ("none", b""),
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
    )
    for cols in range(1, 5):
        geometries: list[tuple[str, str, bytes, int, int]] = [
            ("default", "default", b"", 1, cols),
        ]
        for left in range(1, cols + 1):
            for right in range(left, cols + 1):
                stored = (b"\x1b[?69h"
                          + f"\x1b[{left};{right}s".encode())
                geometries.append(
                    (f"active-{left}-{right}", "active", stored,
                     left, right))
                geometries.append(
                    (f"hidden-{left}-{right}", "hidden",
                     stored + b"\x1b[?69l", left, right))
        for geometry_name, geometry_mode, setup, left, right in geometries:
            for rows in range(1, 5):
                for wide_name, wide in wide_sources:
                    for autowrap, mode in (
                        (True, b"\x1b[?7h"),
                        (False, b"\x1b[?7l"),
                    ):
                        effective_one = (
                            (geometry_mode in ("default", "hidden")
                             and cols == 1)
                            or (geometry_mode == "active"
                                and left == 1 and right == 1)
                        )
                        current_row = (2 if effective_one and autowrap
                                       and rows > 1 else 1)
                        positions = (
                            ("none", b""),
                            ("cr", b"\r"),
                            ("cbt", b"\x1b[Z"),
                            ("cup-current",
                             f"\x1b[{current_row};1H".encode()),
                            ("cub1", b"\x1b[D"),
                        )
                        for position_name, position in positions:
                            for base_name, base in bases:
                                for selector_name, selector in selectors:
                                    payload = (setup + mode + wide + position
                                               + base + selector)
                                    name = (
                                        f"audit-vs16-overwrite-wide-c{cols}-"
                                        f"{geometry_name}-r{rows}-{wide_name}-"
                                        f"aw{int(autowrap)}-{position_name}-"
                                        f"{base_name}-{selector_name}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def vs16_overwrite_wide_active_left_matrix_cases() -> Iterator[Case]:
    """Place the overwritten wide cell at every active one-column margin."""
    wide_sources = (
        ("cjk", "\u65e5".encode()),
        ("rocket", "\U0001f680".encode()),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode()),
        ("ri-flag", "\U0001f1fa\U0001f1f8".encode()),
        ("grinning", "\U0001f600".encode()),
    )
    bases = (
        ("heart", "\u2764".encode()),
        ("plane", "\u2708".encode()),
        ("ascii", b"A"),
    )
    selectors = (
        ("none", b""),
        ("vs15", "\ufe0e".encode()),
        ("vs16", "\ufe0f".encode()),
    )
    for cols in range(1, 5):
        for left in range(1, cols + 1):
            setup = (b"\x1b[?69h" + f"\x1b[{left};{left}s".encode()
                     + f"\x1b[1;{left}H".encode())
            for rows in range(1, 5):
                for wide_name, wide in wide_sources:
                    for autowrap, mode in (
                        (True, b"\x1b[?7h"),
                        (False, b"\x1b[?7l"),
                    ):
                        current_row = (2 if autowrap and rows > 1 else 1)
                        positions = (
                            ("none", b""),
                            ("cr", b"\r"),
                            ("cbt", b"\x1b[Z"),
                            ("cup-current",
                             f"\x1b[{current_row};{left}H".encode()),
                            ("cub1", b"\x1b[D"),
                        )
                        for position_name, position in positions:
                            for base_name, base in bases:
                                for selector_name, selector in selectors:
                                    payload = (setup + mode + wide + position
                                               + base + selector)
                                    name = (
                                        f"audit-vs16-overwrite-wide-active-"
                                        f"c{cols}-l{left}-r{rows}-{wide_name}-"
                                        f"aw{int(autowrap)}-{position_name}-"
                                        f"{base_name}-{selector_name}"
                                    )
                                    yield Case(name, cols, rows, payload,
                                               (len(payload),), None)


def origin_ri_wide_scalar_matrix_cases() -> Iterator[Case]:
    """Bound one-column wide-cell behavior across origin and RI geometry.

    A width-two grapheme is printed at the physical edge before a vertical
    region starting on row two, DECOM/DECAWM selection, one IND, and one RI.
    Axes: heights 3...5, every valid region bottom, DECOM and DECAWM, and
    two narrow plus five width-two grapheme classes.  Cardinality: 168.

    Frozen candidate ab6b00648b06eb2f3a5416367dcffe7e72084187464434418eaf6322fe7ccbd7
    classification: 30 scalar-only cell deltas.  A delta occurs exactly when
    DECOM and DECAWM are enabled and the initial grapheme is width two.  The
    reference retains its lead scalar at row two; the candidate reports zero.
    All narrow controls are exact.
    """
    graphemes = (
        ("ascii", b"A"),
        ("heart", "\u2764".encode()),
        ("cjk", "\u65e5".encode()),
        ("rocket", "\U0001f680".encode()),
        ("woman", "\U0001f469".encode()),
        ("flag", "\U0001f1fa\U0001f1f8".encode()),
        ("woman-zwj-laptop", "\U0001f469\u200d\U0001f4bb".encode()),
    )
    for rows in range(3, 6):
        for bottom in range(3, rows + 1):
            region = f"\x1b[2;{bottom}r".encode()
            for origin_name, origin in (("absolute", b""),
                                        ("origin", b"\x1b[?6h")):
                for wrap_name, wrap in (("wrap", b"\x1b[?7h"),
                                        ("nowrap", b"\x1b[?7l")):
                    for grapheme_name, grapheme in graphemes:
                        payload = wrap + grapheme + region + origin + b"\x1bD\x1bM"
                        name = (
                            f"audit-origin-ri-wide-scalar-r{rows}-b{bottom}-"
                            f"{origin_name}-{wrap_name}-{grapheme_name}"
                        )
                        yield Case(name, 1, rows, payload,
                                   (len(payload),), None)


def origin_mode_line_motion_matrix_cases() -> Iterator[Case]:
    """Bound origin-mode line motion over every small vertical geometry.

    Axes: heights 3...5; every valid top/bottom pair; every requested
    physical start row (classified above, inside, or below the region); a
    physical pre-region position or an origin-blind post-region position;
    DECOM and DECAWM on/off; IND, RI, IND+RI, or RI+IND; and blank,
    narrow-wrapped, clipped-wide-wrapped, or ordinary-unwrapped top content.
    All content is first made with autowrap enabled; the DECAWM axis controls
    the subsequent line motion. Cardinality: 10,624.

    Frozen candidate ab6b00648b06eb2f3a5416367dcffe7e72084187464434418eaf6322fe7ccbd7:
    2,220 deltas and 8,404 exact cases. Every absolute-origin case is exact;
    DECAWM never changes pass/fail membership. In origin mode, origin-blind
    starts inside the region are exact; pre-region and above/below requests
    expose cursor, scalar, or line-count deltas. The reference first resolves
    an origin coordinate to the vertical region, then applies IND/RI; the
    candidate instead admits one row above the region and physical rows below
    it, so its clamp ordering is not symmetric at the two boundaries.
    """
    content_states = (
        ("blank", b""),
        ("narrow-wrapped", b"AA"),
        ("clipped-wide-wrapped", "\U0001f469".encode()),
        ("ordinary-unwrapped", b"A\x1b[H"),
    )
    operations = (
        ("ind", b"\x1bD"),
        ("ri", b"\x1bM"),
        ("ind-ri", b"\x1bD\x1bM"),
        ("ri-ind", b"\x1bM\x1bD"),
    )
    for rows in range(3, 6):
        for top in range(1, rows):
            for bottom in range(top + 1, rows + 1):
                region = f"\x1b[{top};{bottom}r".encode()
                for start_row in range(1, rows + 1):
                    relation = ("above" if start_row < top else
                                "below" if start_row > bottom else "inside")
                    position = f"\x1b[{start_row};1H".encode()
                    for path_name, prefix, suffix in (
                        ("pre-region", position, region),
                        ("origin-blind", region, position),
                    ):
                        for origin_name, origin in (("absolute", b"\x1b[?6l"),
                                                    ("origin", b"\x1b[?6h")):
                            for wrap_name, wrap in (("wrap", b"\x1b[?7h"),
                                                    ("nowrap", b"\x1b[?7l")):
                                for content_name, content in content_states:
                                    for operation_name, operation in operations:
                                        payload = b"".join((
                                            b"\x1b[?7h", content,
                                            prefix, suffix, origin, wrap, operation,
                                        ))
                                        name = (
                                            f"audit-origin-line-motion-r{rows}-"
                                            f"v{top}-{bottom}-y{start_row}-{relation}-"
                                            f"{path_name}-{origin_name}-{wrap_name}-"
                                            f"{content_name}-{operation_name}"
                                        )
                                        yield Case(name, 1, rows, payload,
                                                   (len(payload),), None)


def origin_mode_line_motion_representative_cases() -> Iterator[Case]:
    """Compact controls for the six origin-line-motion branch witnesses."""
    selected = (
        ("origin-line-motion-pre-region-upper-ind",
         "audit-origin-line-motion-r5-v2-4-y1-above-pre-region-origin-wrap-blank-ind"),
        ("origin-line-motion-origin-blind-below-ind",
         "audit-origin-line-motion-r5-v2-4-y5-below-origin-blind-origin-wrap-blank-ind"),
        ("origin-line-motion-origin-blind-inside-pass",
         "audit-origin-line-motion-r5-v2-4-y3-inside-origin-blind-origin-nowrap-ordinary-unwrapped-ri"),
        ("origin-line-motion-narrow-ri-ind",
         "audit-origin-line-motion-r5-v2-4-y1-above-origin-blind-origin-nowrap-narrow-wrapped-ri-ind"),
        ("origin-line-motion-narrow-ind-ri",
         "audit-origin-line-motion-r3-v2-3-y1-above-origin-blind-origin-wrap-narrow-wrapped-ind-ri"),
        ("origin-line-motion-wide-ind-ri",
         "audit-origin-line-motion-r3-v2-3-y1-above-origin-blind-origin-wrap-clipped-wide-wrapped-ind-ri"),
    )
    wanted = {source for _, source in selected}
    found: dict[str, Case] = {}
    for case in origin_mode_line_motion_matrix_cases():
        if case.name in wanted:
            found[case.name] = case
            if len(found) == len(wanted):
                break
    if len(found) != len(wanted):
        missing = sorted(wanted - found.keys())
        raise AssertionError(f"missing origin line-motion controls: {missing}")
    for name, source in selected:
        case = found[source]
        yield Case(name, case.cols, case.rows, case.payload,
                   case.chunks, case.resize)


def chunk_plan(length: int, rng: random.Random) -> tuple[int, ...]:
    result: list[int] = []
    remaining = length
    while remaining:
        size = min(remaining, rng.randint(1, 23))
        result.append(size)
        remaining -= size
    return tuple(result)


def targeted_cases() -> list[tuple[str, bytes, tuple[int, int] | None]]:
    esc = b"\x1b"
    csi = esc + b"["
    st = esc + b"\\"
    kitty = lambda control, payload=b"": esc + b"_G" + control + b";" + payload + st
    return [
        ("sgr-matrix", b"".join(
            esc + f"[{code}m".encode() + b"X" for code in
            [0, 1, 2, 3, 4, 5, 7, 8, 9, 21, 22, 23, 24, 25, 27, 28, 29,
             30, 37, 40, 47, 90, 97, 100, 107, 39, 49]), None),
        ("sgr-semicolon-colors", b"".join([
            esc + b"[38;5;196mA", esc + b"[48;5;22mB",
            esc + b"[4;58;5;33mC", esc + b"[58;2;1;2;3mD",
            esc + b"[38;2;10;20;30mE", esc + b"[48;2;255;128;0mF",
            esc + b"[39;49;59mG", esc + b"[0mH",
        ]), None),
        ("sgr-colon-colors", b"".join([
            csi + b"38:5:201mA", csi + b"48:5:17mB",
            csi + b"4:3;58:5:45mC", csi + b"38:2::1:2:3mD",
            csi + b"48:2:0:250:128:4mE", csi + b"58:2::9:8:7mF",
            csi + b"0mG",
        ]), None),
        ("sgr-truncated-extended", b"".join([
            csi + b"38;5mA", csi + b"38;2;1;2mB", csi + b"48;2;3mC",
            csi + b"58;5mD", csi + b"38:2::4:5mE",
            csi + b"48:5mF", csi + b"58:2::6mG", csi + b"0mH",
        ]), None),
        ("unicode-mn", "A\u0301\u0327 B\u20dd \u0308C n\u0303\u0301".encode(), None),
        ("unicode-zwj", ("\U0001f469\u200d\U0001f4bb "
         "\U0001f468\u200d\U0001f469\u200d\U0001f467 "
         "x\u200dy").encode(), None),
        ("unicode-regional-indicators", ("\U0001f1fa\U0001f1f8 "
         "\U0001f1e8\U0001f1e6 \U0001f1e6\U0001f1e7\U0001f1e8").encode(), None),
        ("unicode-variation-selectors", ("\u2764\ufe0e \u2764\ufe0f "
         "\u2708\ufe0e \u2708\ufe0f 1\ufe0f\u20e3").encode(), None),
        ("wide-overwrite-continuation-stub", csi + b"1;1H" + esc + b"H" + b"A"
         + "\U0001f680".encode() + csi + b"Z" + "\U0001f680".encode(), None),
        ("insert-delete-characters", b"0123456789" + csi + b"1;4H" + csi + b"3@ABC"
         + csi + b"2P" + csi + b"2X" + csi + b"4hxy" + csi + b"4l", None),
        ("insert-delete-lines", b"one\r\ntwo\r\nthree\r\nfour\r\nfive"
         + csi + b"2;5r" + csi + b"3;1H" + csi + b"2LINS"
         + csi + b"1M", None),
        ("autowrap-wide-pending", csi + b"?7h123456789012" + "日".encode()
         + csi + b"?7lABCDEFGHIJKLMN" + csi + b"?7h" + b"XY", None),
        ("reverse-wrap-bs", csi + b"?7h" + csi + b"?45hABCDE\r\n12345\r\b\bZ"
         + csi + b"?45l\bQ", None),
        ("controls-bs-cr-lf", b"abcd\bZ\rQ\nR\r\nS\b\bT", None),
        ("controls-ind-ri", b"one\r\ntwo\r\nthree\r\nfour\r\nfive"
         + csi + b"2;5r" + csi + b"5;1H" + esc + b"D" + esc + b"D"
         + csi + b"2;1H" + esc + b"M" + esc + b"M", None),
        ("origin-vertical-margins", b"0\r\n1\r\n2\r\n3\r\n4\r\n5"
         + csi + b"2;5r" + csi + b"?6h" + csi + b"1;1HA"
         + csi + b"4;3HZ\nY" + csi + b"?6l", None),
        ("horizontal-margins", b"abcdefghijkl" + csi + b"?69h" + csi + b"3;10s"
         + csi + b"2;3H0123456789ABC" + csi + b"2;5H" + csi + b"2@XY"
         + csi + b"1P", None),
        ("rectangular-margins", b"ABCDEFGHIJKL\r\nabcdefghijkl\r\n0123456789ab"
         + csi + b"?69h" + csi + b"3;10s" + csi + b"2;5r" + csi + b"?6h"
         + csi + b"4;8H" + esc + b"D" + esc + b"M" + csi + b"?6l", None),
        ("tab-stops", b"A\tB" + csi + b"3g" + csi + b"1;4H" + esc + b"H"
         + csi + b"1;9H" + esc + b"H\r1\t2\t3" + csi + b"2ZL"
         + csi + b"2IR" + csi + b"g", None),
        ("decbi", b"ABCDEFGHIJKL\r\nabcdefghijkl" + csi + b"?69h" + csi + b"3;10s"
         + csi + b"2;3H" + esc + b"6" + b"X", None),
        ("decfi", b"ABCDEFGHIJKL\r\nabcdefghijkl" + csi + b"?69h" + csi + b"3;10s"
         + csi + b"1;10H" + esc + b"9" + b"Y", None),
        ("insert-delete-columns", b"ABCDEFGHIJKL\r\nabcdefghijkl\r\n0123456789ab"
         + csi + b"?69h" + csi + b"2;11s" + csi + b"1;3r"
         + csi + b"2;5H" + csi + b"2'}" + csi + b"1'~", None),
        ("kitty-chunked-transmit", kitty(b"f=32,s=2,v=1,i=9,m=1,q=2", b"/wAA/wD/")
         + kitty(b"m=0,q=2", b"AP8=") + b"after", None),
        ("kitty-place-delete", kitty(b"a=t,f=32,s=1,v=1,i=11,q=2", b"/wAA/w==")
         + kitty(b"a=p,i=11,p=3,x=0,y=0,c=1,r=1,q=2")
         + kitty(b"a=d,d=i,i=11,p=3,q=2") + b"done", None),
        ("kitty-malformed", kitty(b"a=T,f=32,s=1,v=1,i=12,q=2", b"%%%not-base64%%")
         + kitty(b"a=z,i=-1,s=0,v=999999999999,q=2", b"AA==")
         + esc + b"_Gbroken" + st + b"recovered", None),
        ("kitty-placeholder", kitty(b"a=T,f=32,s=1,v=1,i=42,U=1,q=2", b"/wAA/w==")
         + "\U0010eeee\u0305\u0305 \U0010eeee\u0305\u030d\u030e".encode(), None),
        ("semantic-block", b"\x1b]133;A\x07$ \x1b]133;B\x07false\r\n"
         b"\x1b]133;C\x07failure\r\n\x1b]133;D;1\x07"
         b"\x1b]133;A\x1b\\# \x1b]133;B\x1b\\sleep\r\n"
         b"\x1b]133;C\x1b\\running", None),
        ("resize-reflow-shrink", ("abc\u0301\U0001f680" * 80).encode(), (7, 11)),
        ("resize-reflow-grow", ("wide\U0001f680\r\n" * 24).encode(), (31, 4)),
    ]


def random_payload(rng: random.Random, actions: int) -> bytes:
    esc = b"\x1b"
    st = esc + b"\\"
    printable = [
        b"a", b"Z", b"0", b" ", "é".encode(), "日".encode(), "🚀".encode(),
        "A\u0301".encode(), "\U0001f469\u200d\U0001f4bb".encode(),
        "\U0001f1fa\U0001f1f8".encode(), "\u2764\ufe0f".encode(),
    ]
    controls = [b"\b", b"\t", b"\r", b"\n", esc + b"D", esc + b"M",
                esc + b"6", esc + b"9", esc + b"H"]
    csi = [
        b"\x1b[0m", b"\x1b[1m", b"\x1b[22m", b"\x1b[31m", b"\x1b[39m",
        b"\x1b[38;5;201m", b"\x1b[48;2;4;8;16m", b"\x1b[58;5;45m",
        b"\x1b[38:2::4:8:16m", b"\x1b[48:5:99m", b"\x1b[58:2::9:8:7m",
        b"\x1b[38;2;1m", b"\x1b[48:2::3:4m", b"\x1b[2@", b"\x1b[2P",
        b"\x1b[2L", b"\x1b[2M", b"\x1b[2X", b"\x1b[4h", b"\x1b[4l",
        b"\x1b[2A", b"\x1b[2B", b"\x1b[2C", b"\x1b[2D", b"\x1b[H",
        b"\x1b[2;6H", b"\x1b[2;5r", b"\x1b[?6h", b"\x1b[?6l",
        b"\x1b[?7h", b"\x1b[?7l", b"\x1b[?45h", b"\x1b[?45l",
        b"\x1b[?69h", b"\x1b[?69l", b"\x1b[2;9s", b"\x1b[g", b"\x1b[3g",
        b"\x1b[2I", b"\x1b[2Z", b"\x1b[2'}", b"\x1b[2'~",
    ]
    kitty = [
        esc + b"_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==" + st,
        esc + b"_Ga=d,d=i,i=3,q=2;" + st,
        esc + b"_Ga=T,f=32,s=1,v=1,q=2;%%%" + st,
    ]
    semantic = [b"\x1b]133;A\x07", b"\x1b]133;B\x07", b"\x1b]133;C\x07",
                b"\x1b]133;D;0\x07"]
    combining = ["\u0301".encode(), "\ufe0f".encode(), "\u200d".encode(),
                 "\U0010eeee\u0305\u030d\u030e".encode()]
    choices = printable * 7 + controls * 3 + csi * 2 + combining + kitty + semantic
    return b"".join(rng.choice(choices) for _ in range(actions))


def first_difference(left: object, right: object, path: str = "$") -> str:
    if type(left) is not type(right):
        return f"{path}: type {type(left).__name__} != {type(right).__name__}"
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return f"{path}: keys differ"
        for key in left:
            difference = first_difference(left[key], right[key], f"{path}.{key}")
            if difference:
                return difference
        return ""
    if isinstance(left, list):
        if len(left) != len(right):
            return f"{path}: length {len(left)} != {len(right)}"
        for index, (a, b) in enumerate(zip(left, right)):
            difference = first_difference(a, b, f"{path}[{index}]")
            if difference:
                return difference
        return ""
    return "" if left == right else f"{path}: {left!r} != {right!r}"


def case_to_wire(case: Case) -> dict[str, object]:
    return {
        "name": case.name,
        "cols": case.cols,
        "rows": case.rows,
        "payload": case.payload.hex(),
        "chunks": list(case.chunks),
        "resize": list(case.resize) if case.resize is not None else None,
    }


def case_from_wire(value: dict[str, object]) -> Case:
    resize_value = value["resize"]
    resize = None if resize_value is None else tuple(int(item) for item in resize_value)
    return Case(
        str(value["name"]), int(value["cols"]), int(value["rows"]),
        bytes.fromhex(str(value["payload"])),
        tuple(int(item) for item in value["chunks"]), resize,  # type: ignore[arg-type]
    )


def worker_main(library_path: Path) -> int:
    """Load exactly one Swift dylib in this process and serve snapshots.

    Swift/Objective-C class registration is process-global. Loading two builds
    of CmdyCore in one Python process makes the second build's class selection
    undefined, so the comparison parent must never call ctypes itself.
    """
    core = CoreLibrary(library_path)
    for line in sys.stdin:
        try:
            case = case_from_wire(json.loads(line))
            response: dict[str, object] = {"snapshot": core.run(case)}
        except Exception as error:  # keep the parent error attributable to a side
            response = {"error": f"{type(error).__name__}: {error}"}
        print(json.dumps(response, sort_keys=True, separators=(",", ":")), flush=True)
    return 0


class CoreWorker:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.process = subprocess.Popen(
            [sys.executable, "-u", str(Path(__file__).resolve()),
             "--worker-library", str(path.resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )

    def run(self, case: Case) -> dict[str, object]:
        if self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError(f"worker pipes unavailable for {self.path}")
        self.process.stdin.write(json.dumps(case_to_wire(case), separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            stderr = ""
            if self.process.stderr is not None:
                stderr = self.process.stderr.read()
            raise RuntimeError(
                f"snapshot worker exited for {self.path} "
                f"(status={self.process.poll()}): {stderr.strip()}")
        response = json.loads(line)
        if "error" in response:
            raise RuntimeError(f"{self.path}: {response['error']}")
        return response["snapshot"]

    def close(self) -> None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


def difference_surface(difference: str) -> str:
    path = difference.split(":", 1)[0]
    if path.startswith("$.cells"):
        # Preserve the cell field (scalar, width, fg, bg, or style), while
        # allowing delta debugging to move the differing cell. Preserve the
        # observed values too, so minimization cannot switch from (say) an
        # incomplete foreground color to an unrelated background-color bug.
        values = difference.split(": ", 1)[1] if ": " in difference else ""
        return "cells:" + path.rsplit("[", 1)[-1].rstrip("]") + ":" + values
    return path.split("[", 1)[0]


def minimized_failure(
    case: Case, reference: CoreWorker, candidate: CoreWorker,
    original_difference: str, max_probes: int,
) -> tuple[Case, str, int]:
    """Delta-debug a mismatch by bytes while retaining its ABI surface."""
    surface = difference_surface(original_difference)
    probes = 0

    def reproduces(payload: bytes, resize: tuple[int, int] | None) -> tuple[bool, str]:
        nonlocal probes
        if probes >= max_probes:
            return False, ""
        probes += 1
        chunks = (len(payload),) if payload else ()
        probe = Case(case.name + "-min", case.cols, case.rows, payload, chunks, resize)
        difference = first_difference(reference.run(probe), candidate.run(probe))
        return difference_surface(difference) == surface, difference

    payload = case.payload
    resize = case.resize
    # First remove chunk-boundary dependence if the behavior permits it.
    same, difference = reproduces(payload, resize)
    if not same:
        return case, original_difference, probes
    current_difference = difference
    if resize is not None:
        same, difference = reproduces(payload, None)
        if same:
            resize = None
            current_difference = difference

    granularity = 2
    while len(payload) >= 2 and probes < max_probes:
        part_size = (len(payload) + granularity - 1) // granularity
        reduced = False
        for start in range(0, len(payload), part_size):
            trial = payload[:start] + payload[start + part_size:]
            same, difference = reproduces(trial, resize)
            if same:
                payload = trial
                current_difference = difference
                granularity = max(2, granularity - 1)
                reduced = True
                break
        if not reduced:
            if granularity >= len(payload):
                break
            granularity = min(len(payload), granularity * 2)

    minimized = Case(
        case.name + "-min", case.cols, case.rows, payload,
        (len(payload),) if payload else (), resize,
    )
    return minimized, current_difference, probes


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--worker-library":
        return worker_main(Path(sys.argv[2]))

    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=0xC0D1)
    parser.add_argument("--random-cases", type=int, default=2000)
    parser.add_argument("--actions", type=int, default=180)
    parser.add_argument("--no-minimize", action="store_true",
                        help="do not delta-debug the first behavioral mismatch")
    parser.add_argument("--suppress-wire", action="store_true",
                        help="omit serialized payloads from failure output")
    parser.add_argument("--minimize-probes", type=int, default=256)
    parser.add_argument(
        "--audit-matrix", action="append", default=[],
        choices=("nowrap-dl", "il-to-dl-superset", "narrowed-margin-dl",
                 "narrowed-margin-dl-content",
                 "active-margin-il-dl-roundtrip",
                 "hidden-margin-decfi-wide", "hidden-margin-decfi-cursor",
                 "active-margin-decfi-wide-persistence",
                 "hidden-margin-vs16-setup", "ind-stored-margin-geometry",
                 "lf-ri-parked-geometry",
                 "active-edge-print-setup",
                 "declrmm-normalization", "cuf-after-edge", "cht-after-edge",
                 "semantic-block-resize-edge",
                 "semantic-resize-history",
                 "semantic-resize-multi-history",
                 "semantic-prewrapped-destination",
                 "semantic-line-motion-boundary",
                 "semantic-later-softwrap",
                 "semantic-hidden-margin-rewrap",
                 "kitty-control-pending", "kitty-row-advance",
                 "kitty-row-horizontal-margin", "kitty-row-background",
                 "kitty-retransmit-line-generation",
                 "decbi-generated-blank-grapheme",
                 "ht-lastwrite", "selector-after-forward-motion",
                 "selector-forward-reverse",
                 "selector-motion-observer", "selector-reposition-left",
                 "selector-after-vertical-reposition",
                 "active-margin-pending-bs",
                 "ht-selector-cursor-width",
                 "active-margin-irm-orphan-tail",
                 "active-margin-dl-background-history",
                 "dl-single-content", "vs-lastwrite", "post-zwj-wide",
                 "parked-wide-selector-owner", "c1-grapheme-owner",
                 "semantic-kitty-resize-block",
                 "decfi-grapheme-owner",
                 "dl-grapheme-owner",
                 "post-zwj-cluster-boundary",
                 "reverse-wrap-bs-reflow", "reverse-wrap-bs-vregion",
                 "dch-lastwrite",
                 "cud-after-edge", "vertical-cursor-after-edge",
                 "cursor-up-selector-ownership",
                 "cursor-down-vertical-region",
                 "selector-repetition",
                 "vs16-overwrite-wide", "vs16-overwrite-wide-active-left",
                 "origin-ri-wide-scalar", "origin-mode-line-motion"),
        help="append a saved bounded public-ABI audit matrix after random cases",
    )
    args = parser.parse_args()
    for path in (args.reference, args.candidate):
        if not path.is_file():
            parser.error(f"library does not exist: {path}")

    rng = random.Random(args.seed)
    cases: list[Case] = []
    for name, payload, resize in targeted_cases():
        cases.append(Case(name, 12, 6, payload, chunk_plan(len(payload), rng), resize))
    # cmdy_create accepts every positive width. A width-2 grapheme on the
    # smallest legal screen has distinct wrap/storage behavior and cannot be
    # exercised by the standard 12-column targeted dimensions.
    narrow_wide = "\U0001f680".encode()
    cases.append(Case("narrow-screen-wide-glyph", 1, 3, narrow_wide,
                      (1, 1, 1, 1), None))
    overlap_wide = "\U0001f680".encode() + b"\x1b6" + "\u65e5".encode()
    cases.append(Case("wide-overwrite-from-continuation", 4, 3, overlap_wide,
                      (4, 1, 1, 3), None))
    colored_vs16 = b"\x1b[38;5;201m" + "\u2764\ufe0f".encode()
    cases.append(Case("colored-vs16-continuation", 4, 2, colored_vs16,
                      (11, 3, 1, 1, 1), None))
    cases.append(Case("vs16-after-fixed-wide-cjk", 2, 1,
                      "\u65e5\ufe0f".encode(), (3, 3), None))
    cases.append(Case("vs15-after-fixed-wide-cjk", 2, 1,
                      "\u65e5\ufe0e".encode(), (3, 3), None))
    cases.append(Case("vs16-at-right-edge-preserves-next-row-decbi-space", 2, 3,
                      b"\x1b6\ta\x1b[B" + "\u2764\ufe0f".encode(),
                      (2, 1, 1, 3, 3, 3), None))
    vs16_wrap_bs = "\u2764\ufe0f".encode() + b"a0\b"
    cases.append(Case("vs16-wrap-pending-backspace", 4, 6, vs16_wrap_bs,
                      (3, 3, 1, 1, 1), None))
    moved_cursor_mn = b"Z\b" + "\u0301".encode()
    cases.append(Case("mn-after-cursor-move", 5, 3, moved_cursor_mn,
                      (1, 1, 1, 1), None))
    vs16_zwj = "Z\ufe0f\u200d".encode()
    cases.append(Case("trailing-zwj-after-vs16", 5, 3, vs16_zwj,
                      (1, 3, 1, 2), None))
    decbi_outside_margin = b"\x1b[?69h\x1b[1;2s\x1b[4G\x1b6"
    cases.append(Case("decbi-outside-right-margin", 4, 2,
                      decbi_outside_margin, (6, 6, 4, 2), None))
    # At the smallest width, a printable leaves the cursor wrap-pending.  LF
    # must handle that logical cursor state without materializing an extra
    # wrapped blank line first.  Keep this after the RNG-backed targets so the
    # established random corpus remains byte-for-byte stable.
    cases.append(Case("lf-after-wrap-pending", 1, 1, b"Z\n", (1, 1), None))
    cases.append(Case("bs-after-no-wrap-right-edge", 2, 1,
                      b"\x1b[?7l\tA\b", (5, 1, 1, 1), None))
    cases.append(Case("bs-reverse-wrap-with-declrmm-at-origin", 2, 1,
                      b"\x1b[?45h\x1b[?69h\b", (6, 6, 1), None))
    cases.append(Case("il-after-vs16-pending-with-declrmm", 1, 1,
                      b"\x1b[?69h" + "\u2764\ufe0f".encode() + b"\x1b[L",
                      (6, 3, 3, 3), None))
    cases.append(Case("il-after-wide-vs16-pending-with-declrmm", 2, 1,
                      b"\x1b[?69h" + "\u2764\ufe0f".encode() + b"\x1b[L",
                      (6, 3, 3, 3), None))
    cases.append(Case("il-after-pending-at-physical-edge-with-custom-margins", 3, 1,
                      b"\x1b[?69h\x1b[2;3s\tA\x1b[L",
                      (6, 6, 1, 1, 3), None))
    cases.append(Case("il-after-cbt-from-pending-with-custom-margins", 3, 1,
                      b"\x1b[?69h\x1b[2;3s\tA\x1b[Z\x1b[L",
                      (6, 6, 1, 1, 3, 3), None))
    cases.append(Case("vs16-after-cud-from-wrap-pending", 1, 3,
                      b"a\x1b[B" + "\u2764\ufe0f".encode(),
                      (1, 3, 3, 3), None))
    cases.append(Case("vs16-after-cud-from-nonzero-wrap-pending", 2, 3,
                      b"\ta\x1b[B" + "\u2764\ufe0f".encode(),
                      (1, 1, 3, 3, 3), None))
    vs16_active_background_row = (b"\x1b[40m\x1b[2Ja\x1b[B"
                                  + "\u2764\ufe0f".encode())
    cases.append(Case("vs16-after-cud-on-active-background-erased-screen", 1, 3,
                      vs16_active_background_row,
                      (5, 4, 1, 3, 3, 3), None))
    ri_wrap_pending = b"\t\b0A\x1bM "
    cases.append(Case("space-after-ri-wrap-pending", 2, 2,
                      ri_wrap_pending, (1, 1, 2, 2, 1), None))
    decfi_after_wide = b"Z\n\x1b[?7l" + "\U0001f1fa\U0001f1f8".encode() + b"\b\x1b9"
    cases.append(Case("decfi-after-wide-continuation", 3, 1,
                      decfi_after_wide, (2, 5, 8, 1, 2), None))
    irm_wide_shift = "\u65e5".encode() + b"\x1b[4h\ra"
    cases.append(Case("irm-wide-shift-order", 3, 1,
                      irm_wide_shift, (3, 4, 1, 1), None))
    irm_wide_right_edge = b"\x1b[4h" + "\u65e5".encode() + b"\rA"
    cases.append(Case("irm-shift-drops-wide-at-right-edge", 2, 1,
                      irm_wide_right_edge, (4, 3, 1, 1), None))
    irm_zwj_pending = b"\x1b[4h" + "\u65e5\u200d".encode() + b"a"
    cases.append(Case("irm-zwj-preserves-wrap-pending", 2, 2,
                      irm_zwj_pending, (4, 3, 3, 1), None))
    cases.append(Case("declrmm-zwj-allows-next-print", 3, 1,
                      b"\x1b[?69h" + "\u65e5\u200d".encode() + b"Z",
                      (6, 3, 3, 1), None))
    cases.append(Case("resize-trailing-line-from-narrow-screen", 1, 2,
                      b"a\n", (1, 1), (1, 1)))
    cases.append(Case("ind-after-wrap-pending", 1, 2,
                      b"Z\x1bD", (1, 1, 1), None))
    cases.append(Case("ind-after-no-wrap-right-edge", 1, 1,
                      b"\x1b[?7l0\x1bD", (5, 1, 2), None))
    combining_after_ind = (b"A\x1bD" + "\u0301".encode()
                           + b"B\x1bD" + "\u200d".encode())
    cases.append(Case("mn-and-zwj-after-ind", 1, 1,
                      combining_after_ind, (1, 2, 2, 1, 2, 3), None))
    wide_after_full_nowrap = b"\x1b[?7la" + "\u65e5".encode()
    cases.append(Case("wide-after-full-row-autowrap-off", 1, 1,
                      wide_after_full_nowrap, (5, 1, 1, 1, 1), None))
    decfi_colored_wide = (b"\x1b[48:5:99ma" + "\u65e5".encode()
                          + b"a\x1b[48:2::3:4m\x1bMa\x1b9")
    cases.append(Case("decfi-colored-wide-cell-shift", 3, 2,
                      decfi_colored_wide, (10, 1, 3, 1, 12, 2, 1, 2), None))
    nowrap_zwj = b"\x1b[?7la" + "\U0001f469\u200d\U0001f4bb".encode()
    cases.append(Case("nowrap-rejected-zwj-sequence", 2, 1,
                      nowrap_zwj, (5, 1, 4, 3, 4), None))
    nowrap_zwj_one_column = b"Z\x1b[?7l\t" + "\U0001f469\u200d\U0001f4bb".encode()
    cases.append(Case("nowrap-rejected-zwj-on-one-column", 1, 1,
                      nowrap_zwj_one_column, (1, 5, 1, 4, 3, 4), None))
    nowrap_zwj_after_vs16 = (b"\x1b[?7l" + "\u2764\ufe0f".encode()
                             + "\U0001f469\u200d\U0001f4bb".encode())
    cases.append(Case("nowrap-rejected-zwj-laptop-after-vs16", 1, 1,
                      nowrap_zwj_after_vs16, (5, 3, 3, 4, 3, 4), None))
    cbt_narrow_wide = ("\u65e5\u65e5".encode() + b"\x1b[Z"
                       + "\u2764\ufe0f".encode())
    cases.append(Case("cbt-after-narrow-wide-lines", 1, 1,
                      cbt_narrow_wide, (3, 3, 3, 3, 3), None))
    cases.append(Case("decbi-with-vertical-margin", 1, 3,
                      b"\x1b[2r\x1b6", (4, 1, 1), None))
    cases.append(Case("declrmm-default-margins-one-column", 1, 2,
                      b"\x1b[?69h\x1bD\x1b[s", (6, 2, 3), None))
    cases.append(Case("declrmm-invalid-explicit-margins-preserve-cursor", 2, 2,
                      b"\n\x1b[?69h\x1b[2;9s", (1, 6, 6), None))
    cases.append(Case("declrmm-valid-margins-with-origin-mode", 9, 1,
                      b"\x1b[?6h\x1b[?69h\x1b[2;9s", (5, 6, 6), None))
    cases.append(Case("declrmm-valid-margins-preserve-cursor", 9, 1,
                      b"\x1b[?69hA\x1b[2;9s", (6, 1, 6), None))
    ind_outside_right_margin = (b"\x1b[?6h\x1b[?69h\x1b[2;9s"
                                b"\x1b[10G\x1bD")
    cases.append(Case("ind-outside-right-margin-with-origin-mode", 10, 2,
                      ind_outside_right_margin, (5, 6, 6, 5, 2), None))
    vs16_hidden_right_margin = (b"\x1b[?6h\x1b[?69h\x1b[2;9s\x1b[9G"
                                + "\u2764\ufe0f".encode())
    cases.append(Case("vs16-at-ignored-right-margin-with-origin-mode", 10, 1,
                      vs16_hidden_right_margin, (5, 6, 6, 4, 3, 3), None))
    print_outside_right_margin = (b"\x1b[?6h\x1b[?69h\x1b[2;9s"
                                  b"\x1b[10G0")
    cases.append(Case("print-outside-right-margin-with-origin-mode", 10, 1,
                      print_outside_right_margin, (5, 6, 6, 5, 1), None))
    ri_after_vs16_outside_margin = (b"\x1b[?6h\x1b[?69h\x1b[2;9s\n"
                                    b"\x1b[9G" + "\u2764\ufe0f".encode()
                                    + b"\x1bM")
    cases.append(Case("ri-after-vs16-pending-outside-right-margin", 10, 2,
                      ri_after_vs16_outside_margin,
                      (5, 6, 6, 1, 4, 3, 3, 2), None))
    cases.append(Case("ri-preserves-onscreen-pending-beyond-right-margin", 12, 2,
                      ri_after_vs16_outside_margin,
                      (5, 6, 6, 1, 4, 3, 3, 2), None))
    ri_top_outside_margin = b"\x1b[?69h\x1b[2;9sAX\x1b[10G\x1bM"
    cases.append(Case("ri-at-top-outside-right-margin-preserves-region", 10, 1,
                      ri_top_outside_margin, (6, 6, 2, 5, 2), None))
    decfi_after_vs16_beyond_margin = (b"\x1b[?69h\x1b[2;9s\x1b[9G"
                                       + "\u2764\ufe0f".encode() + b"\x1b9")
    cases.append(Case("decfi-advances-onscreen-beyond-right-margin", 12, 1,
                      decfi_after_vs16_beyond_margin,
                      (6, 6, 4, 3, 3, 2), None))
    margin_wide_overwrite = ("\u2764\ufe0f".encode()
                             + b"\x1b[?69h\x1b[1;1s"
                             + "\U0001f680".encode())
    cases.append(Case("wide-overwrite-in-one-column-horizontal-margin", 2, 1,
                      margin_wide_overwrite, (3, 3, 6, 6, 2, 2), None))
    kitty_right_edge = (b"\t\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;"
                        b"/wAA/w==\x1b\\")
    cases.append(Case("kitty-transmit-at-right-edge", 2, 2,
                      kitty_right_edge, (1, 38), None))
    kitty_nonedge_column = (b"a\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;"
                            b"/wAA/w==\x1b\\")
    cases.append(Case("kitty-transmit-resets-nonzero-column", 3, 2,
                      kitty_nonedge_column, (1, 38), None))
    dl_active_background = b"\x1b[?69h\x1b[48:5:99m\n\x1b[M"
    cases.append(Case("delete-line-active-background-declrmm", 1, 2,
                      dl_active_background, (6, 10, 1, 3), None))
    cases.append(Case("delete-line-active-background-at-top-with-declrmm", 1, 1,
                      b"\x1b[?69h\x1b[40m\x1b[M",
                      (6, 5, 3), None))
    cases.append(Case("delete-line-active-background-from-middle-with-declrmm", 1, 3,
                      b"\x1b[?69h\x1b[40m\n\x1b[M",
                      (6, 5, 1, 3), None))
    cases.append(Case("delete-lines-active-background-count-exceeds-bottom", 1, 2,
                      b"\x1b[?69h\n\x1b[40m\x1b[2M",
                      (6, 1, 5, 4), None))
    cases.append(Case("delete-lines-active-background-bottom-height-three", 1, 3,
                      b"\x1b[?69h\x1b[3;1H\x1b[40m\x1b[2M",
                      (6, 6, 5, 4), None))
    cases.append(Case("delete-lines-active-background-middle-height-three", 1, 3,
                      b"\x1b[?69h\x1b[2;1H\x1b[40m\x1b[2M",
                      (6, 6, 5, 4), None))
    cases.append(Case("delete-line-active-background-above-vertical-margin", 1, 3,
                      b"\x1b[?69h\x1b[2;3r\x1b[40m\x1b[M",
                      (6, 6, 5, 3), None))
    cases.append(Case("delete-lines-active-background-above-vertical-margin", 1, 3,
                      b"\x1b[?69h\x1b[2;3r\x1b[40m\x1b[2M",
                      (6, 6, 5, 4), None))
    cases.append(Case("delete-line-active-background-larger-vertical-margin", 1, 4,
                      b"\x1b[?69h\x1b[2;4r\x1b[40m\x1b[M",
                      (6, 6, 5, 3), None))
    cases.append(Case("delete-line-shifts-content-above-vertical-margin", 1, 4,
                      b"\x1b[?69h\x1b[3;1HA\x1b[2;4r\x1b[M",
                      (6, 6, 1, 6, 3), None))
    cases.append(Case("delete-line-above-vertical-margin-with-declrmm", 1, 3,
                      b"\x1b[?69hA\x1b[2;3r\x1b[M",
                      (6, 1, 6, 3), None))
    cases.append(Case("delete-lines-active-background-middle-height-four", 1, 4,
                      b"\x1b[?69h\x1b[2;1H\x1b[40m\x1b[2M",
                      (6, 6, 5, 4), None))
    cases.append(Case("delete-lines-active-background-full-height-two", 1, 2,
                      b"\x1b[?69h\x1b[40m\x1b[2M",
                      (6, 5, 4), None))
    cases.append(Case("delete-line-active-background-inside-vertical-margin", 1, 3,
                      b"\x1b[?69h\x1b[2;3r\n\x1b[40m\x1b[M",
                      (6, 6, 1, 5, 3), None))
    cases.append(Case("delete-line-active-background-below-vertical-margin", 1, 3,
                      b"\x1b[?69h\x1b[1;2r\n\x1b[40m\x1b[M",
                      (6, 6, 1, 5, 3), None))
    cases.append(Case("delete-lines-active-background-below-vertical-margin", 1, 3,
                      b"\x1b[?69h\x1b[1;2r\n\x1b[40m\x1b[2M",
                      (6, 6, 1, 5, 4), None))
    cases.append(Case("delete-line-active-background-from-margin-interior", 1, 4,
                      b"\x1b[?69h\x1b[1;3r\n\x1b[40m\x1b[M",
                      (6, 6, 1, 5, 3), None))
    cases.append(Case("delete-line-does-not-fill-below-vertical-margin", 1, 3,
                      b"\x1b[?69h\x1b[1;2r\x1b[40m\x1b[M",
                      (6, 6, 5, 3), None))
    cases.append(Case("repeated-delete-line-active-background-at-bottom", 1, 2,
                      b"\x1b[?69h\n\x1b[40m\x1b[M\x1b[M",
                      (6, 1, 5, 3, 3), None))
    cases.append(Case("delete-line-then-delete-two-active-background", 1, 3,
                      b"\x1b[?69h\n\x1b[40m\x1b[M\x1b[2M",
                      (6, 1, 5, 3, 4), None))
    cases.append(Case("repeated-delete-line-uses-current-background", 1, 1,
                      b"\x1b[?69h\x1b[41m\x1b[M\x1b[40m\x1b[M",
                      (6, 5, 3, 5, 3), None))
    cases.append(Case("delete-two-then-delete-line-preserves-background", 1, 2,
                      b"\x1b[?69h\n\x1b[40m\x1b[2M\x1b[M",
                      (6, 1, 5, 4, 3), None))
    cases.append(Case("delete-line-after-lf-does-not-retain-background", 1, 2,
                      b"\x1b[?69h\x1b[40m\x1b[M\n\x1b[M",
                      (6, 5, 3, 1, 3), None))
    cases.append(Case("delete-two-below-vertical-margin-active-background", 1, 3,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[2M",
                      (6, 6, 4, 5, 4), None))
    cases.append(Case("delete-line-below-vertical-margin-fills-physical-bottom", 1, 4,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[M",
                      (6, 6, 4, 5, 3), None))
    cases.append(Case("delete-line-two-rows-above-vertical-margin-fill-position", 1, 4,
                      b"\x1b[?69h\x1b[3;4r\x1b[40m\x1b[M",
                      (6, 6, 5, 3), None))
    cases.append(Case("delete-line-inside-margin-fill-offscreen", 1, 4,
                      b"\x1b[?69h\x1b[1;3r\x1b[3H\x1b[40m\x1b[M",
                      (6, 6, 4, 5, 3), None))
    cases.append(Case("delete-line-inside-margin-fill-shifted", 1, 5,
                      b"\x1b[?69h\x1b[1;3r\x1b[3H\x1b[40m\x1b[M",
                      (6, 6, 4, 5, 3), None))
    cases.append(Case("delete-two-inside-margin-fill-truncated", 1, 5,
                      b"\x1b[?69h\x1b[1;3r\x1b[3H\x1b[40m\x1b[2M",
                      (6, 6, 4, 5, 4), None))
    cases.append(Case("delete-line-below-margin-fill-offscreen", 1, 3,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[M",
                      (6, 6, 4, 5, 3), None))
    cases.append(Case("delete-line-below-margin-fill-shifted", 1, 5,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[M",
                      (6, 6, 4, 5, 3), None))
    cases.append(Case("delete-three-below-margin-fill-shifted-and-longer", 1, 6,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[3M",
                      (6, 6, 4, 5, 4), None))
    cases.append(Case("delete-three-below-margin-fill-overextended", 1, 5,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[3M",
                      (6, 6, 4, 5, 4), None))
    cases.append(Case("delete-two-then-delete-line-height-three-retains-background", 1, 3,
                      b"\x1b[?69h\n\x1b[40m\x1b[2M\x1b[M",
                      (6, 1, 5, 4, 3), None))
    cases.append(Case("repeated-delete-below-margin-reference-only", 1, 3,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[M\x1b[M",
                      (6, 6, 4, 5, 3, 3), None))
    cases.append(Case("repeated-delete-below-margin-candidate-subset", 1, 5,
                      b"\x1b[?69h\x1b[1;3r\x1b[4H\x1b[40m\x1b[M\x1b[2M",
                      (6, 6, 4, 5, 3, 4), None))
    cases.append(Case("repeated-delete-inside-full-region-candidate-only", 1, 3,
                      b"\x1b[?69h\x1b[3H\x1b[40m\x1b[M\x1b[M",
                      (6, 4, 5, 3, 3), None))
    cases.append(Case("repeated-delete-inside-full-region-candidate-superset", 1, 4,
                      b"\x1b[?69h\x1b[3H\x1b[40m\x1b[M\x1b[2M",
                      (6, 4, 5, 3, 4), None))
    cases.append(Case("repeated-delete-inside-partial-region-shifted", 1, 4,
                      b"\x1b[?69h\x1b[1;3r\x1b[3H\x1b[40m\x1b[M\x1b[M",
                      (6, 6, 4, 5, 3, 3), None))
    cases.append(Case("repeated-delete-inside-full-region-reference-only", 1, 4,
                      b"\x1b[?69h\x1b[3H\x1b[40m\x1b[3M\x1b[2M",
                      (6, 4, 5, 4, 4), None))
    cases.append(Case("repeated-delete-inside-partial-region-shifted-and-longer", 1, 6,
                      b"\x1b[?69h\x1b[1;5r\x1b[4H\x1b[40m\x1b[M\x1b[2M",
                      (6, 6, 4, 5, 3, 4), None))
    cases.append(Case("repeated-delete-after-cup-anchor-change-retains-background", 1, 3,
                      b"\x1b[?69h\x1b[2H\x1b[40m\x1b[M\x1b[3H\x1b[M",
                      (6, 4, 5, 3, 4, 3), None))
    cases.append(Case("relocated-delete-down-below-candidate-subset", 1, 4,
                      b"\x1b[?69h\x1b[1;3r\x1b[3H\x1b[40m\x1b[3M\x1b[4H\x1b[M",
                      (6, 6, 4, 5, 4, 4, 3), None))
    cases.append(Case("relocated-delete-down-below-reference-only", 1, 4,
                      b"\x1b[?69h\x1b[1;3r\x1b[3H\x1b[40m\x1b[M\x1b[4H\x1b[M",
                      (6, 6, 4, 5, 3, 4, 3), None))
    cases.append(Case("relocated-delete-down-inside-candidate-only", 1, 5,
                      b"\x1b[?69h\x1b[1;4r\x1b[2H\x1b[40m\x1b[M\x1b[4H\x1b[2M",
                      (6, 6, 4, 5, 3, 4, 4), None))
    cases.append(Case("relocated-delete-down-inside-candidate-subset", 1, 3,
                      b"\x1b[?69h\x1b[2H\x1b[40m\x1b[3M\x1b[3H\x1b[M",
                      (6, 4, 5, 4, 4, 3), None))
    cases.append(Case("relocated-delete-down-inside-candidate-superset", 1, 5,
                      b"\x1b[?69h\x1b[1;4r\x1b[2H\x1b[40m\x1b[3M\x1b[4H\x1b[2M",
                      (6, 6, 4, 5, 4, 4, 4), None))
    cases.append(Case("relocated-delete-down-inside-shifted-length", 1, 6,
                      b"\x1b[?69h\x1b[1;5r\x1b[3H\x1b[40m\x1b[2M\x1b[4H\x1b[2M",
                      (6, 6, 4, 5, 4, 4, 4), None))
    cases.append(Case("relocated-delete-down-inside-shifted", 1, 4,
                      b"\x1b[?69h\x1b[1;3r\x1b[2H\x1b[40m\x1b[M\x1b[3H\x1b[M",
                      (6, 6, 4, 5, 3, 4, 3), None))
    cases.append(Case("relocated-delete-up-above-candidate-subset", 1, 3,
                      b"\x1b[?69h\x1b[2;3r\x1b[2H\x1b[40m\x1b[M\x1b[H\x1b[M",
                      (6, 6, 4, 5, 3, 3, 3), None))
    cases.append(Case("relocated-delete-up-above-shifted-length", 1, 5,
                      b"\x1b[?69h\x1b[4;5r\x1b[4H\x1b[40m\x1b[2M\x1b[H\x1b[2M",
                      (6, 6, 4, 5, 4, 3, 4), None))
    cases.append(Case("relocated-delete-up-above-shifted", 1, 4,
                      b"\x1b[?69h\x1b[3;4r\x1b[3H\x1b[40m\x1b[M\x1b[H\x1b[M",
                      (6, 6, 4, 5, 3, 3, 3), None))
    cases.append(Case("relocated-delete-up-below-candidate-subset", 1, 5,
                      b"\x1b[?69h\x1b[1;2r\x1b[4H\x1b[40m\x1b[M\x1b[3H\x1b[M",
                      (6, 6, 4, 5, 3, 4, 3), None))
    cases.append(Case("relocated-delete-up-below-reference-only", 1, 5,
                      b"\x1b[?69h\x1b[1;3r\x1b[5H\x1b[40m\x1b[2M\x1b[4H\x1b[M",
                      (6, 6, 4, 5, 4, 4, 3), None))
    cases.append(Case("relocated-delete-up-below-shifted", 1, 6,
                      b"\x1b[?69h\x1b[1;2r\x1b[5H\x1b[40m\x1b[M\x1b[3H\x1b[M",
                      (6, 6, 4, 5, 3, 4, 3), None))
    cases.append(Case("relocated-delete-up-inside-candidate-subset", 1, 3,
                      b"\x1b[?69h\x1b[1;2r\x1b[3H\x1b[40m\x1b[2M\x1b[2H\x1b[M",
                      (6, 6, 4, 5, 4, 4, 3), None))
    cases.append(Case("relocated-delete-up-inside-reference-only", 1, 3,
                      b"\x1b[?69h\x1b[3H\x1b[40m\x1b[2M\x1b[2H\x1b[M",
                      (6, 4, 5, 4, 4, 3), None))
    dl_move_lf = b"\x1b[?69h\x1b[2H\x1b[40m\x1b[M\n\x1b[M"
    cases.append(Case("delete-anchor-lf-matches-cup-relocation", 1, 3,
                      dl_move_lf, (len(dl_move_lf),), None))
    dl_move_ind = b"\x1b[?69h\x1b[2H\x1b[40m\x1b[M\x1bD\x1b[M"
    cases.append(Case("delete-anchor-ind-matches-lf-relocation", 1, 3,
                      dl_move_ind, (len(dl_move_ind),), None))
    dl_boundary_lf = b"\x1b[?69h\x1b[3H\x1b[40m\x1b[M\n"
    cases.append(Case("lf-at-full-region-bottom-materializes-active-row", 1, 3,
                      dl_boundary_lf, (len(dl_boundary_lf),), None))
    cases.append(Case("delete-after-lf-bottom-generation-resets-virtual-tail", 1, 3,
                      dl_boundary_lf + b"\x1b[M", (len(dl_boundary_lf) + 3,), None))
    dl_boundary_ind = b"\x1b[?69h\x1b[2;4r\x1b[4H\x1b[40m\x1b[M\x1bD"
    cases.append(Case("ind-at-subregion-bottom-materializes-active-row", 1, 4,
                      dl_boundary_ind, (len(dl_boundary_ind),), None))
    cases.append(Case("delete-after-ind-subregion-scroll-resets-virtual-tail", 1, 4,
                      dl_boundary_ind + b"\x1b[M", (len(dl_boundary_ind) + 3,), None))
    dl_then_il_background = (b"\x1b[1;2r\x1b[?69h\x1b[2H\x1b[48:5:99m"
                             b"\x1b[M\x1b[48;2;4;8;16m\x1b[M\x1b[L")
    cases.append(Case("insert-line-restores-prior-delete-background-slot", 1, 3,
                      dl_then_il_background, (len(dl_then_il_background),), None))
    dl_clamped_then_il = (b"\x1b[1;2r\x1b[?69h\x1b[2H\x1b[48:5:99m"
                          b"\x1b[2M\x1b[48;2;4;8;16m\x1b[M\x1b[L")
    cases.append(Case("insert-line-restores-clamped-delete-background-slot", 1, 3,
                      dl_clamped_then_il, (len(dl_clamped_then_il),), None))
    il_clamped_background = (b"\x1b[1;3r\x1b[?69h\x1b[3H\x1b[48:5:99m"
                             b"\x1b[M\x1b[48;2;4;8;16m\x1b[M\x1b[3L")
    cases.append(Case("clamped-insert-line-fills-restored-delete-window", 1, 4,
                      il_clamped_background, (len(il_clamped_background),), None))
    dl_il_both_clamped = (b"\x1b[1;3r\x1b[?69h\x1b[3H\x1b[48:5:99m"
                          b"\x1b[3M\x1b[48;2;4;8;16m\x1b[M\x1b[3L")
    cases.append(Case("clamped-insert-after-clamped-delete-fills-window", 1, 4,
                      dl_il_both_clamped, (len(dl_il_both_clamped),), None))
    il_above_margin = (b"\x1b[2;3r\x1b[?69h\x1b[H\x1b[48:5:99m"
                       b"\x1b[M\x1b[48;2;4;8;16m\x1b[M\x1b[L")
    cases.append(Case("insert-line-above-vertical-margin-is-noop", 1, 3,
                      il_above_margin, (len(il_above_margin),), None))
    il_below_margin = (b"\x1b[1;2r\x1b[?69h\x1b[3H\x1b[48:5:99m"
                       b"\x1b[M\x1b[48;2;4;8;16m\x1b[M\x1b[L")
    cases.append(Case("insert-line-below-vertical-margin-is-noop", 1, 3,
                      il_below_margin, (len(il_below_margin),), None))
    il_moves_content_offscreen = b"\x1b[1;2r\x1b[?69h\x1b[2Ha\x1b[L"
    cases.append(Case("insert-line-moves-content-into-physical-row-below-margin", 2, 3,
                      il_moves_content_offscreen, (len(il_moves_content_offscreen),), None))
    il_overwrites_tail_content = b"\x1b[1;2r\x1b[?69h\x1b[3Ha\x1b[2H\x1b[L"
    cases.append(Case("insert-line-overwrites-tail-content", 2, 3,
                      il_overwrites_tail_content,
                      (len(il_overwrites_tail_content),), None))
    il_clamped_overwrites_content = (b"\x1b[1;2r\x1b[?69h\x1b[3Ha"
                                     b"\x1b[2H\x1b[2L")
    cases.append(Case("clamped-insert-line-overwrites-window-content", 2, 3,
                      il_clamped_overwrites_content,
                      (len(il_clamped_overwrites_content),), None))
    il_shifts_content_beyond_screen = b"\x1b[1;3r\x1b[?69h\x1b[4Ha\x1b[3H\x1b[L"
    cases.append(Case("insert-line-shifts-content-beyond-physical-screen", 2, 4,
                      il_shifts_content_beyond_screen,
                      (len(il_shifts_content_beyond_screen),), None))
    cases.append(Case("insert-line-shifts-content-to-last-physical-row", 2, 5,
                      il_shifts_content_beyond_screen,
                      (len(il_shifts_content_beyond_screen),), None))
    ri_pending_beyond_right_margin = (b"\x1b[?69h\x1b[2;3r\x1b[2;2s"
                                      b"\x1b[2;2Ha\x1bM")
    cases.append(Case("ri-pending-beyond-right-margin-with-physical-room-is-noop", 3, 3,
                      ri_pending_beyond_right_margin,
                      (len(ri_pending_beyond_right_margin),), None))
    ri_pending_at_physical_edge = (b"\x1b[?69h\x1b[2;3r\x1b[2;3s"
                                   b"\x1b[2;2Hab\x1bM")
    cases.append(Case("ri-pending-at-physical-edge-scrolls-margin-content", 3, 3,
                      ri_pending_at_physical_edge,
                      (len(ri_pending_at_physical_edge),), None))
    ri_left_edge_single_margin_pending = (b"\x1b[?69h\x1b[1;2r\x1b[1;1s"
                                          b"\x1b[1;1Ha\x1bM")
    cases.append(Case("ri-pending-beyond-left-edge-single-margin-is-noop", 2, 2,
                      ri_left_edge_single_margin_pending,
                      (len(ri_left_edge_single_margin_pending),), None))
    ri_left_edge_single_margin_outside = (b"\x1b[?69h\x1b[1;2r\x1b[1;1s"
                                          b"\x1b[1;1Ha\x1b[1;2H\x1bM")
    cases.append(Case("ri-right-outside-left-edge-single-margin-is-noop", 2, 2,
                      ri_left_edge_single_margin_outside,
                      (len(ri_left_edge_single_margin_outside),), None))
    ri_right_edge_single_margin_outside = (b"\x1b[?69h\x1b[1;2r\x1b[2;2s"
                                           b"\x1b[1;2Ha\x1b[1;1H\x1bM")
    cases.append(Case("ri-left-outside-right-edge-single-margin-is-noop", 2, 2,
                      ri_right_edge_single_margin_outside,
                      (len(ri_right_edge_single_margin_outside),), None))
    equal_left_edge_margin = b"\x1b[?69h\x1b[1;1sAB"
    cases.append(Case("equal-left-edge-horizontal-margin-is-accepted", 2, 2,
                      equal_left_edge_margin, (len(equal_left_edge_margin),), None))
    equal_right_edge_margin = b"\x1b[?69h\x1b[2;2s\x1b[1;2HAB"
    cases.append(Case("equal-right-edge-horizontal-margin-is-accepted", 2, 2,
                      equal_right_edge_margin, (len(equal_right_edge_margin),), None))
    equal_margin_physical_pending = b"\x1b[?69h\x1b[1;3HX\x1b[2;2s"
    cases.append(Case("equal-margin-preserves-physical-edge-pending-cursor", 3, 2,
                      equal_margin_physical_pending,
                      (len(equal_margin_physical_pending),), None))
    equal_margin_custom_pending = (b"\x1b[?69h\x1b[1;3s\x1b[1;3HX"
                                   b"\x1b[2;2s")
    cases.append(Case("equal-margin-preserves-custom-edge-pending-cursor", 4, 2,
                      equal_margin_custom_pending,
                      (len(equal_margin_custom_pending),), None))
    irm_zwj_cluster = b"\x1b[4h" + "\U0001f469\u200d\U0001f4bb".encode()
    cases.append(Case("irm-composes-wide-zwj-cluster", 4, 2,
                      irm_zwj_cluster, (len(irm_zwj_cluster),), None))
    cases.append(Case("irm-composes-wide-zwj-cluster-at-screen-width", 2, 2,
                      irm_zwj_cluster, (len(irm_zwj_cluster),), None))
    irm_two_column_rocket = ("\U0001f680".encode() +
                             b"\x1b[?69h\x1b[1;2s\x1b[4h\x1b[HX")
    cases.append(Case("irm-retains-rocket-shifted-past-two-column-margin", 3, 2,
                      irm_two_column_rocket, (len(irm_two_column_rocket),), None))
    irm_two_column_cjk = ("\u65e5".encode() +
                          b"\x1b[?69h\x1b[1;2s\x1b[4h\x1b[HX")
    cases.append(Case("irm-retains-cjk-shifted-past-two-column-margin", 3, 2,
                      irm_two_column_cjk, (len(irm_two_column_cjk),), None))
    irm_single_column_rocket = ("\U0001f680".encode() +
                                b"\x1b[?69h\x1b[2;2s\x1b[4h\x1b[HX")
    cases.append(Case("irm-vacates-rocket-continuation-past-single-column-margin", 3, 2,
                      irm_single_column_rocket,
                      (len(irm_single_column_rocket),), None))
    irm_single_column_cjk = ("\u65e5".encode() +
                             b"\x1b[?69h\x1b[2;2s\x1b[4h\x1b[HX")
    cases.append(Case("irm-vacates-cjk-continuation-past-single-column-margin", 3, 2,
                      irm_single_column_cjk, (len(irm_single_column_cjk),), None))
    cases.append(Case("irm-retains-rocket-shifted-past-margin-with-physical-room", 4, 2,
                      irm_two_column_rocket, (len(irm_two_column_rocket),), None))
    cases.append(Case("irm-retains-cjk-shifted-past-margin-with-physical-room", 4, 2,
                      irm_two_column_cjk, (len(irm_two_column_cjk),), None))
    cases.append(Case("irm-vacates-rocket-continuation-past-single-margin-with-physical-room", 4, 2,
                      irm_single_column_rocket,
                      (len(irm_single_column_rocket),), None))
    cases.append(Case("irm-vacates-cjk-continuation-past-single-margin-with-physical-room", 4, 2,
                      irm_single_column_cjk, (len(irm_single_column_cjk),), None))
    irm_preserve_beyond_right = ("\u65e5 0".encode() +
                                 b"\x1b[?69h\x1b[2;3s\x1b[4h\x1b[HX")
    cases.append(Case("irm-preserves-marker-beyond-right-margin", 4, 1,
                      irm_preserve_beyond_right,
                      (len(irm_preserve_beyond_right),), None))
    irm_drop_at_right = ("\u65e50".encode() +
                         b"\x1b[?69h\x1b[2;3s\x1b[4h\x1b[HX")
    cases.append(Case("irm-drops-marker-at-right-margin", 4, 1,
                      irm_drop_at_right, (len(irm_drop_at_right),), None))
    irm_preserve_crossed_neighbor = ("\u65e5 0".encode() +
                                     b"\x1b[?69h\x1b[1;2s\x1b[4h\x1b[HX")
    cases.append(Case("irm-preserves-populated-neighbor-past-wide-margin-edge", 4, 1,
                      irm_preserve_crossed_neighbor,
                      (len(irm_preserve_crossed_neighbor),), None))
    irm_preserve_single_neighbor = ("\u65e5 0".encode() +
                                    b"\x1b[?69h\x1b[2;2s\x1b[4h\x1b[HX")
    cases.append(Case("irm-single-margin-preserves-populated-physical-neighbor", 4, 1,
                      irm_preserve_single_neighbor,
                      (len(irm_preserve_single_neighbor),), None))
    rejected_wide_zwj = b"\x1b[?7la\t\x1bD" + "\u65e5\u200d".encode()
    cases.append(Case("zwj-after-rejected-wide-retains-prior-cell", 1, 2,
                      rejected_wide_zwj, (len(rejected_wide_zwj),), None))
    nowrap_zwj_narrow = b"\x1b[?7l" + "\u65e5\u200da".encode()
    cases.append(Case("nowrap-zwj-narrow-follower-replaces-continuation", 2, 2,
                      nowrap_zwj_narrow, (len(nowrap_zwj_narrow),), None))
    nowrap_cjk_zwj_cjk = b"\x1b[?7l" + "\u65e5\u200d\u65e5".encode()
    cases.append(Case("nowrap-cjk-zwj-cjk-follower-prints-separately", 4, 2,
                      nowrap_cjk_zwj_cjk, (len(nowrap_cjk_zwj_cjk),), None))
    nowrap_cjk_zwj_emoji = b"\x1b[?7l" + "\u65e5\u200d\U0001f680".encode()
    cases.append(Case("nowrap-cjk-zwj-emoji-follower-prints-separately", 4, 2,
                      nowrap_cjk_zwj_emoji, (len(nowrap_cjk_zwj_emoji),), None))
    nowrap_emoji_zwj_cjk = b"\x1b[?7l" + "\U0001f680\u200d\u65e5".encode()
    cases.append(Case("nowrap-emoji-zwj-cjk-follower-prints-separately", 4, 2,
                      nowrap_emoji_zwj_cjk, (len(nowrap_emoji_zwj_cjk),), None))
    nowrap_emoji_zwj_emoji = (b"\x1b[?7l" +
                              "\U0001f469\u200d\U0001f4bb".encode())
    cases.append(Case("nowrap-emoji-zwj-emoji-follower-composes", 4, 2,
                      nowrap_emoji_zwj_emoji,
                      (len(nowrap_emoji_zwj_emoji),), None))
    decfi_tail_continuation = (b"\x1b[?7l" + "\u65e5\u65e5".encode() +
                               b"\x1b[HxaA\x1b9" + "\u65e5\u200d".encode())
    cases.append(Case("decfi-continuation-tail-clears-last-write", 4, 1,
                      decfi_tail_continuation,
                      (len(decfi_tail_continuation),), None))
    decfi_tail_narrow = (b"\x1b[?7l" + "\u65e5aa".encode() +
                         b"\x1b[HxaA\x1b9" + "\u65e5\u200d".encode())
    cases.append(Case("decfi-narrow-tail-becomes-last-write", 4, 1,
                      decfi_tail_narrow, (len(decfi_tail_narrow),), None))
    decfi_tail_blank = (b"\x1b[?7l" + "\u65e5".encode() +
                        b"\x1b[HxaA\x1b9" + "\u65e5\u200d".encode())
    cases.append(Case("decfi-blank-tail-clears-last-write", 4, 1,
                      decfi_tail_blank, (len(decfi_tail_blank),), None))
    decfi_current_tail = (b"\x1b[?7l\x1b[IA\x1b[I\x1b9" +
                          "\u65e5\u200d".encode())
    cases.append(Case("decfi-shifted-current-last-write-is-invalidated", 2, 1,
                      decfi_current_tail, (len(decfi_current_tail),), None))
    decfi_stale_tail = (b"\x1b[?7l\x1b[IA\x1b[HX\x1b[I\x1b9" +
                        "\u65e5\u200d".encode())
    cases.append(Case("decfi-shifted-stale-tail-becomes-last-write", 2, 1,
                      decfi_stale_tail, (len(decfi_stale_tail),), None))
    decfi_stale_tail_after_gap = (b"\x1b[?7l\x1b[IA\ra\x1b[I\x1b9" +
                                  "\u65e5\u200d".encode())
    cases.append(Case("decfi-stale-tail-after-gap-invalidates-last-write", 3, 1,
                      decfi_stale_tail_after_gap,
                      (len(decfi_stale_tail_after_gap),), None))
    decfi_stale_tail_contiguous = (b"\x1b[?7l\x1b[IA\rab\x1b[I\x1b9" +
                                   "\u65e5\u200d".encode())
    cases.append(Case("decfi-contiguous-stale-tail-becomes-last-write", 3, 1,
                      decfi_stale_tail_contiguous,
                      (len(decfi_stale_tail_contiguous),), None))
    emoji_zwj_bare_heart = "\U0001f680\u200d\u2764".encode()
    cases.append(Case("emoji-zwj-bare-heart-composes", 4, 2,
                      emoji_zwj_bare_heart,
                      (len(emoji_zwj_bare_heart),), None))
    emoji_zwj_heart_vs15 = "\U0001f680\u200d\u2764\ufe0e".encode()
    cases.append(Case("emoji-zwj-heart-vs15-composes-at-text-width", 4, 2,
                      emoji_zwj_heart_vs15,
                      (len(emoji_zwj_heart_vs15),), None))
    emoji_zwj_heart_vs16 = "\U0001f680\u200d\u2764\ufe0f".encode()
    cases.append(Case("emoji-zwj-heart-vs16-composes-at-emoji-width", 4, 2,
                      emoji_zwj_heart_vs16,
                      (len(emoji_zwj_heart_vs16),), None))
    emoji_zwj_plane_vs16 = "\U0001f680\u200d\u2708\ufe0f".encode()
    cases.append(Case("emoji-zwj-plane-vs16-composes", 4, 2,
                      emoji_zwj_plane_vs16,
                      (len(emoji_zwj_plane_vs16),), None))
    vs16_emoji_lead_and_follower = "\u2764\ufe0f\u200d\u2764\ufe0f".encode()
    cases.append(Case("vs16-emoji-lead-and-follower-compose", 4, 2,
                      vs16_emoji_lead_and_follower,
                      (len(vs16_emoji_lead_and_follower),), None))
    vs15_lead_vs16_follower = "\u2764\ufe0e\u200d\u2764\ufe0f".encode()
    cases.append(Case("vs15-lead-with-vs16-follower-upgrades-composed-width", 4, 2,
                      vs15_lead_vs16_follower,
                      (len(vs15_lead_vs16_follower),), None))
    cjk_zwj_heart_vs16 = "\u65e5\u200d\u2764\ufe0f".encode()
    cases.append(Case("cjk-zwj-heart-vs16-prints-separately", 4, 2,
                      cjk_zwj_heart_vs16,
                      (len(cjk_zwj_heart_vs16),), None))
    emoji_zwj_keycap = "\U0001f680\u200d1\ufe0f\u20e3".encode()
    cases.append(Case("emoji-zwj-keycap-prints-separately", 6, 2,
                      emoji_zwj_keycap,
                      (len(emoji_zwj_keycap),), None))
    text_emoji_lead_wide_follower = "\u2764\u200d\U0001f680".encode()
    cases.append(Case("text-width-emoji-lead-composes-wide-follower-at-lead-width", 4, 2,
                      text_emoji_lead_wide_follower,
                      (len(text_emoji_lead_wide_follower),), None))
    cases.append(Case("one-column-emoji-zwj-vs15-clears-wrap-pending", 1, 2,
                      emoji_zwj_heart_vs15,
                      (len(emoji_zwj_heart_vs15),), None))
    decbi_hidden_margin_origin = b"\x1b[?69h\x1b[2;2s\x1b[?69l\x1b6"
    cases.append(Case("decbi-after-declrmm-off-retains-hidden-left-margin", 2, 1,
                      decbi_hidden_margin_origin,
                      (len(decbi_hidden_margin_origin),), None))
    decbi_hidden_margin_left_edge = (b"\x1b[?69h\x1b[2;2s\x1b[1;2H"
                                     b"\x1b[?69l\x1b6")
    cases.append(Case("decbi-after-declrmm-off-inserts-at-hidden-left-edge", 2, 1,
                      decbi_hidden_margin_left_edge,
                      (len(decbi_hidden_margin_left_edge),), None))
    decbi_enabled_margin_origin = b"\x1b[?69h\x1b[2;2s\x1b6"
    cases.append(Case("decbi-with-declrmm-on-noops-outside-left-margin", 2, 1,
                      decbi_enabled_margin_origin,
                      (len(decbi_enabled_margin_origin),), None))
    decbi_hidden_physical_left = b"\x1b[?69h\x1b[1;1s\x1b[?69l\x1b6"
    cases.append(Case("decbi-hidden-physical-left-margin-inserts-space", 2, 1,
                      decbi_hidden_physical_left,
                      (len(decbi_hidden_physical_left),), None))
    decbi_hidden_margin_exterior = (b"\x1b[?69h\x1b[3;3s\x1b[1;2H"
                                    b"\x1b[?69l\x1b6")
    cases.append(Case("decbi-after-declrmm-off-moves-through-hidden-left-exterior", 3, 1,
                      decbi_hidden_margin_exterior,
                      (len(decbi_hidden_margin_exterior),), None))
    irm_declrmm_flag_at_screen_edge = (b"\x1b[4h\x1b[?69h" +
                                       "\U0001f1fa\U0001f1f8".encode() + b"\r ")
    cases.append(Case("irm-declrmm-drops-flag-shifted-past-screen-edge", 2, 2,
                      irm_declrmm_flag_at_screen_edge,
                      (len(irm_declrmm_flag_at_screen_edge),), None))
    irm_declrmm_cjk_at_screen_edge = (b"\x1b[4h\x1b[?69h" +
                                      "\u65e5".encode() + b"\r ")
    cases.append(Case("irm-declrmm-drops-cjk-shifted-past-screen-edge", 2, 2,
                      irm_declrmm_cjk_at_screen_edge,
                      (len(irm_declrmm_cjk_at_screen_edge),), None))
    irm_custom_right_edge = (b"\x1b[4h\x1b[?69h\x1b[3;4s\x1b[1;3H" +
                             "\U0001f680".encode() + b"\r ")
    cases.append(Case("irm-drops-wide-shifted-past-custom-right-screen-edge", 4, 2,
                      irm_custom_right_edge,
                      (len(irm_custom_right_edge),), None))
    irm_custom_with_room = (b"\x1b[4h\x1b[?69h\x1b[2;3s\x1b[1;2H" +
                            "\U0001f680".encode() + b"\r ")
    cases.append(Case("irm-retains-wide-shifted-past-internal-right-margin", 4, 2,
                      irm_custom_with_room,
                      (len(irm_custom_with_room),), None))
    irm_without_declrmm = b"\x1b[4h" + "\U0001f680".encode() + b"\r "
    cases.append(Case("irm-without-declrmm-drops-wide-at-screen-edge", 2, 2,
                      irm_without_declrmm,
                      (len(irm_without_declrmm),), None))
    irm_shift_two_wide = (b"\x1b[4h\x1b[?69h" +
                          "\U0001f1fa\U0001f1f8".encode() + b"\r" +
                          "\U0001f680".encode())
    cases.append(Case("irm-declrmm-drops-wide-after-two-column-wide-insert", 3, 2,
                      irm_shift_two_wide,
                      (len(irm_shift_two_wide),), None))
    irm_shift_two_narrow = (b"\x1b[4h\x1b[?69h" +
                            "\u65e5".encode() + b"\rAA")
    cases.append(Case("irm-declrmm-drops-wide-after-two-narrow-inserts", 3, 2,
                      irm_shift_two_narrow,
                      (len(irm_shift_two_narrow),), None))
    irm_shift_three_mixed = (b"\x1b[4h\x1b[?69h" +
                             "\U0001f469\u200d\U0001f4bb".encode() + b"\r" +
                             "\U0001f680".encode() + b"A")
    cases.append(Case("irm-declrmm-drops-wide-after-three-column-mixed-insert", 4, 2,
                      irm_shift_three_mixed,
                      (len(irm_shift_three_mixed),), None))
    irm_shift_four_wide = (b"\x1b[4h\x1b[?69h" +
                           "\u2764\ufe0f".encode() + b"\r" +
                           "\U0001f680\U0001f680".encode())
    cases.append(Case("irm-declrmm-drops-wide-after-four-column-insert", 5, 2,
                      irm_shift_four_wide,
                      (len(irm_shift_four_wide),), None))
    irm_custom_shift_two = (b"\x1b[4h\x1b[?69h\x1b[3;5s\x1b[1;3H" +
                            "1\ufe0f\u20e3".encode() + b"\r" +
                            "\U0001f680".encode())
    cases.append(Case("irm-custom-right-edge-drops-wide-after-wide-insert", 5, 2,
                      irm_custom_shift_two,
                      (len(irm_custom_shift_two),), None))
    irm_internal_shift_two = (b"\x1b[4h\x1b[?69h\x1b[3;5s\x1b[1;3H" +
                              "\U0001f1fa\U0001f1f8".encode() + b"\r" +
                              "\U0001f680".encode())
    cases.append(Case("irm-internal-margin-retains-wide-after-wide-insert", 6, 2,
                      irm_internal_shift_two,
                      (len(irm_internal_shift_two),), None))
    dl_pending_single_margin = b"\x1b[?69h\x1b[1;1sA\x1b[M"
    cases.append(Case("dl-noops-at-pending-single-column-custom-margin", 2, 2,
                      dl_pending_single_margin,
                      (len(dl_pending_single_margin),), None))
    dl_pending_middle_count = (b"\x1b[?69h\x1b[2;3s\x1b[2;2H"
                               b"AB\x1b[3M")
    cases.append(Case("dl-count-noops-at-pending-custom-margin-middle-row", 4, 3,
                      dl_pending_middle_count,
                      (len(dl_pending_middle_count),), None))
    dl_pending_bottom_count = (b"\x1b[?69h\x1b[2;3s\x1b[3;2H"
                               b"AB\x1b[2M")
    cases.append(Case("dl-count-noops-at-pending-custom-margin-bottom-row", 4, 3,
                      dl_pending_bottom_count,
                      (len(dl_pending_bottom_count),), None))
    dl_pending_full_width = b"\x1b[?69h\x1b[1;2sAB\x1b[M"
    cases.append(Case("dl-executes-at-pending-explicit-full-width-margin", 2, 2,
                      dl_pending_full_width,
                      (len(dl_pending_full_width),), None))
    dl_nonpending_custom = b"\x1b[?69h\x1b[1;2sA\x1b[M"
    cases.append(Case("dl-executes-at-nonpending-custom-margin", 3, 2,
                      dl_nonpending_custom,
                      (len(dl_nonpending_custom),), None))
    dl_pending_after_il_metadata = (b"\x1b[?69h\x1b[2;9s\x1b[2;8H"
                                    b"\x1b[48:2::3:4m\x1b[2L0" +
                                    "A\u0301".encode() + b"\x1b[2M")
    cases.append(Case("dl-pending-noop-retains-il-content-and-background", 16, 6,
                      dl_pending_after_il_metadata,
                      (len(dl_pending_after_il_metadata),), None))
    dl_pending_equal_physical_edge = (b"\x1b[?69h\x1b[2;2s\x1b[1;2H"
                                      b"A\x1b[M")
    cases.append(Case("dl-executes-at-pending-equal-physical-right-margin", 2, 2,
                      dl_pending_equal_physical_edge,
                      (len(dl_pending_equal_physical_edge),), None))
    dl_pending_custom_physical_edge = (b"\x1b[?69h\x1b[2;3s\x1b[1;2H"
                                       b"AB\x1b[M")
    cases.append(Case("dl-executes-at-pending-custom-physical-right-margin", 3, 2,
                      dl_pending_custom_physical_edge,
                      (len(dl_pending_custom_physical_edge),), None))
    dl_pending_equal_internal_edge = (b"\x1b[?69h\x1b[2;2s\x1b[1;2H"
                                      b"A\x1b[M")
    cases.append(Case("dl-noops-at-pending-equal-internal-right-margin", 3, 2,
                      dl_pending_equal_internal_edge,
                      (len(dl_pending_equal_internal_edge),), None))
    dl_nowrap_parked_equal_internal = (b"\x1b[?69h\x1b[1;1s"
                                       b"\x1b[?7lA\x1b[M")
    cases.append(Case("dl-noops-after-nowrap-parks-beyond-equal-internal-margin", 2, 1,
                      dl_nowrap_parked_equal_internal,
                      (len(dl_nowrap_parked_equal_internal),), None))
    dl_nowrap_parked_custom_internal = (b"\x1b[?69h\x1b[1;2s"
                                        b"\x1b[?7lAB\x1b[M")
    cases.append(Case("dl-noops-after-nowrap-parks-beyond-custom-internal-margin", 3, 1,
                      dl_nowrap_parked_custom_internal,
                      (len(dl_nowrap_parked_custom_internal),), None))
    dl_nowrap_parked_physical_edge = (b"\x1b[?69h\x1b[2;2s\x1b[1;2H"
                                      b"\x1b[?7lA\x1b[M")
    cases.append(Case("dl-executes-after-nowrap-parks-at-physical-right-margin", 2, 1,
                      dl_nowrap_parked_physical_edge,
                      (len(dl_nowrap_parked_physical_edge),), None))
    dl_cup_outside_internal_margin = (b"\x1b[?69h\x1b[1;1s"
                                      b"\x1b[1;2H\x1b[M")
    cases.append(Case("dl-noops-after-cup-outside-internal-right-margin", 2, 1,
                      dl_cup_outside_internal_margin,
                      (len(dl_cup_outside_internal_margin),), None))
    dl_nowrap_parked_after_sgr = (b"\x1b[?69h\x1b[1;1s\x1b[?7l"
                                  b"A\x1b[31m\x1b[M")
    cases.append(Case("dl-nowrap-parked-state-survives-sgr", 2, 1,
                      dl_nowrap_parked_after_sgr,
                      (len(dl_nowrap_parked_after_sgr),), None))
    dl_nowrap_parked_after_il = (b"\x1b[?69h\x1b[1;1s\x1b[?7l"
                                 b"A\x1b[L\x1b[M")
    cases.append(Case("dl-nowrap-parked-state-survives-il", 2, 2,
                      dl_nowrap_parked_after_il,
                      (len(dl_nowrap_parked_after_il),), None))
    dl_nowrap_parked_reset_by_cup = (b"\x1b[?69h\x1b[1;1s\x1b[?7l"
                                     b"A\x1b[1;1H\x1b[M")
    cases.append(Case("dl-nowrap-parked-state-resets-after-cup-inside-margin", 2, 1,
                      dl_nowrap_parked_reset_by_cup,
                      (len(dl_nowrap_parked_reset_by_cup),), None))
    dl_prior_pending_after_narrow_margin = (b"\x1b[1;2HA\x1b[?69h"
                                            b"\x1b[1;1s\x1b[M")
    cases.append(Case("dl-clamps-prior-physical-edge-pending-after-margin-narrows", 2, 1,
                      dl_prior_pending_after_narrow_margin,
                      (len(dl_prior_pending_after_narrow_margin),), None))
    prior_pending_after_narrow_margin = b"\x1b[1;2HA\x1b[?69h\x1b[1;1s"
    cases.append(Case("margin-narrowing-alone-preserves-prior-pending-cursor", 2, 1,
                      prior_pending_after_narrow_margin,
                      (len(prior_pending_after_narrow_margin),), None))
    dl_prior_nowrap_after_narrow_margin = (b"\x1b[1;2H\x1b[?7lA"
                                           b"\x1b[?69h\x1b[1;1s\x1b[M")
    cases.append(Case("dl-after-nowrap-physical-edge-and-margin-narrows", 2, 1,
                      dl_prior_nowrap_after_narrow_margin,
                      (len(dl_prior_nowrap_after_narrow_margin),), None))
    dl_prior_settled_after_narrow_margin = (b"\x1b[1;2H\x1b[?69h"
                                            b"\x1b[1;1s\x1b[M")
    cases.append(Case("dl-after-settled-physical-edge-and-margin-narrows", 2, 1,
                      dl_prior_settled_after_narrow_margin,
                      (len(dl_prior_settled_after_narrow_margin),), None))
    dl_prior_pending_full_right_margin = (b"\x1b[1;2HA\x1b[?69h"
                                           b"\x1b[1;2s\x1b[M")
    cases.append(Case("dl-executes-when-replacement-margin-keeps-physical-right", 2, 1,
                      dl_prior_pending_full_right_margin,
                      (len(dl_prior_pending_full_right_margin),), None))
    dl_tab_pending_after_narrow_margin = (b"\x1b[3g\tA\x1b[?69h"
                                          b"\x1b[1;1s\x1b[M")
    cases.append(Case("dl-clamps-tab-derived-physical-edge-pending-after-margin-narrows", 2, 1,
                      dl_tab_pending_after_narrow_margin,
                      (len(dl_tab_pending_after_narrow_margin),), None))
    dl_clamped_pending_then_print = dl_prior_pending_after_narrow_margin + b"B"
    cases.append(Case("dl-clamped-prior-pending-wraps-on-next-print", 2, 2,
                      dl_clamped_pending_then_print,
                      (len(dl_clamped_pending_then_print),), None))
    dl_clamped_pending_then_bs = dl_prior_pending_after_narrow_margin + b"\b"
    cases.append(Case("dl-clamped-prior-pending-normalizes-on-backspace", 2, 2,
                      dl_clamped_pending_then_bs,
                      (len(dl_clamped_pending_then_bs),), None))
    hidden_decfi_wide_narrow = (b"\x1b[?69h\x1b[2;3s\x1b[1;1H" +
                                "\u65e5".encode() + b"A\x1b[1;3H\x1b[?69l\x1b9")
    cases.append(Case("decfi-after-declrmm-off-moves-narrow-into-wide-continuation", 4, 2,
                      hidden_decfi_wide_narrow,
                      (len(hidden_decfi_wide_narrow),), None))
    hidden_decfi_wide_only = (b"\x1b[?69h\x1b[2;3s\x1b[1;1H" +
                              "\u65e5".encode() + b"\x1b[1;3H\x1b[?69l\x1b9")
    cases.append(Case("decfi-after-declrmm-off-vacates-wide-continuation", 4, 2,
                      hidden_decfi_wide_only,
                      (len(hidden_decfi_wide_only),), None))
    hidden_decfi_narrow_only = (b"\x1b[?69h\x1b[2;3s\x1b[1;1H"
                                b"A\x1b[1;3H\x1b[?69l\x1b9")
    cases.append(Case("decfi-after-declrmm-off-moves-cursor-with-narrow-source", 4, 2,
                      hidden_decfi_narrow_only,
                      (len(hidden_decfi_narrow_only),), None))
    enabled_decfi_wide_narrow = (b"\x1b[?69h\x1b[2;3s\x1b[1;1H" +
                                 "\u65e5".encode() + b"A\x1b[1;3H\x1b9")
    cases.append(Case("decfi-with-declrmm-on-wide-continuation-control", 4, 2,
                      enabled_decfi_wide_narrow,
                      (len(enabled_decfi_wide_narrow),), None))
    hidden_decfi_then_combining = hidden_decfi_wide_narrow + "\u0301".encode()
    cases.append(Case("decfi-relocated-narrow-does-not-become-last-write", 4, 2,
                      hidden_decfi_then_combining,
                      (len(hidden_decfi_then_combining),), None))
    hidden_decfi_repeated = hidden_decfi_wide_narrow + b"\x1b9"
    cases.append(Case("decfi-repeated-after-hidden-margin-wide-shift", 4, 2,
                      hidden_decfi_repeated,
                      (len(hidden_decfi_repeated),), None))
    hidden_decfi_right_of_margin = (b"\x1b[?69h\x1b[1;2s\x1b[1;1H" +
                                    "\u65e5".encode() + b"\x1b[1;3H\x1b[?69l\x1b9")
    cases.append(Case("decfi-right-of-hidden-margin-preserves-wide-cell", 3, 2,
                      hidden_decfi_right_of_margin,
                      (len(hidden_decfi_right_of_margin),), None))
    hidden_decfi_physical_right_external_lead = (b"\x1b[?69h\x1b[2;3s\x1b[1;1H" +
                                                 "\u65e5".encode() +
                                                 b"\x1b[1;3H\x1b[?69l\x1b9")
    cases.append(Case("decfi-physical-right-shift-preserves-wide-lead-outside-margin", 3, 2,
                      hidden_decfi_physical_right_external_lead,
                      (len(hidden_decfi_physical_right_external_lead),), None))
    hidden_decfi_full_width_control = (b"\x1b[?69h\x1b[1;3s\x1b[1;1H" +
                                       "\u65e5".encode() + b"\x1b[1;3H\x1b[?69l\x1b9")
    cases.append(Case("decfi-full-width-shift-wide-lead-control", 3, 2,
                      hidden_decfi_full_width_control,
                      (len(hidden_decfi_full_width_control),), None))
    hidden_decfi_left_of_margin_control = (b"\x1b[?69h\x1b[2;3s\x1b[1;1H" +
                                           "\u65e5".encode() +
                                           b"\x1b[1;1H\x1b[?69l\x1b9")
    cases.append(Case("decfi-left-of-hidden-margin-preserves-wide-cell", 3, 2,
                      hidden_decfi_left_of_margin_control,
                      (len(hidden_decfi_left_of_margin_control),), None))
    hidden_decfi_all_rows_wide_cleanup = (b"\x1b[?69h\x1b[1;1s\x1b[1;1H" +
                                          "\u65e5".encode() +
                                          b"\x1b[1;1H\x1b[?69l\x1b9")
    cases.append(Case("decfi-hidden-margin-shifts-all-rows-and-cleans-wide-pair", 3, 2,
                      hidden_decfi_all_rows_wide_cleanup,
                      (len(hidden_decfi_all_rows_wide_cleanup),), None))
    hidden_decfi_deletes_pair_filling_stored_margin = (b"\x1b[?69h\x1b[1;2s"
                                                       b"\x1b[1;1H" +
                                                       "\u65e5".encode() +
                                                       b"\x1b[1;2H\x1b[?69l\x1b9")
    cases.append(Case("decfi-hidden-margin-deletes-wide-pair-filling-region", 3, 2,
                      hidden_decfi_deletes_pair_filling_stored_margin,
                      (len(hidden_decfi_deletes_pair_filling_stored_margin),), None))
    vs16_after_wrap_from_right_of_margin = (b"\x1b[?69h\x1b[1;1s"
                                            b"\x1b[1;2H" +
                                            "\u2764\ufe0f".encode())
    cases.append(Case("vs16-after-base-wraps-from-right-of-active-margin", 2, 2,
                      vs16_after_wrap_from_right_of_margin,
                      (len(vs16_after_wrap_from_right_of_margin),), None))
    cases.append(Case("print-after-vs16-wrap-from-right-of-active-margin", 2, 2,
                      vs16_after_wrap_from_right_of_margin + b"A",
                      (len(vs16_after_wrap_from_right_of_margin) + 1,), None))
    vs15_after_wrap_from_right_of_margin = (b"\x1b[?69h\x1b[1;1s"
                                            b"\x1b[1;2H" +
                                            "\u2764\ufe0e".encode())
    cases.append(Case("vs15-after-base-wraps-from-right-of-active-margin-control", 2, 2,
                      vs15_after_wrap_from_right_of_margin,
                      (len(vs15_after_wrap_from_right_of_margin),), None))
    vs16_after_bottom_wrap_from_right_of_margin = (b"\x1b[?69h\x1b[1;1s"
                                                   b"\x1b[2;2H" +
                                                   "\u2764\ufe0f".encode())
    cases.append(Case("vs16-after-bottom-row-wrap-from-right-of-active-margin", 2, 2,
                      vs16_after_bottom_wrap_from_right_of_margin,
                      (len(vs16_after_bottom_wrap_from_right_of_margin),), None))
    cases.append(Case("vs16-after-one-row-wrap-from-right-of-margin-control", 2, 1,
                      vs16_after_wrap_from_right_of_margin,
                      (len(vs16_after_wrap_from_right_of_margin),), None))
    nowrap_vs16_right_of_margin = (b"\x1b[?69h\x1b[1;1s\x1b[?7l"
                                    b"\x1b[1;2H" + "\u2764\ufe0f".encode())
    cases.append(Case("vs16-after-nowrap-print-right-of-active-margin-control", 2, 2,
                      nowrap_vs16_right_of_margin,
                      (len(nowrap_vs16_right_of_margin),), None))
    ind_outside_hidden_margin_after_cup = (b"\x1b[?69h\x1b[1;1s"
                                           b"\x1b[?69l\x1b[1;2H\x1bD")
    cases.append(Case("ind-outside-hidden-right-margin-after-cup", 2, 1,
                      ind_outside_hidden_margin_after_cup,
                      (len(ind_outside_hidden_margin_after_cup),), None))
    ind_outside_active_margin_settled = b" \x1b[?69h\x1b[1;1s\x1bD"
    cases.append(Case("ind-outside-active-right-margin-preserves-settled-content", 2, 1,
                      ind_outside_active_margin_settled,
                      (len(ind_outside_active_margin_settled),), None))
    ind_outside_active_margin_pending = b"AB\x1b[?69h\x1b[1;1s\x1bD"
    cases.append(Case("ind-outside-active-right-margin-preserves-pending-content", 2, 1,
                      ind_outside_active_margin_pending,
                      (len(ind_outside_active_margin_pending),), None))
    ind_outside_active_margin_nowrap = (b"\x1b[?7lAB"
                                        b"\x1b[?69h\x1b[1;1s\x1bD")
    cases.append(Case("ind-outside-active-right-margin-preserves-nowrap-content", 2, 1,
                      ind_outside_active_margin_nowrap,
                      (len(ind_outside_active_margin_nowrap),), None))
    ind_outside_hidden_margin_pending = (b"AB\x1b[?69h\x1b[1;1s"
                                         b"\x1b[?69l\x1bD")
    cases.append(Case("ind-outside-hidden-right-margin-preserves-pending-state", 2, 1,
                      ind_outside_hidden_margin_pending,
                      (len(ind_outside_hidden_margin_pending),), None))
    ind_outside_hidden_margin_nowrap = (b"\x1b[?7lAB\x1b[?69h\x1b[1;1s"
                                        b"\x1b[?69l\x1bD")
    cases.append(Case("ind-outside-hidden-right-margin-preserves-nowrap-state", 2, 1,
                      ind_outside_hidden_margin_nowrap,
                      (len(ind_outside_hidden_margin_nowrap),), None))
    ind_advance_active_pending = b"AB\x1b[?69h\x1b[1;1s\x1bD"
    cases.append(Case("ind-above-bottom-active-margin-normalizes-physical-pending", 2, 2,
                      ind_advance_active_pending,
                      (len(ind_advance_active_pending),), None))
    ind_advance_hidden_pending = ind_advance_active_pending[:-2] + b"\x1b[?69l\x1bD"
    cases.append(Case("ind-above-bottom-hidden-margin-normalizes-physical-pending", 2, 2,
                      ind_advance_hidden_pending,
                      (len(ind_advance_hidden_pending),), None))
    ind_bottom_left_of_hidden_margin = (b"A\x1b[?69h\x1b[2;2s"
                                        b"\x1b[?69l\x1b[1;1H\x1bD")
    cases.append(Case("ind-at-bottom-left-of-hidden-margin-is-noop", 2, 1,
                      ind_bottom_left_of_hidden_margin,
                      (len(ind_bottom_left_of_hidden_margin),), None))
    ind_marker_rows_two = b"\x1b[1;1HAX\x1b[2;1HBY"
    ind_marker_rows_three = ind_marker_rows_two + b"\x1b[3;1HCZ"
    ind_below_left_of_hidden_margin = (ind_marker_rows_three +
                                       b"\x1b[1;2r\x1b[3;1H"
                                       b"\x1b[?69h\x1b[2;2s\x1b[?69l\x1bD")
    cases.append(Case("ind-below-bottom-left-of-hidden-margin-is-noop", 2, 3,
                      ind_below_left_of_hidden_margin,
                      (len(ind_below_left_of_hidden_margin),), None))
    ind_bottom_active_partial_scroll = (ind_marker_rows_two +
                                        b"\x1b[2;1H\x1b[?69h\x1b[1;1s\x1bD")
    cases.append(Case("ind-at-bottom-active-margin-scrolls-stored-columns", 2, 2,
                      ind_bottom_active_partial_scroll,
                      (len(ind_bottom_active_partial_scroll),), None))
    ind_bottom_hidden_full_scroll = (ind_marker_rows_two +
                                     b"\x1b[2;1H\x1b[?69h\x1b[1;1s"
                                     b"\x1b[?69l\x1bD")
    cases.append(Case("ind-at-bottom-hidden-margin-scrolls-full-rows", 2, 2,
                      ind_bottom_hidden_full_scroll,
                      (len(ind_bottom_hidden_full_scroll),), None))
    ind_bottom_active_full_scroll = (ind_marker_rows_two +
                                     b"\x1b[2;1H\x1b[?69h\x1b[1;2s\x1bD")
    cases.append(Case("ind-at-bottom-active-full-width-creates-scrollback", 2, 2,
                      ind_bottom_active_full_scroll,
                      (len(ind_bottom_active_full_scroll),), None))
    ind_below_active_partial_scroll = (ind_marker_rows_three +
                                       b"\x1b[1;2r\x1b[3;1H"
                                       b"\x1b[?69h\x1b[1;1s\x1bD")
    cases.append(Case("ind-below-bottom-active-margin-scrolls-stored-columns", 2, 3,
                      ind_below_active_partial_scroll,
                      (len(ind_below_active_partial_scroll),), None))
    ind_nontop_active_partial_scroll = (ind_marker_rows_three +
                                        b"\x1b[2;3r\x1b[3;1H"
                                        b"\x1b[?69h\x1b[1;1s\x1bD")
    cases.append(Case("ind-nontop-active-margin-scrolls-stored-columns-in-place", 2, 3,
                      ind_nontop_active_partial_scroll,
                      (len(ind_nontop_active_partial_scroll),), None))
    ind_nontop_hidden_full_scroll = (ind_marker_rows_three +
                                     b"\x1b[2;3r\x1b[3;1H"
                                     b"\x1b[?69h\x1b[1;1s\x1b[?69l\x1bD")
    cases.append(Case("ind-nontop-hidden-margin-scrolls-full-rows-in-place", 2, 3,
                      ind_nontop_hidden_full_scroll,
                      (len(ind_nontop_hidden_full_scroll),), None))
    clamped_horizontal_margin_cr = (b"\x1b[?69h\x1b[1;2H"
                                    b"\x1b[2;3s\r")
    cases.append(Case("cr-uses-clamped-horizontal-margin-request", 2, 1,
                      clamped_horizontal_margin_cr,
                      (len(clamped_horizontal_margin_cr),), None))
    both_overrange_horizontal_margins = (b"\x1b[?69h\x1b[1;4H"
                                         b"\x1b[5;6s\r")
    cases.append(Case("declrmm-clamps-both-overrange-horizontal-margins", 4, 2,
                      both_overrange_horizontal_margins,
                      (len(both_overrange_horizontal_margins),), None))
    reversed_horizontal_margins = (b"\x1b[?69h\x1b[1;4H"
                                   b"\x1b[4;2s\r")
    cases.append(Case("declrmm-orders-reversed-horizontal-margins", 4, 2,
                      reversed_horizontal_margins,
                      (len(reversed_horizontal_margins),), None))
    zero_horizontal_margins = b"\x1b[?69h\x1b[1;4H\x1b[0;0s\r"
    cases.append(Case("declrmm-zero-horizontal-margins-use-defaults", 4, 2,
                      zero_horizontal_margins,
                      (len(zero_horizontal_margins),), None))
    omitted_horizontal_margins = b"\x1b[?69h\x1b[1;4H\x1b[s\r"
    cases.append(Case("declrmm-omitted-horizontal-margins-use-defaults", 4, 2,
                      omitted_horizontal_margins,
                      (len(omitted_horizontal_margins),), None))
    equal_horizontal_margin = b"\x1b[?69h\x1b[1;4H\x1b[3;3s\r"
    cases.append(Case("declrmm-preserves-equal-horizontal-margin", 4, 2,
                      equal_horizontal_margin,
                      (len(equal_horizontal_margin),), None))
    pending_clamped_horizontal_margin = (b"\x1b[?69h\x1b[1;4HA"
                                         b"\x1b[3;6s\r")
    cases.append(Case("declrmm-clamped-margin-preserves-pending-setup", 4, 2,
                      pending_clamped_horizontal_margin,
                      (len(pending_clamped_horizontal_margin),), None))
    origin_clamped_horizontal_margin = (b"\x1b[?69h\x1b[?6h\x1b[1;4H"
                                        b"\x1b[3;6s\r")
    cases.append(Case("declrmm-clamped-margin-with-origin-mode", 4, 2,
                      origin_clamped_horizontal_margin,
                      (len(origin_clamped_horizontal_margin),), None))
    pending_print_clamped_horizontal_margin = (b"\x1b[?69h\x1b[1;4HA"
                                               b"\x1b[3;6sB")
    cases.append(Case("declrmm-clamped-margin-preserves-wrap-pending", 4, 2,
                      pending_print_clamped_horizontal_margin,
                      (len(pending_print_clamped_horizontal_margin),), None))
    unicode_after_cuf_pending = b"A\x1b[C" + "\u00e9".encode()
    cases.append(Case("unicode-narrow-after-cuf-from-wrap-pending", 1, 2,
                      unicode_after_cuf_pending,
                      (len(unicode_after_cuf_pending),), None))
    ascii_after_cuf_pending = b"A\x1b[CB"
    cases.append(Case("ascii-narrow-after-cuf-from-wrap-pending", 1, 2,
                      ascii_after_cuf_pending,
                      (len(ascii_after_cuf_pending),), None))
    wide_after_cuf_pending = b"A\x1b[C" + "\U0001f680".encode()
    cases.append(Case("wide-glyph-after-cuf-from-wrap-pending", 1, 2,
                      wide_after_cuf_pending,
                      (len(wide_after_cuf_pending),), None))
    combining_after_cuf_pending = b"A\x1b[C" + "\u0301".encode()
    cases.append(Case("combining-after-cuf-from-wrap-pending", 1, 2,
                      combining_after_cuf_pending,
                      (len(combining_after_cuf_pending),), None))
    unicode_internal_margin_pending = (b"\x1b[?69h\x1b[1;2s\x1b[1;2HA"
                                       b"\x1b[C" + "\u00e9".encode())
    cases.append(Case("unicode-after-cuf-at-internal-margin-pending", 3, 2,
                      unicode_internal_margin_pending,
                      (len(unicode_internal_margin_pending),), None))
    wide_custom_physical_edge = (b"\x1b[?69h\x1b[2;3s\x1b[1;3HA\x1b[C"
                                 + "\u65e5".encode())
    cases.append(Case("wide-after-cuf-at-custom-physical-edge", 3, 2,
                      wide_custom_physical_edge,
                      (len(wide_custom_physical_edge),), None))
    emoji_zwj_after_cuf_nowrap = (b"\x1b[?7lA\x1b[C"
                                  + "\U0001f469\u200d\U0001f4bb".encode())
    cases.append(Case("emoji-zwj-after-cuf-from-nowrap-parked", 1, 2,
                      emoji_zwj_after_cuf_nowrap,
                      (len(emoji_zwj_after_cuf_nowrap),), None))
    unicode_internal_margin_nowrap = (b"\x1b[?69h\x1b[1;2s\x1b[?7l"
                                      b"\x1b[1;2HA\x1b[C"
                                      + "\u00e9".encode())
    cases.append(Case("unicode-after-cuf-at-internal-margin-nowrap", 3, 2,
                      unicode_internal_margin_nowrap,
                      (len(unicode_internal_margin_nowrap),), None))
    kitty_cursor_reset = (b"\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;"
                          b"/wAA/w==\x1b\\")
    kitty_pending_then_nowrap = b"AA" + kitty_cursor_reset + b"\x1b[?7l "
    cases.append(Case("space-after-kitty-wrap-reset-with-nowrap", 2, 2,
                      kitty_pending_then_nowrap,
                      (len(kitty_pending_then_nowrap),), None))
    kitty_pending_autowrap = b"AA" + kitty_cursor_reset + b" "
    cases.append(Case("space-after-kitty-wrap-reset-with-autowrap", 2, 2,
                      kitty_pending_autowrap,
                      (len(kitty_pending_autowrap),), None))
    kitty_settled_then_nowrap = b"A" + kitty_cursor_reset + b"\x1b[?7l "
    cases.append(Case("space-after-kitty-settled-reset-with-nowrap", 2, 2,
                      kitty_settled_then_nowrap,
                      (len(kitty_settled_then_nowrap),), None))
    kitty_delete = b"\x1b_Ga=d,d=i,i=3,q=2;\x1b\\"
    kitty_delete_pending_nowrap = b"AA" + kitty_delete + b"\x1b[?7l "
    cases.append(Case("space-after-kitty-delete-from-pending-nowrap", 2, 2,
                      kitty_delete_pending_nowrap,
                      (len(kitty_delete_pending_nowrap),), None))
    kitty_pending_edge = b"\x1b[1;2HA"
    kitty_unicode_autowrap = (kitty_pending_edge + kitty_cursor_reset
                              + "\u00e9".encode())
    cases.append(Case("unicode-after-kitty-reset-from-pending", 2, 2,
                      kitty_unicode_autowrap,
                      (len(kitty_unicode_autowrap),), None))
    kitty_wide_autowrap = (kitty_pending_edge + kitty_cursor_reset
                           + "\u65e5".encode())
    cases.append(Case("wide-after-kitty-reset-from-pending", 2, 2,
                      kitty_wide_autowrap,
                      (len(kitty_wide_autowrap),), None))
    kitty_unicode_nowrap = (kitty_pending_edge + kitty_cursor_reset
                            + b"\x1b[?7l" + "\u00e9".encode())
    cases.append(Case("unicode-nowrap-after-kitty-reset-from-pending", 2, 2,
                      kitty_unicode_nowrap,
                      (len(kitty_unicode_nowrap),), None))
    kitty_wide_nowrap = (kitty_pending_edge + kitty_cursor_reset
                         + b"\x1b[?7l" + "\u65e5".encode())
    cases.append(Case("wide-nowrap-after-kitty-reset-from-pending", 2, 2,
                      kitty_wide_nowrap,
                      (len(kitty_wide_nowrap),), None))
    kitty_preload = (b"\x1b_Ga=t,f=32,s=1,v=1,i=21,q=2;"
                     b"/wAA/w==\x1b\\")
    kitty_display = b"\x1b_Ga=p,i=21,p=1,x=0,y=0,c=1,r=1,q=2;\x1b\\"
    kitty_display_unicode = (kitty_preload + kitty_pending_edge
                             + kitty_display + "\u00e9".encode())
    cases.append(Case("unicode-after-kitty-display-from-pending", 2, 2,
                      kitty_display_unicode,
                      (len(kitty_display_unicode),), None))
    kitty_combining = (kitty_pending_edge + kitty_cursor_reset
                       + "\u0301".encode())
    cases.append(Case("combining-after-kitty-reset-retains-last-write", 2, 2,
                      kitty_combining, (len(kitty_combining),), None))
    kitty_query = (b"\x1b_Ga=q,f=32,s=1,v=1,i=23,q=2;"
                   b"/wAA/w==\x1b\\")
    kitty_pending_query = kitty_pending_edge + kitty_query
    cases.append(Case("kitty-query-preserves-wrap-pending", 2, 2,
                      kitty_pending_query, (len(kitty_pending_query),), None))
    kitty_invalid_transmit = (b"\x1b_Ga=T,f=32,s=1,v=1,i=22,q=2;"
                              b"%%%\x1b\\")
    kitty_pending_invalid = kitty_pending_edge + kitty_invalid_transmit
    cases.append(Case("invalid-kitty-transmit-preserves-wrap-pending", 2, 2,
                      kitty_pending_invalid,
                      (len(kitty_pending_invalid),), None))
    kitty_nowrap_parked = (b"\x1b[?7l" + kitty_pending_edge
                           + kitty_cursor_reset + b" ")
    cases.append(Case("space-after-kitty-reset-from-nowrap-parked", 2, 2,
                      kitty_nowrap_parked,
                      (len(kitty_nowrap_parked),), None))
    lf_nowrap_parked = b"\x1b[?7lA\n"
    cases.append(Case("lf-after-nowrap-parked-one-column", 1, 1,
                      lf_nowrap_parked, (len(lf_nowrap_parked),), None))
    ri_nowrap_parked = b"\x1b[?7lA\x1bM"
    cases.append(Case("ri-after-nowrap-parked-one-column", 1, 1,
                      ri_nowrap_parked, (len(ri_nowrap_parked),), None))
    ri_nowrap_parked_declrmm = b"\x1b[?7l\x1b[?69hA\x1bM"
    cases.append(Case("ri-after-nowrap-parked-one-column-declrmm", 1, 1,
                      ri_nowrap_parked_declrmm,
                      (len(ri_nowrap_parked_declrmm),), None))
    ri_settled_control = b"A\x1b[H\x1bM"
    cases.append(Case("ri-after-settled-one-column-control", 1, 1,
                      ri_settled_control, (len(ri_settled_control),), None))
    lf_pending_internal = b"\x1b[?69h\x1b[1;2s\x1b[1;2HA\n"
    cases.append(Case("lf-after-pending-internal-right-margin", 3, 2,
                      lf_pending_internal, (len(lf_pending_internal),), None))
    lf_parked_full_declrmm = b"\x1b[?69h\x1b[1;2s\x1b[?7l\x1b[1;2HA\n"
    cases.append(Case("lf-after-nowrap-parked-fullwidth-declrmm", 2, 2,
                      lf_parked_full_declrmm,
                      (len(lf_parked_full_declrmm),), None))
    ri_parked_full_declrmm = (b"\x1b[?69h\x1b[1;2s\x1b[?7l"
                              b"\x1b[1;2HA\x1bM")
    cases.append(Case("ri-after-nowrap-parked-fullwidth-declrmm", 2, 2,
                      ri_parked_full_declrmm,
                      (len(ri_parked_full_declrmm),), None))
    ri_hidden_settled = b"A\x1b[?69h\x1b[1;2s\x1b[?69l\x1b[1;3H\x1bM"
    cases.append(Case("ri-hidden-margin-physical-right-settled-noop", 3, 2,
                      ri_hidden_settled, (len(ri_hidden_settled),), None))
    lf_hidden_settled = (b"\x1b[2;1HB\x1b[?69h\x1b[1;2s"
                         b"\x1b[?69l\x1b[2;3H\n")
    cases.append(Case("lf-hidden-margin-bottom-settled-noop", 3, 2,
                      lf_hidden_settled, (len(lf_hidden_settled),), None))
    lf_active_settled = b"\x1b[2;1HB\x1b[?69h\x1b[1;2s\x1b[2;3H\n"
    cases.append(Case("lf-active-margin-bottom-settled-noop", 3, 2,
                      lf_active_settled, (len(lf_active_settled),), None))
    ri_hidden_parked = (b"\x1b[?69h\x1b[1;2s\x1b[?69l"
                        b"\x1b[?7l\x1b[1;3HA\x1bM")
    cases.append(Case("ri-hidden-margin-physical-right-parked-noop", 3, 2,
                      ri_hidden_parked, (len(ri_hidden_parked),), None))
    lf_hidden_parked = (b"\x1b[?69h\x1b[1;2s\x1b[?69l"
                        b"\x1b[?7l\x1b[2;3HA\n")
    cases.append(Case("lf-hidden-margin-bottom-parked-noop", 3, 2,
                      lf_hidden_parked, (len(lf_hidden_parked),), None))
    lf_active_parked_content = (b"\x1b[1;1HX\x1b[2;1HY\x1b[?69h"
                                b"\x1b[1;2s\x1b[?7l\x1b[2;2HA\n")
    cases.append(Case("lf-active-margin-bottom-parked-content-noop", 3, 2,
                      lf_active_parked_content,
                      (len(lf_active_parked_content),), None))
    lf_pending_above_region = (b"\x1b[2;3r\x1b[?69h\x1b[1;1s"
                               b"\x1b[1;2HA\n")
    cases.append(Case("lf-pending-internal-edge-above-region", 2, 3,
                      lf_pending_above_region,
                      (len(lf_pending_above_region),), None))
    lf_pending_below_region = (b"\x1b[1;2r\x1b[?69h\x1b[1;1s"
                               b"\x1b[3;2HA\n")
    cases.append(Case("lf-pending-internal-edge-below-region", 2, 3,
                      lf_pending_below_region,
                      (len(lf_pending_below_region),), None))
    lf_hidden_stored_print = (b"\x1b[?69h\x1b[1;1s\x1b[?69l"
                              b"\x1b[2;1HA\n")
    cases.append(Case("lf-after-hidden-stored-edge-print-bottom", 2, 2,
                      lf_hidden_stored_print,
                      (len(lf_hidden_stored_print),), None))
    ri_pending_below_region = (b"\x1b[1;2r\x1b[?69h\x1b[1;1s"
                               b"\x1b[3;2HA\x1bM")
    cases.append(Case("ri-pending-internal-edge-below-region", 2, 4,
                      ri_pending_below_region,
                      (len(ri_pending_below_region),), None))
    ri_pending_below_markers = (b"\x1b[1;1HX\x1b[2;1HY\x1b[3;1HZ"
                                b"\x1b[1;2r\x1b[?69h\x1b[1;1s"
                                b"\x1b[3;2HA\x1bM")
    cases.append(Case("ri-pending-below-region-marker-transform", 2, 3,
                      ri_pending_below_markers,
                      (len(ri_pending_below_markers),), None))
    ind_pending_below_markers = (b"\x1b[1;1HX\x1b[2;1HY\x1b[3;1HZ"
                                 b"\x1b[1;2r\x1b[?69h\x1b[1;1s"
                                 b"\x1b[3;2HA\x1bD")
    cases.append(Case("ind-pending-below-region-marker-transform", 2, 3,
                      ind_pending_below_markers,
                      (len(ind_pending_below_markers),), None))
    ri_hidden_wide = ("\u65e5".encode() +
                      b"\x1b[?69h\x1b[1;2s\x1b[?69l\x1b[1;3H\x1bM")
    cases.append(Case("ri-hidden-margin-wide-marker-noop", 3, 2,
                      ri_hidden_wide, (len(ri_hidden_wide),), None))
    lf_active_parked_wide = (b"\x1b[1;1H" + "\u65e5".encode() +
                             b"\x1b[2;1H" + "\u754c".encode() +
                             b"\x1b[?69h\x1b[1;2s\x1b[?7l"
                             b"\x1b[2;2HA\n")
    cases.append(Case("lf-active-margin-bottom-parked-wide-noop", 3, 2,
                      lf_active_parked_wide,
                      (len(lf_active_parked_wide),), None))
    ri_physical_parked_nontop = b"\x1b[?7l\x1b[2;2HA\x1bM"
    cases.append(Case("ri-nowrap-parked-physical-nontop", 2, 2,
                      ri_physical_parked_nontop,
                      (len(ri_physical_parked_nontop),), None))
    lf_physical_parked_bottom = b"\x1b[?7l\x1b[2;2HA\n"
    cases.append(Case("lf-nowrap-parked-physical-bottom-noop", 2, 2,
                      lf_physical_parked_bottom,
                      (len(lf_physical_parked_bottom),), None))
    active_edge_print_wide = (b"\x1b[?7l\x1b[1;1H" + "\u65e5".encode() +
                              b"\x1b[2;1H" + "\u754c".encode() +
                              b"\x1b[3;1H" + "\u8a9e".encode() +
                              b"\x1b[1;2r\x1b[?69h\x1b[1;1s"
                              b"\x1b[?7h\x1b[3;2HA")
    cases.append(Case("active-edge-print-below-region-wide-transform", 2, 3,
                      active_edge_print_wide,
                      (len(active_edge_print_wide),), None))
    kitty_bottom_transmit = (b"\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;"
                             b"/wAA/w==\x1b\\")
    cases.append(Case("kitty-transmit-at-bottom-generates-line", 1, 1,
                      kitty_bottom_transmit,
                      (len(kitty_bottom_transmit),), None))
    kitty_preload_for_display = (b"\x1b_Ga=t,f=32,s=1,v=1,i=31,q=2;"
                                 b"/wAA/w==\x1b\\")
    kitty_display_preloaded = (b"\x1b_Ga=p,i=31,p=1,x=0,y=0,c=1,r=1,q=2;"
                               b"\x1b\\")
    kitty_bottom_display = kitty_preload_for_display + kitty_display_preloaded
    cases.append(Case("kitty-display-at-bottom-generates-line", 1, 1,
                      kitty_bottom_display,
                      (len(kitty_bottom_display),), None))
    kitty_pending_region_bottom = (b"\x1b[1;2r\x1b[?7h\x1b[2;1HA" +
                                     kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-pending-at-region-bottom-noop", 1, 3,
                      kitty_pending_region_bottom,
                      (len(kitty_pending_region_bottom),), None))
    kitty_parked_region_bottom = (b"\x1b[1;2r\x1b[?7l\x1b[2;1HA" +
                                    kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-parked-at-region-bottom-noop", 1, 3,
                      kitty_parked_region_bottom,
                      (len(kitty_parked_region_bottom),), None))
    four_row_markers = (b"\x1b[?7l\x1b[1;1HA\x1b[2;1HB"
                        b"\x1b[3;1HC\x1b[4;1HD")
    kitty_region_scroll_with_room = (four_row_markers + b"\x1b[2;3r"
                                     b"\x1b[?7h\x1b[3;1H" +
                                     kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-scrolls-region-with-room-below", 1, 4,
                      kitty_region_scroll_with_room,
                      (len(kitty_region_scroll_with_room),), None))
    three_row_markers = b"\x1b[?7l\x1b[1;1HA\x1b[2;1HB\x1b[3;1HC"
    kitty_region_scroll_at_bottom = (three_row_markers + b"\x1b[2;3r"
                                     b"\x1b[?7h\x1b[3;1H" +
                                     kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-scrolls-region-at-physical-bottom", 1, 3,
                      kitty_region_scroll_at_bottom,
                      (len(kitty_region_scroll_at_bottom),), None))
    kitty_blank_region_cursor = (b"\x1b[2;3r\x1b[?7h\x1b[3;1H" +
                                   kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-blank-region-bottom-preserves-cursor", 1, 4,
                      kitty_blank_region_cursor,
                      (len(kitty_blank_region_cursor),), None))
    kitty_alternate_bottom = b"\x1b[?1049h" + kitty_bottom_transmit
    cases.append(Case("kitty-transmit-alternate-buffer-bottom-generates-line",
                      1, 1, kitty_alternate_bottom,
                      (len(kitty_alternate_bottom),), None))
    kitty_below_region_setup = b"\x1b[1;2r\x1b[?7h\x1b[3;1H"
    kitty_success_public_noop = (kitty_below_region_setup +
                                 kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-success-publicly-inert-below-region",
                      1, 3, kitty_success_public_noop,
                      (len(kitty_success_public_noop),), None))
    kitty_malformed_action = b"\x1b_Ga=z,i=-1,q=2;AA==\x1b\\"
    kitty_malformed_public_noop = (kitty_below_region_setup +
                                   kitty_malformed_action)
    cases.append(Case("kitty-malformed-publicly-inert-below-region", 1, 3,
                      kitty_malformed_public_noop,
                      (len(kitty_malformed_public_noop),), None))
    kitty_display_public_noop = (kitty_preload_for_display +
                                 kitty_below_region_setup +
                                 kitty_display_preloaded)
    cases.append(Case("kitty-display-success-publicly-inert-below-region",
                      1, 3, kitty_display_public_noop,
                      (len(kitty_display_public_noop),), None))
    kitty_delete_preloaded = b"\x1b_Ga=d,d=i,i=31,q=2;\x1b\\"
    kitty_delete_public_noop = (kitty_preload_for_display +
                                kitty_below_region_setup +
                                kitty_delete_preloaded)
    cases.append(Case("kitty-delete-publicly-inert-below-region", 1, 3,
                      kitty_delete_public_noop,
                      (len(kitty_delete_public_noop),), None))
    kitty_full_row_markers = (b"\x1b[?7l\x1b[1;1HAAA"
                              b"\x1b[2;1HBBB\x1b[3;1HCCC")
    kitty_active_slice_inside = (kitty_full_row_markers + b"\x1b[2;3r"
                                 b"\x1b[?69h\x1b[2;2s"
                                 b"\x1b[?7h\x1b[3;2H" +
                                 kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-active-margin-scrolls-stored-slice",
                      3, 3, kitty_active_slice_inside,
                      (len(kitty_active_slice_inside),), None))
    kitty_active_slice_outside = (kitty_full_row_markers + b"\x1b[2;3r"
                                  b"\x1b[?69h\x1b[2;2s"
                                  b"\x1b[?7h\x1b[3;1H" +
                                  kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-outside-active-margin-noop", 3, 3,
                      kitty_active_slice_outside,
                      (len(kitty_active_slice_outside),), None))
    kitty_hidden_inside = (kitty_full_row_markers + b"\x1b[2;3r"
                           b"\x1b[?69h\x1b[2;2s\x1b[?69l"
                           b"\x1b[?7h\x1b[3;2H" +
                           kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-hidden-margin-scrolls-physical-row",
                      3, 3, kitty_hidden_inside,
                      (len(kitty_hidden_inside),), None))
    kitty_hidden_outside = (kitty_full_row_markers + b"\x1b[2;3r"
                            b"\x1b[?69h\x1b[2;2s\x1b[?69l"
                            b"\x1b[?7h\x1b[3;1H" +
                            kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-outside-hidden-margin-noop", 3, 3,
                      kitty_hidden_outside,
                      (len(kitty_hidden_outside),), None))
    kitty_alternate_default_outside = (b"\x1b[?1049h\x1b[1;2H" +
                                       kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-alternate-default-outside-stored-noop",
                      2, 1, kitty_alternate_default_outside,
                      (len(kitty_alternate_default_outside),), None))
    kitty_active_full_generation = (b"\x1b[?69h\x1b[1;2s\x1b[1;1H" +
                                    kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-active-fullwidth-generates-line", 2, 1,
                      kitty_active_full_generation,
                      (len(kitty_active_full_generation),), None))
    kitty_hidden_partial_generation = (b"\x1b[?69h\x1b[2;2s\x1b[?69l"
                                       b"\x1b[1;2H" +
                                       kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-hidden-partial-generates-full-line",
                      3, 1, kitty_hidden_partial_generation,
                      (len(kitty_hidden_partial_generation),), None))
    kitty_active_partial_singleton = (b"\x1b[?7lAAA\x1b[?69h\x1b[2;2s"
                                        b"\x1b[?7h\x1b[1;2H" +
                                        kitty_bottom_transmit)
    cases.append(Case("kitty-transmit-active-partial-singleton-erases-slice",
                      3, 1, kitty_active_partial_singleton,
                      (len(kitty_active_partial_singleton),), None))
    zwj_after_tab_wide = "\u65e5".encode() + b"\t" + "\u200d".encode()
    cases.append(Case("zwj-after-tab-from-wide-cjk-one-column", 1, 1,
                      zwj_after_tab_wide,
                      (len(zwj_after_tab_wide),), None))
    mn_after_tab_ascii_no_move = b"A\t" + "\u0301".encode()
    cases.append(Case("mn-after-tab-from-ascii-no-move", 2, 1,
                      mn_after_tab_ascii_no_move,
                      (len(mn_after_tab_ascii_no_move),), None))
    zwj_after_tab_unicode_move = "\u00e9".encode() + b"\t" + "\u200d".encode()
    cases.append(Case("zwj-after-tab-from-unicode-moving", 4, 1,
                      zwj_after_tab_unicode_move,
                      (len(zwj_after_tab_unicode_move),), None))
    mn_after_tab_pending = b"\x1b[1;2HA\t" + "\u0301".encode()
    cases.append(Case("mn-after-tab-from-pending-edge", 2, 1,
                      mn_after_tab_pending,
                      (len(mn_after_tab_pending),), None))
    zwj_after_tab_parked = b"\x1b[?7l\x1b[1;2HA\t" + "\u200d".encode()
    cases.append(Case("zwj-after-tab-from-nowrap-parked-edge", 2, 1,
                      zwj_after_tab_parked,
                      (len(zwj_after_tab_parked),), None))
    mn_after_tab_wrapped = b"\x1b[1;2HXA\t" + "\u0301".encode()
    cases.append(Case("mn-after-tab-from-wrapped-row", 2, 1,
                      mn_after_tab_wrapped,
                      (len(mn_after_tab_wrapped),), None))
    zwj_after_cleared_tab = b"\x1b[3gA\t" + "\u200d".encode()
    cases.append(Case("zwj-after-cleared-tab-no-move", 2, 1,
                      zwj_after_cleared_tab,
                      (len(zwj_after_cleared_tab),), None))
    narrow_after_tab = b"A\tZ"
    cases.append(Case("narrow-after-tab-control", 4, 1,
                      narrow_after_tab, (len(narrow_after_tab),), None))
    mn_after_rejected_wide = (b"\x1b[?7l" + "\u65e5".encode() + b"\t" +
                              "\u0301".encode())
    cases.append(Case("mn-after-tab-from-rejected-nowrap-wide-control", 1, 1,
                      mn_after_rejected_wide,
                      (len(mn_after_rejected_wide),), None))
    mn_after_tab_settled = b"A\x1b[1;1H\t" + "\u0301".encode()
    cases.append(Case("mn-after-tab-from-explicitly-settled-cursor", 2, 1,
                      mn_after_tab_settled,
                      (len(mn_after_tab_settled),), None))
    dl_content_bottom_cover = (b"\x1b[?69h\x1b[1;2r\x1b[3;1Ha"
                               b"\x1b[2;1H\x1b[2M")
    cases.append(Case("dl-virtual-window-deletes-marker-below-region", 1, 3,
                      dl_content_bottom_cover,
                      (len(dl_content_bottom_cover),), None))
    dl_content_bottom_shift = (b"\x1b[?69h\x1b[1;2r\x1b[3;1Ha"
                               b"\x1b[2;1H\x1b[M")
    cases.append(Case("dl-virtual-window-pulls-marker-below-region", 1, 3,
                      dl_content_bottom_shift,
                      (len(dl_content_bottom_shift),), None))
    dl_content_inside_extend = (b"\x1b[?69h\x1b[1;3r\x1b[4;1Ha"
                                b"\x1b[2;1H\x1b[M")
    cases.append(Case("dl-virtual-window-extends-below-region", 1, 4,
                      dl_content_inside_extend,
                      (len(dl_content_inside_extend),), None))
    dl_content_above_clip = (b"\x1b[?69h\x1b[3;4r\x1b[3;1Ha"
                             b"\x1b[1;1H\x1b[M")
    cases.append(Case("dl-virtual-window-above-region-excludes-later-marker", 1, 4,
                      dl_content_above_clip,
                      (len(dl_content_above_clip),), None))
    dl_content_below_clip = (b"\x1b[?69h\x1b[1;2r\x1b[5;1Ha"
                             b"\x1b[3;1H\x1b[M")
    cases.append(Case("dl-virtual-window-below-region-clips-at-height", 1, 5,
                      dl_content_below_clip,
                      (len(dl_content_below_clip),), None))
    dl_content_oversized = (b"\x1b[?69h\x1b[1;2r\x1b[3;1Ha"
                            b"\x1b[2;1H\x1b[4M")
    cases.append(Case("dl-virtual-window-clamps-oversized-count", 1, 3,
                      dl_content_oversized,
                      (len(dl_content_oversized),), None))
    dl_content_before_window = (b"\x1b[?69h\x1b[1;3r\x1b[1;1Ha"
                                b"\x1b[2;1H\x1b[M")
    cases.append(Case("dl-virtual-window-preserves-marker-before-start", 1, 4,
                      dl_content_before_window,
                      (len(dl_content_before_window),), None))
    dl_content_mode_off = (b"\x1b[1;2r\x1b[3;1Ha"
                           b"\x1b[2;1H\x1b[M")
    cases.append(Case("dl-mode-off-preserves-marker-below-region-control", 1, 3,
                      dl_content_mode_off,
                      (len(dl_content_mode_off),), None))
    cases.append(Case("vs16-after-ri-flag-is-ignored", 2, 1,
                      "\U0001f1fa\U0001f1f8\ufe0f".encode(),
                      (11,), None))
    cases.append(Case("vs15-after-ri-flag-preserves-wide-cluster", 2, 1,
                      "\U0001f1fa\U0001f1f8\ufe0e".encode(),
                      (11,), None))
    cases.append(Case("vs16-after-fixed-wide-rocket-is-ignored", 2, 1,
                      "\U0001f680\ufe0f".encode(), (7,), None))
    cases.append(Case("vs15-after-fixed-wide-rocket-preserves-width", 2, 1,
                      "\U0001f680\ufe0e".encode(), (7,), None))
    cases.append(Case("vs16-after-fixed-wide-woman-is-ignored", 2, 1,
                      "\U0001f469\ufe0f".encode(), (7,), None))
    cases.append(Case("vs15-after-fixed-wide-woman-preserves-width", 2, 1,
                      "\U0001f469\ufe0e".encode(), (7,), None))
    cases.append(Case("narrow-after-ignored-vs15-on-ri-flag", 3, 1,
                      "\U0001f1fa\U0001f1f8\ufe0eZ".encode(),
                      (12,), None))
    heart_settled_vs16 = "\u2764".encode() + b"\x1b[1;1H" + "\ufe0f".encode()
    cases.append(Case("vs16-expands-heart-after-explicit-cup", 2, 1,
                      heart_settled_vs16,
                      (len(heart_settled_vs16),), None))
    cases.append(Case("narrow-after-heart-vs16-after-explicit-cup", 3, 1,
                      heart_settled_vs16 + b"Z",
                      (len(heart_settled_vs16) + 1,), None))
    plane_settled_vs16 = "\u2708".encode() + b"\x1b[1;1H" + "\ufe0f".encode()
    cases.append(Case("narrow-after-plane-vs16-after-explicit-cup", 3, 1,
                      plane_settled_vs16 + b"Z",
                      (len(plane_settled_vs16) + 1,), None))
    cases.append(Case("vs16-after-wide-zwj-cluster-control", 3, 1,
                      "\U0001f469\u200d\U0001f4bb\ufe0f".encode(),
                      (14,), None))
    rejected_rocket_vs16 = b"\x1b[?7l" + "\U0001f680\ufe0f".encode()
    cases.append(Case("vs16-after-rejected-nowrap-wide-control", 1, 1,
                      rejected_rocket_vs16,
                      (len(rejected_rocket_vs16),), None))
    cases.append(Case("vs15-after-grinning-face-is-ignored", 2, 1,
                      "\U0001f600\ufe0e".encode(), (7,), None))
    cases.append(Case("vs16-after-grinning-face-is-ignored", 2, 1,
                      "\U0001f600\ufe0f".encode(), (7,), None))
    cases.append(Case("narrow-after-ignored-vs15-on-grinning-face", 2, 1,
                      "\U0001f600\ufe0eZ".encode(), (8,), None))
    parked_zero_zwj = b"\x1b[?7l0" + "\u200d".encode()
    cases.append(Case("zwj-after-rejected-woman-after-parked-zwj", 1, 1,
                      parked_zero_zwj + "\U0001f469\u200d".encode(),
                      (len(parked_zero_zwj) + 7,), None))
    cases.append(Case("zwj-after-rejected-rocket-after-parked-zwj", 1, 1,
                      parked_zero_zwj + "\U0001f680\u200d".encode(),
                      (len(parked_zero_zwj) + 7,), None))
    cases.append(Case("mn-after-rejected-laptop-after-parked-zwj", 1, 1,
                      parked_zero_zwj + "\U0001f4bb\u0301".encode(),
                      (len(parked_zero_zwj) + 6,), None))
    cases.append(Case("wide-rocket-prints-after-zwj-on-ineligible-base", 3, 1,
                      parked_zero_zwj + "\U0001f680".encode(),
                      (len(parked_zero_zwj) + 4,), None))
    cases.append(Case("mn-follows-wide-woman-after-zwj-on-ineligible-base", 3, 1,
                      parked_zero_zwj + "\U0001f469\u0301".encode(),
                      (len(parked_zero_zwj) + 6,), None))
    cases.append(Case("zwj-follows-wide-laptop-after-zwj-on-ineligible-base", 3, 1,
                      parked_zero_zwj + "\U0001f4bb\u200d".encode(),
                      (len(parked_zero_zwj) + 7,), None))
    cases.append(Case("rejected-cjk-preserves-parked-zwj-control", 1, 1,
                      parked_zero_zwj + "\u65e5\u200d".encode(),
                      (len(parked_zero_zwj) + 6,), None))
    cases.append(Case("wide-cjk-prints-after-zwj-on-ineligible-base-control", 3, 1,
                      parked_zero_zwj + "\u65e5\u200d".encode(),
                      (len(parked_zero_zwj) + 6,), None))
    parked_zero_mn = b"\x1b[?7l0" + "\u0301".encode()
    cases.append(Case("mn-base-rejected-woman-zwj-control", 1, 1,
                      parked_zero_mn + "\U0001f469\u200d".encode(),
                      (len(parked_zero_mn) + 7,), None))
    eligible_woman_cluster = (b"\x1b[?7l" +
                              "\U0001f469\u200d\U0001f4bb".encode())
    cases.append(Case("eligible-woman-zwj-laptop-control", 2, 1,
                      eligible_woman_cluster,
                      (len(eligible_woman_cluster),), None))
    dch_relocated_cell = b"0A\rZ\r\x1b[P"
    cases.append(Case("mn-follows-cell-relocated-by-dch", 2, 1,
                      dch_relocated_cell + "\u0301".encode(),
                      (len(dch_relocated_cell) + 2,), None))
    cases.append(Case("zwj-follows-cell-relocated-by-dch", 2, 1,
                      dch_relocated_cell + "\u200d".encode(),
                      (len(dch_relocated_cell) + 3,), None))
    reverse_wrap_bs_reflow = b"\x1b[?45haZ\r\b"
    cases.append(Case("reverse-wrap-bs-two-cells-survive-reflow", 1, 1,
                      reverse_wrap_bs_reflow,
                      (len(reverse_wrap_bs_reflow),), (1, 1)))
    no_reverse_wrap_bs_reflow = b"aZ\r\b"
    cases.append(Case("bs-two-cells-reflow-without-reverse-wrap-control", 1, 1,
                      no_reverse_wrap_bs_reflow,
                      (len(no_reverse_wrap_bs_reflow),), (1, 1)))
    reverse_wrap_no_bs_reflow = b"\x1b[?45haZ\r"
    cases.append(Case("two-cells-reflow-without-bs-control", 1, 1,
                      reverse_wrap_no_bs_reflow,
                      (len(reverse_wrap_no_bs_reflow),), (1, 1)))
    reverse_wrap_two_bs_reflow = b"\x1b[?45hZ\b\b"
    cases.append(Case("reverse-wrap-two-bs-preserves-empty-row-on-reflow", 1, 2,
                      reverse_wrap_two_bs_reflow,
                      (len(reverse_wrap_two_bs_reflow),), (1, 1)))
    reverse_wrap_cursor_reflow = b"\x1b[?45haZ\b"
    cases.append(Case("reverse-wrap-bs-reflow-preserves-logical-column", 2, 1,
                      reverse_wrap_cursor_reflow,
                      (len(reverse_wrap_cursor_reflow),), (1, 1)))
    reverse_wrap_repartition = b"\x1b[?45haaZ\x1b[H\b"
    cases.append(Case("reverse-wrap-bs-reflow-preserves-row-partition", 1, 2,
                      reverse_wrap_repartition,
                      (len(reverse_wrap_repartition),), (1, 1)))
    dch_shifted_heart = (b"Z" + "\u2764".encode()
                         + b"\rZ\r\x1b[P" + "\ufe0f".encode())
    cases.append(Case("vs16-expands-heart-adopted-at-dch-owner-coordinate", 2, 1,
                      dch_shifted_heart,
                      (len(dch_shifted_heart),), None))
    dch_moved_wide_owner = (b"Z" + "\u65e5".encode()
                            + b"\r\x1b[P" + "\u0301".encode())
    cases.append(Case("mn-does-not-follow-wide-owner-moved-by-dch", 3, 1,
                      dch_moved_wide_owner,
                      (len(dch_moved_wide_owner),), None))
    reverse_wrap_cub_bs = b"\x1b[?45hZ\x1b[D\b"
    cases.append(Case("reverse-wrap-bs-cycles-after-cub-clears-pending", 1, 2,
                      reverse_wrap_cub_bs,
                      (len(reverse_wrap_cub_bs),), (1, 1)))
    reverse_wrap_unwrapped_top = b"\x1b[?45haZ\x1b[H\b"
    cases.append(Case(
        "reverse-wrap-top-cycle-preserves-wrapped-destination-from-unwrapped-source",
        1, 2, reverse_wrap_unwrapped_top,
        (len(reverse_wrap_unwrapped_top),), (1, 1)))
    reverse_wrap_cycle_grow = b"\x1b[?45haaZ\x1b[H\b"
    cases.append(Case("reverse-wrap-top-cycle-preserves-boundary-on-grow", 1, 2,
                      reverse_wrap_cycle_grow,
                      (len(reverse_wrap_cycle_grow),), (3, 1)))
    overwritten_wide_heart = "\u65e5".encode() + b"\r" + "\u2764".encode()
    cases.append(Case("vs16-after-narrow-heart-overwrites-wide-cell", 1, 2,
                      overwritten_wide_heart + "\ufe0f".encode(),
                      (len(overwritten_wide_heart) + 3,), None))
    cases.append(Case("vs15-after-narrow-heart-overwrites-wide-cell-control", 1, 2,
                      overwritten_wide_heart + "\ufe0e".encode(),
                      (len(overwritten_wide_heart) + 3,), None))
    cases.append(Case("narrow-heart-overwrites-wide-cell-control", 1, 2,
                      overwritten_wide_heart,
                      (len(overwritten_wide_heart),), None))
    cases.append(Case("vs16-overwrite-wide-with-room-control", 2, 2,
                      overwritten_wide_heart + "\ufe0f".encode(),
                      (len(overwritten_wide_heart) + 3,), None))
    cub_overwritten_wide_heart = ("\u65e5".encode() + b"\x1b[D"
                                  + "\u2764\ufe0f".encode())
    cases.append(Case("vs16-after-cub-heart-overwrites-one-column-wide-cell", 1, 2,
                      cub_overwritten_wide_heart,
                      (len(cub_overwritten_wide_heart),), None))
    margin_overwritten_wide_heart = (b"\x1b[?69h\x1b[2;2s\x1b[1;2H"
                                     + "\u65e5".encode() + b"\r"
                                     + "\u2764\ufe0f".encode())
    cases.append(Case(
        "vs16-expands-overwritten-heart-beyond-active-one-column-margin",
        3, 2, margin_overwritten_wide_heart,
        (len(margin_overwritten_wide_heart),), None))
    margin_adjacent_wide_heart = (b"\x1b[?69h\x1b[2;2s\x1b[1;2H"
                                  + "\u65e5".encode() + b"\x1b[Z"
                                  + "\u2764\ufe0f".encode())
    cases.append(Case("vs16-expansion-overwrites-adjacent-wide-lead", 2, 2,
                      margin_adjacent_wide_heart,
                      (len(margin_adjacent_wide_heart),), None))
    margin_separated_wide_heart = (b"\x1b[?69h\x1b[3;3s\x1b[1;3H"
                                   + "\u65e5".encode() + b"\x1b[Z"
                                   + "\u2764\ufe0f".encode())
    cases.append(Case(
        "vs16-current-narrow-owner-ignores-separated-stale-wide",
        3, 2, margin_separated_wide_heart,
        (len(margin_separated_wide_heart),), None))
    cud_pending_heart = (b"a\x1b[2B" + "\u2764\ufe0f".encode() + b" ")
    cases.append(Case("cud-consumes-pending-before-heart-vs16-and-space", 1, 1,
                      cud_pending_heart, (len(cud_pending_heart),), None))
    cud_pending_narrow_unicode = b"Z\x1b[2B" + "\u00e9".encode()
    cases.append(Case("cud-consumes-pending-before-nonascii-narrow-print", 1, 4,
                      cud_pending_narrow_unicode,
                      (len(cud_pending_narrow_unicode),), None))
    cud_pending_ascii_control = b"Z\x1b[2Ba"
    cases.append(Case("cud-pending-ascii-print-control", 1, 4,
                      cud_pending_ascii_control,
                      (len(cud_pending_ascii_control),), None))
    dch_pending_edge = b"Z\x1b[P"
    cases.append(Case("dch-at-pending-physical-edge-is-noop", 1, 2,
                      dch_pending_edge, (len(dch_pending_edge),), None))
    cases.append(Case("dch-at-pending-edge-preserves-next-wrap", 1, 2,
                      dch_pending_edge + b"a",
                      (len(dch_pending_edge) + 1,), None))
    dch_nowrap_edge = b"\x1b[?7lZ\x1b[P"
    cases.append(Case("dch-at-nowrap-parked-edge-preserves-overwrite", 1, 2,
                      dch_nowrap_edge + b"a",
                      (len(dch_nowrap_edge) + 1,), None))
    next_line_pending_narrow = b"Z\x1b[E" + "\u00e9".encode()
    cases.append(Case("cursor-next-line-clears-pending-at-bottom", 1, 1,
                      next_line_pending_narrow,
                      (len(next_line_pending_narrow),), None))
    next_line_pending_wide = b"ZZ\x1b[E" + "\u65e5".encode()
    cases.append(Case("cursor-next-line-clears-pending-before-wide", 2, 1,
                      next_line_pending_wide,
                      (len(next_line_pending_wide),), None))
    preceding_line_pending_narrow = b"Z\x1b[F" + "\u00e9".encode()
    cases.append(Case("cursor-preceding-line-clears-pending-at-top", 1, 1,
                      preceding_line_pending_narrow,
                      (len(preceding_line_pending_narrow),), None))
    next_line_active_left = (b"\x1b[?69h\x1b[2;2s\x1b[1;2HZ\x1b[E"
                             + "\u00e9".encode())
    cases.append(Case("cursor-next-line-uses-active-stored-left", 3, 2,
                      next_line_active_left,
                      (len(next_line_active_left),), None))
    next_line_hidden_left = (b"\x1b[?69h\x1b[2;2s\x1b[?69l"
                             b"\x1b[1;3HZ\x1b[E" + "\u00e9".encode())
    cases.append(Case("cursor-next-line-uses-hidden-stored-left", 3, 2,
                      next_line_hidden_left,
                      (len(next_line_hidden_left),), None))
    cursor_up_pending_selector = (b"\x1b[2;1HZ\x1b[A"
                                  + "\u2764\ufe0f".encode())
    cases.append(Case("cursor-up-pending-selector-ownership-control", 1, 2,
                      cursor_up_pending_selector,
                      (len(cursor_up_pending_selector),), None))
    vertical_region_down_clamp = b"\x1b[1;2r\x1b[1;1H\x1b[2B"
    cases.append(Case("cursor-down-clamps-at-vertical-region-bottom", 2, 3,
                      vertical_region_down_clamp,
                      (len(vertical_region_down_clamp),), None))
    heart = "\u2764".encode()
    vs15 = "\ufe0e".encode()
    vs16 = "\ufe0f".encode()
    cases.append(Case("repeated-vs16-is-idempotent", 4, 2,
                      heart + vs16 + vs16,
                      (len(heart) + len(vs16) * 2,), None))
    cases.append(Case("repeated-vs15-is-idempotent", 4, 2,
                      heart + vs15 + vs15,
                      (len(heart) + len(vs15) * 2,), None))
    cases.append(Case("first-vs15-wins-over-later-vs16", 4, 2,
                      heart + vs15 + vs16,
                      (len(heart) + len(vs15) + len(vs16),), None))
    cases.append(Case("first-vs16-wins-over-later-vs15", 4, 2,
                      heart + vs16 + vs15,
                      (len(heart) + len(vs16) + len(vs15),), None))
    zwj_cluster = "\U0001f469\u200d\U0001f4bb".encode()
    cases.append(Case("zwj-first-vs16-wins-over-later-vs15", 4, 2,
                      zwj_cluster + vs16 + vs15,
                      (len(zwj_cluster) + len(vs16) + len(vs15),), None))
    cases.append(Case("zwj-first-vs15-wins-over-later-vs16", 4, 2,
                      zwj_cluster + vs15 + vs16,
                      (len(zwj_cluster) + len(vs15) + len(vs16),), None))
    fixed_wide_repeated_selector = "\u65e5\ufe0f\ufe0f".encode()
    cases.append(Case("fixed-wide-repeated-selector-control", 4, 2,
                      fixed_wide_repeated_selector,
                      (len(fixed_wide_repeated_selector),), None))
    ascii_repeated_selector = b"A" + vs16 + vs16
    cases.append(Case("ascii-repeated-selector-control", 4, 2,
                      ascii_repeated_selector,
                      (len(ascii_repeated_selector),), None))
    semantic_reflow = b"aaa\x1b[B\n\x1b]133;A\x07"
    cases.append(Case("semantic-block-row-after-reflow", 3, 1,
                      semantic_reflow, (3, 3, 1, 8), (2, 1)))
    random_0051_earliest_cell_background = (
        b"\x1b[40m"
        b"\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\x1b\\"
    )
    cases.append(Case("random-0051-earliest-cell-background", 1, 1,
                      random_0051_earliest_cell_background,
                      (len(random_0051_earliest_cell_background),), None))
    random_0056_earliest_cell_scalar = (
        "\U0001f469".encode() + b"\x1b[2r\x1b[?6h\x1bD\x1bM"
    )
    cases.append(Case("random-0056-earliest-cell-scalar", 1, 3,
                      random_0056_earliest_cell_scalar,
                      (len(random_0056_earliest_cell_scalar),), None))
    cases.append(Case("random-0056-height-one-control", 1, 1,
                      random_0056_earliest_cell_scalar,
                      (len(random_0056_earliest_cell_scalar),), None))
    cases.append(Case("random-0056-height-two-control", 1, 2,
                      random_0056_earliest_cell_scalar,
                      (len(random_0056_earliest_cell_scalar),), None))
    cases.append(Case("random-0056-width-two-control", 2, 3,
                      random_0056_earliest_cell_scalar,
                      (len(random_0056_earliest_cell_scalar),), None))
    random_0056_two_narrow_wrapped_row = b"AA\x1b[2r\x1b[?6h\x1bD\x1bM"
    cases.append(Case("random-0056-two-narrow-wrapped-row", 1, 3,
                      random_0056_two_narrow_wrapped_row,
                      (len(random_0056_two_narrow_wrapped_row),), None))
    random_0056_wide_ri_only = "\U0001f469".encode() + b"\x1b[2r\x1b[?6h\x1bM"
    cases.append(Case("random-0056-wide-ri-only", 1, 3,
                      random_0056_wide_ri_only,
                      (len(random_0056_wide_ri_only),), None))
    random_0056_wide_cr_then_ind_ri = (
        "\U0001f469".encode() + b"\r\x1b[2r\x1b[?6h\x1bD\x1bM"
    )
    cases.append(Case("random-0056-wide-cr-then-ind-ri", 1, 3,
                      random_0056_wide_cr_then_ind_ri,
                      (len(random_0056_wide_cr_then_ind_ri),), None))
    cases.extend(origin_mode_line_motion_representative_cases())
    cases.extend(reverse_wrap_bs_vertical_region_representative_cases())
    cases.extend(kitty_row_background_representative_cases())
    cases.extend(kitty_retransmit_line_generation_representative_cases())
    cases.extend(decbi_generated_blank_grapheme_representative_cases())
    cases.extend(random439_grapheme_owner_representative_cases())
    cases.extend(semantic_kitty_resize_block_representative_cases())
    cases.extend(decfi_grapheme_owner_representative_cases())
    cases.extend(dl_grapheme_owner_representative_cases())
    cases.extend(post_zwj_cluster_boundary_representative_cases())
    cases.extend(narrowed_margin_dl_content_representative_cases())
    cases.extend(cht_after_edge_representative_cases())
    cases.extend(semantic_block_resize_edge_representative_cases())
    cases.extend(semantic_cursor_resize_representative_cases())
    cases.extend(semantic_resize_history_representative_cases())
    cases.extend(semantic_resize_multi_history_representative_cases())
    cases.extend(semantic_prewrapped_destination_representative_cases())
    cases.extend(semantic_prewrapped_destination_observer_cases())
    cases.extend(random268_semantic_line_motion_residual_cases())
    cases.extend(semantic_line_motion_boundary_representative_cases())
    cases.extend(semantic_line_motion_boundary_observer_cases())
    cases.extend(semantic_later_softwrap_representative_cases())
    cases.extend(semantic_hidden_margin_rewrap_representative_cases())
    cases.extend(active_margin_decfi_wide_persistence_representative_cases())
    cases.extend(active_margin_il_dl_roundtrip_representative_cases())
    cases.extend(selector_after_forward_motion_representative_cases())
    cases.extend(selector_forward_reverse_representative_cases())
    cases.extend(selector_motion_observer_representative_cases())
    cases.extend(selector_reposition_left_representative_cases())
    cases.extend(selector_after_vertical_reposition_representative_cases())
    cases.extend(active_margin_pending_backspace_representative_cases())
    cases.extend(ht_selector_cursor_width_representative_cases())
    cases.extend(active_margin_irm_orphan_tail_representative_cases())
    cases.extend(active_margin_dl_background_history_representative_cases())
    cases.extend(active_margin_dl_content_generation_discriminator_cases())
    for index in range(args.random_cases):
        cols = rng.randint(4, 24)
        rows = rng.randint(2, 10)
        payload = random_payload(rng, args.actions)
        resize = None if rng.random() < 0.7 else (rng.randint(4, 28), rng.randint(2, 12))
        cases.append(Case(f"random-{index:04d}", cols, rows, payload,
                          chunk_plan(len(payload), rng), resize))
    for matrix in args.audit_matrix:
        if matrix == "nowrap-dl":
            cases.extend(nowrap_parked_dl_matrix_cases())
        elif matrix == "il-to-dl-superset":
            cases.extend(il_to_dl_superset_matrix_cases())
        elif matrix == "narrowed-margin-dl":
            cases.extend(narrowed_margin_dl_matrix_cases())
        elif matrix == "narrowed-margin-dl-content":
            cases.extend(narrowed_margin_dl_content_matrix_cases())
        elif matrix == "active-margin-il-dl-roundtrip":
            cases.extend(active_margin_il_dl_roundtrip_matrix_cases())
        elif matrix == "hidden-margin-decfi-wide":
            cases.extend(hidden_margin_decfi_wide_matrix_cases())
        elif matrix == "hidden-margin-decfi-cursor":
            cases.extend(hidden_margin_decfi_cursor_matrix_cases())
        elif matrix == "active-margin-decfi-wide-persistence":
            cases.extend(active_margin_decfi_wide_persistence_matrix_cases())
        elif matrix == "hidden-margin-vs16-setup":
            cases.extend(hidden_margin_vs16_setup_matrix_cases())
        elif matrix == "ind-stored-margin-geometry":
            cases.extend(ind_stored_margin_geometry_matrix_cases())
        elif matrix == "lf-ri-parked-geometry":
            cases.extend(lf_ri_parked_geometry_matrix_cases())
        elif matrix == "active-edge-print-setup":
            cases.extend(active_edge_print_setup_matrix_cases())
        elif matrix == "declrmm-normalization":
            cases.extend(declrmm_normalization_matrix_cases())
        elif matrix == "cuf-after-edge":
            cases.extend(cuf_after_edge_matrix_cases())
        elif matrix == "cht-after-edge":
            cases.extend(cht_after_edge_matrix_cases())
        elif matrix == "semantic-block-resize-edge":
            cases.extend(semantic_block_resize_edge_matrix_cases())
        elif matrix == "semantic-resize-history":
            cases.extend(semantic_resize_history_matrix_cases())
        elif matrix == "semantic-resize-multi-history":
            cases.extend(semantic_resize_multi_history_matrix_cases())
        elif matrix == "semantic-prewrapped-destination":
            cases.extend(semantic_prewrapped_destination_matrix_cases())
        elif matrix == "semantic-line-motion-boundary":
            cases.extend(semantic_line_motion_boundary_matrix_cases())
        elif matrix == "semantic-later-softwrap":
            cases.extend(semantic_later_softwrap_matrix_cases())
        elif matrix == "semantic-hidden-margin-rewrap":
            cases.extend(semantic_hidden_margin_rewrap_matrix_cases())
        elif matrix == "kitty-control-pending":
            cases.extend(kitty_control_pending_matrix_cases())
        elif matrix == "kitty-row-advance":
            cases.extend(kitty_row_advance_matrix_cases())
        elif matrix == "kitty-row-horizontal-margin":
            cases.extend(kitty_row_horizontal_margin_matrix_cases())
        elif matrix == "kitty-row-background":
            cases.extend(kitty_row_background_matrix_cases())
        elif matrix == "kitty-retransmit-line-generation":
            cases.extend(kitty_retransmit_line_generation_matrix_cases())
        elif matrix == "decbi-generated-blank-grapheme":
            cases.extend(decbi_generated_blank_grapheme_matrix_cases())
        elif matrix == "ht-lastwrite":
            cases.extend(ht_lastwrite_matrix_cases())
        elif matrix == "selector-after-forward-motion":
            cases.extend(selector_after_forward_motion_matrix_cases())
        elif matrix == "selector-forward-reverse":
            cases.extend(selector_forward_reverse_matrix_cases())
        elif matrix == "selector-motion-observer":
            cases.extend(selector_motion_observer_matrix_cases())
        elif matrix == "selector-reposition-left":
            cases.extend(selector_reposition_left_matrix_cases())
        elif matrix == "selector-after-vertical-reposition":
            cases.extend(selector_after_vertical_reposition_matrix_cases())
        elif matrix == "active-margin-pending-bs":
            cases.extend(active_margin_pending_backspace_matrix_cases())
        elif matrix == "ht-selector-cursor-width":
            cases.extend(ht_selector_cursor_width_matrix_cases())
        elif matrix == "active-margin-irm-orphan-tail":
            cases.extend(active_margin_irm_orphan_tail_matrix_cases())
        elif matrix == "active-margin-dl-background-history":
            cases.extend(active_margin_dl_background_history_matrix_cases())
        elif matrix == "dl-single-content":
            cases.extend(dl_single_content_matrix_cases())
        elif matrix == "vs-lastwrite":
            cases.extend(variation_selector_lastwrite_matrix_cases())
        elif matrix == "post-zwj-wide":
            cases.extend(post_zwj_wide_matrix_cases())
        elif matrix == "parked-wide-selector-owner":
            cases.extend(parked_wide_selector_owner_matrix_cases())
        elif matrix == "c1-grapheme-owner":
            cases.extend(c1_grapheme_owner_matrix_cases())
        elif matrix == "semantic-kitty-resize-block":
            cases.extend(semantic_kitty_resize_block_matrix_cases())
        elif matrix == "decfi-grapheme-owner":
            cases.extend(decfi_grapheme_owner_matrix_cases())
        elif matrix == "dl-grapheme-owner":
            cases.extend(dl_grapheme_owner_matrix_cases())
        elif matrix == "post-zwj-cluster-boundary":
            cases.extend(post_zwj_cluster_boundary_matrix_cases())
        elif matrix == "reverse-wrap-bs-reflow":
            cases.extend(reverse_wrap_bs_reflow_matrix_cases())
        elif matrix == "reverse-wrap-bs-vregion":
            cases.extend(reverse_wrap_bs_vertical_region_matrix_cases())
        elif matrix == "dch-lastwrite":
            cases.extend(dch_lastwrite_matrix_cases())
        elif matrix == "cud-after-edge":
            cases.extend(cud_after_edge_matrix_cases())
        elif matrix == "vertical-cursor-after-edge":
            cases.extend(vertical_cursor_after_edge_matrix_cases())
        elif matrix == "cursor-up-selector-ownership":
            cases.extend(cursor_up_selector_ownership_matrix_cases())
        elif matrix == "cursor-down-vertical-region":
            cases.extend(cursor_down_vertical_region_matrix_cases())
        elif matrix == "selector-repetition":
            cases.extend(selector_repetition_matrix_cases())
        elif matrix == "vs16-overwrite-wide":
            cases.extend(vs16_overwrite_wide_matrix_cases())
        elif matrix == "vs16-overwrite-wide-active-left":
            cases.extend(vs16_overwrite_wide_active_left_matrix_cases())
        elif matrix == "origin-ri-wide-scalar":
            cases.extend(origin_ri_wide_scalar_matrix_cases())
        elif matrix == "origin-mode-line-motion":
            cases.extend(origin_mode_line_motion_matrix_cases())

    reference = CoreWorker(args.reference)
    candidate = CoreWorker(args.candidate)
    try:
        digest = hashlib.sha256()
        progress_interval = max(100, len(cases) // 20)
        for index, case in enumerate(cases, 1):
            expected = reference.run(case)
            actual = candidate.run(case)
            difference = first_difference(expected, actual)
            if difference:
                print(f"FAIL {case.name}: {difference}", file=sys.stderr)
                if not args.suppress_wire:
                    print("case=" + json.dumps(case_to_wire(case), separators=(",", ":")),
                          file=sys.stderr)
                if not args.no_minimize and args.minimize_probes > 0:
                    minimized, minimized_difference, probes = minimized_failure(
                        case, reference, candidate, difference, args.minimize_probes)
                    print(f"MINIMIZED probes={probes}: {minimized_difference}",
                          file=sys.stderr)
                    if not args.suppress_wire:
                        print("minimized_case=" + json.dumps(
                            case_to_wire(minimized), separators=(",", ":")), file=sys.stderr)
                return 1
            digest.update(json.dumps(actual, sort_keys=True, separators=(",", ":")).encode())
            if index % progress_interval == 0:
                print(f"checked {index}/{len(cases)}")
        print(f"CORE_BLACKBOX_PARITY cases={len(cases)} "
              f"sha256={digest.hexdigest()} ok=true")
        return 0
    finally:
        reference.close()
        candidate.close()


if __name__ == "__main__":
    raise SystemExit(main())
