"""Pure same-frame startup witness protocol; no process or terminal access."""
from dataclasses import dataclass
import hashlib
import json
import re
import zlib

HEADER_VERSION = 3
HEADER_CELLS = 42
TARGET_GRID = (98, 29)
MAX_GENERATION = 64
COLOR_TOLERANCE = 3
EDGE_ROUNDING_PIXELS = 1
START = (238, 40, 40)
END = (40, 238, 40)


@dataclass(frozen=True)
class Witness:
    token: str
    columns: int
    rows: int
    generation: int
    frame_kind: int

    def validate(self):
        if (not isinstance(self.token, str) or re.fullmatch('[0-9a-f]{32}', self.token) is None
                or type(self.columns) is not int or not 44 <= self.columns <= 255
                or type(self.rows) is not int or not 4 <= self.rows <= 255
                or type(self.generation) is not int or not 1 <= self.generation <= MAX_GENERATION
                or type(self.frame_kind) is not int or self.frame_kind != 1):
            raise ValueError('invalid bounded generated grid witness')

    def payload(self):
        self.validate()
        return f'{HEADER_VERSION:x}{self.token}{self.columns:02x}{self.rows:02x}{self.generation:02x}{self.frame_kind:x}'

    def header_colors(self):
        return [START, *[(48 + int(c, 16) * 12, 100, 190) for c in self.payload()], END]

    def cell_color(self, x, y):
        self.validate()
        if not 0 <= x < self.columns or not 0 <= y < self.rows:
            raise ValueError('cell lies outside declared generated grid')
        if y == 0 and x < HEADER_CELLS:
            return self.header_colors()[x]
        if y not in (0, self.rows - 1) and x not in (0, self.columns - 1):
            code = zlib.crc32(f"{self.payload()}/{x:04x}/{y:04x}".encode()) & 15
            return (36 + code % 4 * 48, 36 + code // 4 * 48, 212)
        phase = (x + y) % 3
        component = ((self.generation - 1) >> (2 * phase)) & 3
        return (55 + 50 * component, 55 + 110 * ((x + y) % 2), 55 + 50 * phase)

    def cells(self):
        return {(x,y): self.cell_color(x,y) for y in range(self.rows) for x in range(self.columns)}

    def frame_bytes(self):
        self.validate()
        parts = [b"\x1b[?25l\x1b[?7l\x1b[r\x1b[0m\x1b[2J"]
        for y in range(self.rows):
            parts.append(f"\x1b[{y+1};1H".encode())
            for x in range(self.columns):
                r,g,b = self.cell_color(x,y)
                parts.append(f"\x1b[48;2;{r:03d};{g:03d};{b:03d}m ".encode())
        parts.append(b"\x1b[0m")
        return b"".join(parts)


def decode(payload, token):
    if (not isinstance(payload, str) or re.fullmatch('[0-9a-f]{40}', payload) is None
            or int(payload[0], 16) != HEADER_VERSION or payload[1:33] != token):
        raise ValueError('incomplete/foreign/version-mismatched visible witness')
    result = Witness(token, int(payload[33:35], 16), int(payload[35:37], 16),
                     int(payload[37:39], 16), int(payload[39], 16))
    result.validate()
    return result


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def witness_digest(witness):
    return hashlib.sha256(canonical({'header': witness.payload(), 'cells': [
        [x, y, *color] for (x, y), color in witness.cells().items()]})).hexdigest()
