"""Version 2 resize fixture: independently checkable colors in every viewport cell."""
from __future__ import annotations

import hashlib
import re
import zlib

GRIDS = ((120, 36), (132, 40))
FIXTURE_VERSION = 2
MAX_EVENTS = 64
MAX_SEQUENCE = 0xFFFFFFFF
HISTORY_LINES = 1_000
HISTORY_COLUMNS = 145
HISTORY_BYTES = 147_000
SEPARATOR_ROWS = 36
GROWTH_GUARD_ROWS = GRIDS[1][1] - GRIDS[0][1]
START_RGB = (242, 36, 36)
END_RGB = (36, 242, 36)
# Blue is constant and differs from both sentinels. Adjacent classes are 48
# channel units apart; thresholds must be frozen by calibration, never timing.
PALETTE = tuple((36 + (value % 4) * 48, 36 + (value // 4) * 48, 212)
                for value in range(16))
RESTORE = b"\x1b[0m\x1b[?7h\x1b[?25h"


def check_nonce(value: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise ValueError("nonce must be 128-bit lowercase hexadecimal")
    return value


def check_sequence(value: int) -> int:
    if type(value) is not int or not 0 <= value <= MAX_SEQUENCE:
        raise ValueError("sequence must be an unsigned 32-bit integer")
    return value


def check_grid(columns: int, rows: int) -> tuple[int, int]:
    if type(columns) is not int or type(rows) is not int or (columns, rows) not in GRIDS:
        raise ValueError("grid must be exactly 120x36 or 132x40")
    return columns, rows


def history(nonce: str) -> bytes:
    check_nonce(nonce)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    rows = []
    for row in range(HISTORY_LINES):
        prefix = f"CMDY_RESIZE_{nonce}_ROW_{row:06d}|"
        rows.append((prefix + "".join(alphabet[(row * 17 + column) % len(alphabet)]
            for column in range(HISTORY_COLUMNS - len(prefix))) + "\r\n").encode("ascii"))
    return b"".join(rows)


def visible_row(nonce: str, sequence: int, columns: int, rows: int, row: int) -> bytes:
    row_word(nonce, sequence, columns, rows, row)  # Shared bounds validation.
    return b" " * columns


def row_word(nonce: str, sequence: int, columns: int, rows: int, row: int) -> str:
    check_nonce(nonce); check_sequence(sequence); check_grid(columns, rows)
    if type(row) is not int or not 0 <= row < rows:
        raise ValueError("row ordinal is outside the target")
    payload = f"{nonce}{sequence:08x}{columns:04x}{rows:04x}{row:04x}"
    return payload + f"{zlib.crc32(payload.encode('ascii')):08x}"


def row_classes(nonce: str, sequence: int, columns: int, rows: int, row: int):
    word = row_word(nonce, sequence, columns, rows, row)
    # Existing 60-digit identity+CRC occupies columns 1...60. Every remaining
    # interior column depends on that word and its own absolute column number.
    tail = tuple(zlib.crc32(f"{word}/{column:04x}".encode("ascii")) & 15
                 for column in range(61, columns - 1))
    return (16,) + tuple(int(digit, 16) for digit in word) + tail + (17,)


def row_colors(nonce: str, sequence: int, columns: int, rows: int, row: int):
    palette = PALETTE + (START_RGB, END_RGB)
    return tuple(palette[index] for index in row_classes(nonce, sequence, columns, rows, row))


def cell_classes_bytes(nonce: str, sequence: int, columns: int, rows: int):
    return bytes(index for row in range(rows) for index in row_classes(nonce, sequence, columns, rows, row))


def decode_word(word: str) -> dict:
    if not isinstance(word, str) or re.fullmatch(r"[0-9a-f]{60}", word) is None:
        raise ValueError("barcode word must have 60 hex digits")
    if zlib.crc32(word[:52].encode("ascii")) != int(word[52:], 16):
        raise ValueError("barcode CRC mismatch")
    nonce, sequence = word[:32], int(word[32:40], 16)
    columns, rows, row = int(word[40:44], 16), int(word[44:48], 16), int(word[48:52], 16)
    check_grid(columns, rows)
    if row >= rows:
        raise ValueError("barcode row is outside grid")
    return dict(nonce=nonce, sequence=sequence, columns=columns, rows=rows, row=row)


def growth_guard_enabled(receipt: dict) -> bool:
    rows = receipt.get("historyGrowthGuardRows", 0)
    if type(rows) is not int or rows not in (0, GROWTH_GUARD_ROWS):
        raise ValueError("history growth guard must be absent/zero or exactly four rows")
    return rows == GROWTH_GUARD_ROWS


def frame_bytes(nonce: str, sequence: int, columns: int, rows: int, *, history_growth_guard=False) -> bytes:
    """Neutral full-width spaces first, then every colored cell. No history erase."""
    check_nonce(nonce); check_sequence(sequence); check_grid(columns, rows)
    if type(history_growth_guard) is not bool:
        raise ValueError("history growth guard option must be boolean")
    value = bytearray(b"\x1b[?25l\x1b[?7l\x1b[r\x1b[0m")
    if history_growth_guard and (columns, rows) == GRIDS[1]:
        # Growth can expose scrollback at the top of the live viewport. Return
        # those exact four rows to history before erase/repaint can overwrite them.
        value += f"\x1b[{rows};1H".encode() + b"\r\n" * GROWTH_GUARD_ROWS
    value += b"\x1b[2J"
    for row in range(rows):
        text = visible_row(nonce, sequence, columns, rows, row)
        value += (f"\x1b[{row + 1};1H\x1b[38;2;180;180;180m"
                  "\x1b[48;2;024;024;024m").encode() + text
    for row in range(rows):
        value += f"\x1b[{row + 1};1H".encode()
        for red, green, blue in row_colors(nonce, sequence, columns, rows, row):
            value += f"\x1b[48;2;{red:03d};{green:03d};{blue:03d}m ".encode()
    value += b"\x1b[0m"
    return bytes(value)


def sequence_plan(block: int) -> list[dict]:
    if type(block) is not int or not 0 <= block < 6:
        raise ValueError("exactly six blocks are preregistered")
    # Calibration uses another nonce; each process pair shares these bytes.
    return [dict(sequence=1 + block * 42 + index,
                 columns=GRIDS[(index + 1) % 2][0], rows=GRIDS[(index + 1) % 2][1],
                 warmup=index < 2) for index in range(42)]


class ArmState:
    """Pure at-most-once SIGWINCH authorization seam."""
    def __init__(self):
        self.pending = None
        self.last_sequence = -1
        self.completed = 0

    def arm(self, sequence, target, current, signal_counter):
        check_sequence(sequence)
        target, current = check_grid(*target), check_grid(*current)
        if type(signal_counter) is not int or signal_counter < 0:
            raise ValueError("signal counter must be a nonnegative integer")
        if self.pending is not None or sequence <= self.last_sequence or target == current:
            raise ValueError("arm must be new, singular and change calibrated grid")
        if self.completed >= MAX_EVENTS:
            raise ValueError("event count bound reached")
        self.pending = dict(sequence=sequence, target=target, signalCounter=signal_counter)
        self.last_sequence = sequence

    def resize(self, signal_counter, current):
        value = self.pending
        if value is None or signal_counter <= value["signalCounter"] or current != value["target"]:
            return None
        self.pending = None
        self.completed += 1
        return value


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
