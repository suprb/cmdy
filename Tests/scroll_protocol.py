"""Source-only draft of the fixed three-row, primary-buffer scroll protocol.

This module performs no process launch or native API call. Calibration is a
separate, unpooled requirement; these definitions do not assert native behavior.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import math
import re

CASE = "scroll"
GRID = (120, 36)
BLOCKS = 6
SAMPLES = 40
DISTANCE_ROWS = 3
HISTORY_ROWS = 1000
BARCODE_COLUMNS = 42
STABILITY_NS = 250_000_000


def validate_token(token: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{32}", token):
        raise ValueError("a generated 128-bit lowercase hex nonce is required")


def row_symbols(token: str, ordinal: int) -> list[int]:
    validate_token(token)
    if type(ordinal) is not int or not 0 <= ordinal < HISTORY_ROWS:
        raise ValueError("row is outside the preregistered generated history")
    row = f"{ordinal:04x}"
    checksum = hashlib.sha256(bytes.fromhex(token + row)).hexdigest()[:4]
    # Full nonce + ordinal + checksum, bounded by two distinct sentinels.
    return [-1] + [int(value, 16) for value in token + row + checksum] + [-2]


def symbol_color(symbol: int) -> tuple[int, int, int]:
    if symbol == -1:
        return 238, 40, 40
    if symbol == -2:
        return 40, 238, 40
    if not 0 <= symbol < 16:
        raise ValueError("unknown generated symbol")
    return 48 + symbol * 12, 100, 190


def row_bytes(token: str, ordinal: int) -> bytes:
    marker = "".join(f"\x1b[48;2;{r};{g};{b}m "
                     for r, g, b in map(symbol_color, row_symbols(token, ordinal)))
    body = f" row {ordinal:04d} generated scroll fixture "
    body += hashlib.sha256(f"{token}/{ordinal}".encode()).hexdigest()
    body = body[:GRID[0] - BARCODE_COLUMNS].ljust(GRID[0] - BARCODE_COLUMNS)
    # Exactly 120 cells; the setup phase explicitly disables autowrap. The
    # barcode cells are blank with solid true-color backgrounds. Text beside
    # them supplies ordinary glyph work, but is not claimed to be OCR-verified.
    return ("\x1b[0m" + marker + "\x1b[0m" + body).encode("ascii")


def payload(token: str) -> bytes:
    # All controls and output are outside the latency interval. The worker
    # never prints anything after its final, byte-accurate DSR acknowledgement.
    prefix = (b"\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l"
              b"\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?25l"
              b"\x1b[0m\x1b[3J\x1b[2J\x1b[H\x1b[?7l")
    rows = b"\r\n".join(row_bytes(token, row) for row in range(HISTORY_ROWS))
    return prefix + rows + b"\x1b[0m\x1b[?7h"


def viewport_rows(first_row: int) -> list[int]:
    if type(first_row) is not int or not 0 <= first_row <= HISTORY_ROWS - GRID[1]:
        raise ValueError("viewport leaves generated history")
    return list(range(first_row, first_row + GRID[1]))


def viewport_sha256(token: str, first_row: int) -> str:
    return hashlib.sha256(b"\r\n".join(
        row_bytes(token, row) for row in viewport_rows(first_row))).hexdigest()


def sample_plan() -> list[dict]:
    # Two excluded, individually acknowledged upward events move off the live
    # bottom. Measured work is then 20 upward + 20 downward three-row events.
    # Neither direction can hit a scrollback edge or the live-bottom fast path.
    first = HISTORY_ROWS - GRID[1] - 2 * DISTANCE_ROWS
    plan = []
    for sequence in range(SAMPLES):
        direction = -1 if sequence < SAMPLES // 2 else 1
        after = first + direction * DISTANCE_ROWS
        plan.append({"sequence": sequence, "direction": direction,
                     "beforeFirstRow": first, "afterFirstRow": after,
                     "rowsMoved": DISTANCE_ROWS,
                     "expectedRows": viewport_rows(after)})
        first = after
    return plan


def profile_overrides(terminal: str, profile: str) -> list[str]:
    if terminal not in ("cmdy", "ghostty") or profile not in ("matched", "cmdy-defaults"):
        raise ValueError("unknown app/profile")
    if profile == "cmdy-defaults":
        return []  # Preserve each app's existing scroll/smoothing policies.
    return ["scroll-speed = 1"] if terminal == "cmdy" else [
        "mouse-scroll-multiplier = discrete:1"]


@dataclass(frozen=True)
class WheelCalibration:
    terminal: str
    profile: str
    upward_raw_delta: int
    downward_raw_delta: int
    rows_per_event: int
    units: str
    is_continuous: bool
    source_sha256: str
    binary_sha256: str
    config_sha256: str
    raw_evidence_sha256: str
    status: str

    def validate(self) -> None:
        if self.terminal not in ("cmdy", "ghostty"):
            raise ValueError("unknown app")
        if self.profile not in ("matched", "cmdy-defaults"):
            raise ValueError("unknown profile")
        if self.status != "valid-unpooled-calibration":
            raise ValueError("native action calibration is missing or invalid")
        if (self.units != "line" or self.is_continuous is not False
                or self.rows_per_event != DISTANCE_ROWS):
            raise ValueError("calibration is not one discrete three-row wheel event")
        for delta in (self.upward_raw_delta, self.downward_raw_delta):
            if type(delta) is not int or not 1 <= abs(delta) <= 10:
                raise ValueError("native raw wheel delta must be a small nonzero integer")
        if self.upward_raw_delta * self.downward_raw_delta >= 0:
            raise ValueError("up/down event signs must oppose each other")
        for value in (self.source_sha256, self.binary_sha256,
                      self.config_sha256, self.raw_evidence_sha256):
            if not re.fullmatch(r"[0-9a-f]{64}", value):
                raise ValueError("missing calibration provenance")


def validate_paired_calibration(cmdy: WheelCalibration, ghostty: WheelCalibration) -> None:
    cmdy.validate()
    ghostty.validate()
    if (cmdy.terminal, ghostty.terminal) != ("cmdy", "ghostty") or cmdy.profile != ghostty.profile:
        raise ValueError("calibration pair/profile differs")
    if cmdy.profile == "matched" and (
            cmdy.upward_raw_delta != ghostty.upward_raw_delta
            or cmdy.downward_raw_delta != ghostty.downward_raw_delta):
        raise ValueError("matched profile requires identical native wheel event magnitudes")


def validate_frame_clock(before: int, after: int, display: int, callback: int,
                         query_finished: int, validation_finished: int,
                         numer: int, denom: int) -> dict:
    values = (before, after, display, callback, query_finished, validation_finished, numer, denom)
    if (any(type(value) is not int or not 0 < value < 2**64 for value in values[:6])
            or any(type(value) is not int or not 0 < value < 2**32 for value in values[6:])):
        raise ValueError("invalid native clock fields")
    if not before <= after <= validation_finished:
        raise ValueError("event post lies outside native observation")
    if not before < display <= validation_finished or not before <= callback <= query_finished <= validation_finished:
        raise ValueError("first matching frame lies outside native observation")
    # SC displayTime is a mach-absolute WindowServer event time. The public SDK
    # does not promise callback >= display; retain the signed offset unchanged.
    duration_ms = (display - before) * numer / denom / 1_000_000
    callback_offset_ms = (callback - display) * numer / denom / 1_000_000
    if not math.isfinite(duration_ms) or duration_ms <= 0:
        raise ValueError("nonpositive or nonfinite event-to-frame duration")
    return {"eventToCompleteViewportMS": duration_ms,
            "callbackMinusDisplayMS": callback_offset_ms}
