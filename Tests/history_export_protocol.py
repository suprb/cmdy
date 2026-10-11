"""Generated-only public file-export contract; no terminal or native actions."""
from __future__ import annotations

import hashlib
import re

from memory_bench_payloads import numbered_rows
from resize_protocol import (GRIDS, HISTORY_BYTES, HISTORY_COLUMNS, HISTORY_LINES,
                             SEPARATOR_ROWS, check_nonce, frame_bytes, history)

SCHEMA = 1
PATH_LIMIT = 4096
FILE_LIMIT = 4 * 1024 * 1024
RECEIVE_SECONDS = 3
SHORTCUT = "ctrl+shift+enter"
KEY_CODE = 36
MODIFIER_FLAGS = 0x60000  # CGEventFlags control + shift; no command/option/fn.
ACTION = "write_scrollback_file:paste"
FILE_PROOF_SCOPE = "generated-file-transport-v2"
CASES = ("resize", "primary-1000", "primary-5000", "alternate-continuous")


def require(condition, code):
    if not condition:
        raise ValueError(code)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def expectation(case, nonce):
    check_nonce(nonce)
    require(case in CASES, "unknown-generated-case")
    if case == "resize":
        raw = history(nonce)
        assert len(raw) == HISTORY_BYTES
        count, width = HISTORY_LINES, HISTORY_COLUMNS
    else:
        count = {"primary-1000": 1000, "primary-5000": 5000,
                 "alternate-continuous": 35}[case]
        raw = numbered_rows(count, nonce[:16])
        width = 76
    return dict(schemaVersion=SCHEMA, case=case, nonce=nonce, columns=120, rows=36,
                logicalRows=count, logicalColumns=width, generatedBytes=len(raw),
                generatedSHA256=digest(raw), activeScreen="alternate" if case == "alternate-continuous" else "primary",
                normalization="CRLF-to-LF; trailing-ASCII-spaces; bounded-outer-empty-rows; exact-column-wrap-boundaries-only")


