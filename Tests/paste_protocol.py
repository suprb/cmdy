"""Fixed clipboard-free paste-insertion protocol. No native calls on import.

The payload is known synthetic data. The visual response is generated only
after the worker has verified every byte and the terminal's bracket framing.
Worker receipt/emit times are diagnostics, never the measured endpoint.
"""
from __future__ import annotations

import hashlib
from scroll_protocol import GRID, row_symbols as base_symbols, symbol_color, validate_token, viewport_rows

CASE = "input/paste"
METRIC = "public-apple-event-paste-insertion-to-first-complete-response-viewport"
BLOCKS = 6
SAMPLES = 40
WARMUPS = 2
INITIAL_SETTLE_NS = 5_000_000_000
PAYLOAD_BYTES = 65_536
GUARD_NS = 250_000_000
INITIAL_ROW = 964
OFF_ROW = 963
ENABLED_ROW = 962
EVENT_CLASS = "Ghst"
EVENT_ID = "InTx"
TARGET_KEY = "GItT"
TERMINAL_CLASS = "Gtrm"
BARCODE_COLUMNS = 120
START = b"\x1b[200~"
END = b"\x1b[201~"


def row_symbols(token: str, ordinal: int) -> list[int]:
    # All 120 cells participate. Repeat nonce/ordinal/checksum across the row;
    # distinct first/last sentinel cells permit automatic full-width calibration.
    code = base_symbols(token, ordinal)[1:-1]
    return [-1] + (code * 3)[:118] + [-2]


def row_bytes(token: str, ordinal: int) -> bytes:
    marker = "".join(f"\x1b[48;2;{r};{g};{b}m "
                     for r, g, b in map(symbol_color, row_symbols(token, ordinal)))
    return ("\x1b[0m" + marker + "\x1b[0m").encode("ascii")


def viewport_sha256(token: str, first_row: int) -> str:
    return hashlib.sha256(b"\r\n".join(row_bytes(token, row) for row in viewport_rows(first_row))).hexdigest()


def paste_payload(token: str, sequence: int) -> bytes:
    validate_token(token)
    if type(sequence) is not int or not 1 <= sequence <= WARMUPS + SAMPLES:
        raise ValueError("paste sequence is outside the fixed run")
    prefix = f"CMDYPASTE/{token}/{sequence:02d}/".encode("ascii")
    pattern = "terminal-λ世界🙂0123456789 ".encode("utf-8")
    count, remainder = divmod(PAYLOAD_BYTES - len(prefix), len(pattern))
    result = prefix + pattern * count + b"x" * remainder
    assert len(result) == PAYLOAD_BYTES and result.decode("utf-8").encode("utf-8") == result
    return result


def off_probe(token: str) -> bytes:
    validate_token(token)
    return f"CMDYPASTE-OFF/{token}/".encode("ascii")


def wire_bytes(token: str, sequence: int) -> bytes:
    return off_probe(token) if sequence == 0 else START + paste_payload(token, sequence) + END


def response_first_row(sequence: int) -> int:
    if type(sequence) is not int or not 0 <= sequence <= WARMUPS + SAMPLES:
        raise ValueError("unknown paste sequence")
    return OFF_ROW if sequence == 0 else sequence - 1


def viewport_bytes(token: str, first_row: int) -> bytes:
    viewport_sha256(token, first_row)  # Validate the complete registered range.
    # Explicit row addressing avoids scrollback, autowrap, or newline mappings.
    return b"".join(f"\x1b[{row + 1};1H".encode() + row_bytes(token, first_row + row)
                    for row in range(GRID[1])) + b"\x1b[0m"


def preparation(token: str) -> bytes:
    controls = (b"\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l"
                b"\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?2004l\x1b[?25l"
                b"\x1b[0m\x1b[3J\x1b[2J\x1b[H\x1b[?7l")
    return controls + viewport_bytes(token, INITIAL_ROW)


def expected_receipt(token: str, sequence: int) -> dict:
    payload = off_probe(token) if sequence == 0 else paste_payload(token, sequence)
    wire = wire_bytes(token, sequence)
    first = response_first_row(sequence)
    return {"sequence": sequence, "bracketed": sequence != 0,
            "payloadBytes": len(payload), "payloadSHA256": hashlib.sha256(payload).hexdigest(),
            "wireBytes": len(wire), "wireSHA256": hashlib.sha256(wire).hexdigest(),
            "responseFirstRow": first, "responseViewportSHA256": viewport_sha256(token, first),
            "responseBytes": len(viewport_bytes(token, first)),
            "responseSHA256": hashlib.sha256(viewport_bytes(token, first)).hexdigest()}


class ExactPasteReceiver:
    """Single expected paste; rejects a prefix mismatch or trailing input.

    No arbitrary received bytes are exposed in evidence or error strings.
    The controller only arms the next paste after the prior visible response.
    """
    def __init__(self, token: str, sequence: int):
        self.expected = wire_bytes(token, sequence)
        self.count = 0

    def feed(self, data: bytes) -> bool:
        if not data or len(data) > len(self.expected) - self.count:
            raise ValueError("unexpected paste input length")
        if data != self.expected[self.count:self.count + len(data)]:
            raise ValueError("paste bytes or bracket framing differ")
        self.count += len(data)
        return self.count == len(self.expected)