def resize_batch_expectation(nonce, phase, *, history_growth_guard=False):
    """Only the fixed two-calibration/42-event workload may add reflow padding.

    A 132-column styled-space row can become two 120-column rows. Each
    large-to-small transition can therefore leave at most 40 extra wrapped
    rows plus the four rows removed from the live viewport. Existing blank
    history may rejoin and split again, but is not newly generated content.
    The allowance is trailing-only and never skips an interior or text row.
    """
    require(phase in ("before", "after"), "unknown-resize-history-phase")
    require(type(history_growth_guard) is bool, "resize-growth-guard-type-differs")
    spec = expectation("resize", nonce)
    small, large = GRIDS
    extra_per_round_trip = large[1] * ((large[0] + small[0] - 1) // small[0] - 1) + large[1] - small[1]
    if history_growth_guard: extra_per_round_trip += large[1] - small[1]
    round_trips = 1 if phase == "before" else 22
    spec["resizeBatchPadding"] = dict(schemaVersion=1, phase=phase,
        calibrationTransitions=2, batchTransitions=0 if phase == "before" else 42,
        completedRoundTrips=round_trips, maximumExtraRowsPerRoundTrip=extra_per_round_trip,
        maximumTrailingEmptyRows=spec["rows"] + SEPARATOR_ROWS + 1 + round_trips * extra_per_round_trip)
    if history_growth_guard: spec["resizeBatchPadding"]["growthGuardRows"] = large[1] - small[1]
    return spec


def expected_bytes(spec):
    if "resizeBatchPadding" in spec:
        padding = spec["resizeBatchPadding"]
        require(type(padding) is dict and type(padding.get("phase")) is str
                and all(type(value) is int for key, value in padding.items() if key != "phase"),
                "resize-batch-padding-types-differ")
    canonical = (resize_batch_expectation(spec["nonce"], spec["resizeBatchPadding"]["phase"],
                    history_growth_guard="growthGuardRows" in spec["resizeBatchPadding"])
                 if "resizeBatchPadding" in spec else expectation(spec["case"], spec["nonce"]))
    require(spec == canonical, "generated-expectation-differs")
    return history(spec["nonce"]) if spec["case"] == "resize" else numbered_rows(spec["logicalRows"], spec["nonce"][:16])


def preparation_bytes(spec):
    raw = expected_bytes(spec)
    initial = b"\x1b[0m\x1b[?7h\x1b[?25l\x1b[?2004l\x1b[2J\x1b[H"
    if spec["case"] == "resize":
        return initial + raw + b"\r\n" * SEPARATOR_ROWS + frame_bytes(spec["nonce"], 0, *GRIDS[0])
    if spec["case"] == "alternate-continuous":
        return initial + b"\x1b[?1049h" + b"A" * 3_000_000 + b"\x1b[2J\x1b[H" + raw
    return initial + raw


def memory_payload(spec):
    require(spec["case"] != "resize", "drain-payload-is-memory-only")
    raw = expected_bytes(spec)
    if spec["case"] == "alternate-continuous":
        return b"\x1b[?1049h" + b"A" * 3_000_000 + b"\x1b[2J\x1b[H" + raw
    return raw


def validated_missing_row_counts(value):
    """Whitelist bounded counts only; no input, path, row text or hash."""
    fields = {"schemaVersion", "purpose", "qualifying", "expectedRows", "matchedPrefixRows", "expectedRowIndex",
              "physicalLineCount", "physicalCursor", "leadingEmptyRows", "trailingEmptyRows", "rawBytes"}
    try:
        if type(value) is not dict or set(value) != fields: return None
        if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
                or type(value["purpose"]) is not str or value["purpose"] != "missing-generated-row-prefix-counts"
                or value["qualifying"] is not False): return None
        if any(type(value[key]) is not int for key in fields - {"purpose", "qualifying"}): return None
        expected, matched = value["expectedRows"], value["matchedPrefixRows"]
        if expected not in (35, 1000, 5000) or not 0 <= matched < expected: return None
        # Only the 1000-row resize fixture can wrap one logical row over two
        # physical lines; the other generated cases use one physical line.
        chunks = 2 if expected == 1000 else 1
        padding = 36 + (SEPARATOR_ROWS if expected == 1000 else 0) + 1
        if (value["expectedRowIndex"] != matched
                or value["physicalCursor"] != value["physicalLineCount"]
                or not matched <= value["physicalLineCount"] <= matched * chunks
                or not 0 <= value["leadingEmptyRows"] <= padding
                or not 0 <= value["trailingEmptyRows"] <= padding
                or not 0 < value["rawBytes"] <= FILE_LIMIT
                or value["physicalLineCount"] + value["leadingEmptyRows"] + value["trailingEmptyRows"] > value["rawBytes"] + 1): return None
        return dict(value)
    except Exception:
        return None


def missing_row_metadata(failure):
    if type(failure) is not ValueError or str(failure) != "missing-generated-row": return None
    return validated_missing_row_counts(getattr(failure, "_cmdy_missing_row_counts", None))


def row_split_metadata(failure):
    """Expose only bounded counts from a rejected resize export, never its text."""
    if type(failure) is not ValueError or str(failure) != "generated-row-content-order-or-wrap-differs": return None
    value = getattr(failure, "_cmdy_row_split_counts", None)
    fields = {"schemaVersion", "purpose", "qualifying", "expectedRowIndex", "physicalCursor",
              "physicalContentRows", "nextLineLengths", "exactExpectedRowSplitLengths"}
    if type(value) is not dict or set(value) != fields: return None
    if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or value["purpose"] != "rejected-resize-row-split-counts" or value["qualifying"] is not False): return None
    if any(type(value[k]) is not int for k in ("expectedRowIndex", "physicalCursor", "physicalContentRows")): return None
    if not (0 <= value["expectedRowIndex"] < 1000
            and 0 <= value["physicalCursor"] < value["physicalContentRows"] <= 4000): return None
    for key in ("nextLineLengths", "exactExpectedRowSplitLengths"):
        lengths = value[key]
        if type(lengths) is not list or len(lengths) > 3 or any(type(x) is not int or not 0 <= x <= FILE_LIMIT for x in lengths): return None
    exact = value["exactExpectedRowSplitLengths"]
    if exact and (any(x == 0 for x in exact) or sum(exact) != HISTORY_COLUMNS
                  or value["nextLineLengths"][:len(exact)] != exact): return None
    return dict(value)


def validate_export_bytes(raw, spec):
    """Every nonpadding byte must belong to one complete expected logical row.

    A logical-row exporter and a physical-row exporter may differ only at the
    grid's exact wrap boundaries. Missing/extra/duplicated/interior-blank rows,
    arbitrary newline removal, glyph substitutions and other text are rejected.
    """
    expected = expected_bytes(spec).decode("ascii").split("\r\n")[:-1]
    require(isinstance(raw, bytes) and 0 < len(raw) <= FILE_LIMIT, "export-size-outside-bound")
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeError:
        raise ValueError("export-is-not-generated-utf8") from None
    text = text.replace("\r\n", "\n")
    require(re.fullmatch(r"[\x20-\x7e\n]*", text) is not None, "export-has-ungenerated-controls-or-text")
    physical = [line.rstrip(" ") for line in text.split("\n")]
    padding_limit = spec["rows"] + (SEPARATOR_ROWS if spec["case"] == "resize" else 0) + 1
    trailing_limit = spec.get("resizeBatchPadding", {}).get("maximumTrailingEmptyRows", padding_limit)
    require(len(physical) <= len(expected) * ((spec["logicalColumns"] + spec["columns"] - 1) // spec["columns"])
            + padding_limit + trailing_limit, "export-physical-line-bound")
    leading = 0
    while physical and physical[0] == "":
        physical.pop(0); leading += 1
    trailing = 0
    while physical and physical[-1] == "":
        physical.pop(); trailing += 1
    require(leading <= padding_limit and trailing <= trailing_limit, "outer-padding-exceeds-generated-bound")
    cursor, wrapped = 0, 0
    for expected_index, row in enumerate(expected):
        try:
            require(cursor < len(physical), "missing-generated-row")
        except ValueError as failure:
            try:
                if type(failure) is ValueError and str(failure) == "missing-generated-row":
                    counts = validated_missing_row_counts(dict(schemaVersion=1,
                        purpose="missing-generated-row-prefix-counts", qualifying=False,
                        expectedRows=len(expected), matchedPrefixRows=expected_index, expectedRowIndex=expected_index,
                        physicalLineCount=len(physical), physicalCursor=cursor,
                        leadingEmptyRows=leading, trailingEmptyRows=trailing, rawBytes=len(raw)))
                    if counts is not None: failure._cmdy_missing_row_counts = counts
            except Exception:
                pass  # The same original guard error must survive diagnostics.
            raise
        if physical[cursor] == row:
            cursor += 1
            continue
        chunks = [row[index:index + spec["columns"]] for index in range(0, len(row), spec["columns"])]
        if not (len(chunks) > 1 and physical[cursor:cursor + len(chunks)] == chunks):
            failure = ValueError("generated-row-content-order-or-wrap-differs")
            if "resizeBatchPadding" in spec:
                following = physical[cursor:cursor + 3]
                exact = next(([len(x) for x in following[:n]] for n in range(1, len(following) + 1)
                              if all(following[:n]) and "".join(following[:n]) == row), [])
                failure._cmdy_row_split_counts = dict(schemaVersion=1,
                    purpose="rejected-resize-row-split-counts", qualifying=False,
                    expectedRowIndex=expected_index, physicalCursor=cursor, physicalContentRows=len(physical),
                    nextLineLengths=[len(x) for x in following], exactExpectedRowSplitLengths=exact)
            raise failure
        cursor += len(chunks); wrapped += 1
    require(cursor == len(physical), "extra-generated-or-unrecognized-row")
    normalized = ("\n".join(expected) + "\n").encode()
    return dict(logicalRows=len(expected), logicalColumns=spec["logicalColumns"],
                physicalContentRows=len(physical), wrappedLogicalRows=wrapped,
                leadingEmptyRows=leading, trailingEmptyRows=trailing,
                normalizedSHA256=digest(normalized), rawBytes=len(raw), rawSHA256=digest(raw))
