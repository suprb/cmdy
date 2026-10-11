"""Pure reconstruction of the versioned same-frame complete startup viewport proof.

Never imports artifact code, reads a display, launches a process, or substitutes a
later ioctl for raster geometry. Only validated generated viewport pixels occur
in the lossless RLE; there are no screenshots or unrelated terminal contents.
"""
from __future__ import annotations
import hashlib
import math
import re
from startup_grid import Witness, TARGET_GRID, canonical, witness_digest

PROTOCOL = "startup-full-generated-viewport-v5"
FOREGROUND_METHOD = "system-wide-AXFocusedApplication-bracketed-PID"


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def hash_value(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def witness(value, token):
    require(isinstance(value, dict) and set(value) ==
            {"token", "columns", "rows", "generation", "frameKind"}, "incomplete visible grid codec")
    result = Witness(value["token"], value["columns"], value["rows"],
                     value["generation"], value["frameKind"])
    result.validate()
    require(result.token == token, "foreign visible launch nonce")
    return result


def raster(value, columns, rows):
    require(isinstance(value, dict) and set(value) ==
            {"width", "height", "xEdges", "yEdges", "sampleInsetPixels", "edgeRoundingPixels"},
            "incomplete full-grid raster")
    require(value["sampleInsetPixels"] == 2 and value["edgeRoundingPixels"] == 1,
            "changed uniform edge sampling/rounding")
    for name, size, axis in (("xEdges", columns, "width"), ("yEdges", rows, "height")):
        edges, limit = value[name], value[axis]
        require(type(limit) is int and 1 <= limit <= 16384 and isinstance(edges, list)
                and len(edges) == size + 1 and all(type(edge) is int for edge in edges),
                "missing declared row/column edges")
        gaps = [b - a for a, b in zip(edges, edges[1:])]
        require(0 <= edges[0] < edges[-1] <= limit and all(5 <= gap <= 100 for gap in gaps)
                and max(gaps) - min(gaps) <= 2, "nonfinite, missing or nonuniform cell boundary")
    return value


def raster_agrees(actual, expected):
    return (all(actual[key] == expected[key] for key in
                ("width", "height", "sampleInsetPixels", "edgeRoundingPixels"))
            and all(len(actual[axis]) == len(expected[axis])
                    and all(abs(a - b) <= 1 for a, b in zip(actual[axis], expected[axis]))
                    for axis in ("xEdges", "yEdges")))


def bounds(value):
    require(isinstance(value, dict) and set(value) == {"x", "y", "width", "height"}
            and all(type(part) in (int, float) and math.isfinite(part) for part in value.values())
            and value["width"] > 0 and value["height"] > 0, "invalid native window/display bounds")
    return value


def validate_proof(value, token):
    require(isinstance(value, dict) and set(value) ==
            {"witness", "raster", "checkedCells", "checkedPixels", "generatedSHA256",
             "checkedPixelsSHA256", "checkedPixelRuns"}, "incomplete generated viewport pixel proof")
    visible = witness(value["witness"], token)
    geometry = raster(value["raster"], visible.columns, visible.rows)
    cells = visible.cells()
    require(value["checkedCells"] == len(cells) == visible.columns * visible.rows
            and value["generatedSHA256"] == witness_digest(visible),
            "missing row/column or substituted generated viewport")
    expected_count = sum((geometry["xEdges"][x + 1] - geometry["xEdges"][x] - 4)
                         * (geometry["yEdges"][y + 1] - geometry["yEdges"][y] - 4) for x, y in cells)
    require(type(value["checkedPixels"]) is int and value["checkedPixels"] == expected_count
            and 1 <= expected_count <= 10_000_000, "sampled viewport pixel count differs")
    runs = value["checkedPixelRuns"]
    require(isinstance(runs, list) and 1 <= len(runs) <= min(expected_count, 100_000)
            and all(isinstance(run, list) and len(run) == 5 and all(type(v) is int for v in run)
                    and 1 <= run[0] <= expected_count and all(0 <= v <= 255 for v in run[1:])
                    for run in runs) and sum(run[0] for run in runs) == expected_count,
            "missing, excessive or lossy checked-pixel RLE")
    require(all(a[1:] != b[1:] for a, b in zip(runs, runs[1:])), "noncanonical checked-pixel RLE")
    index, remaining, hasher = 0, runs[0][0], hashlib.sha256()
    for (x, y), (red, green, blue) in cells.items():
        count = ((geometry["xEdges"][x + 1] - geometry["xEdges"][x] - 4)
                 * (geometry["yEdges"][y + 1] - geometry["yEdges"][y] - 4))
        while count:
            run = runs[index]
            require(abs(run[1] - blue) <= 3 and abs(run[2] - green) <= 3
                    and abs(run[3] - red) <= 3 and run[4] >= 250,
                    "captured generated cell pixel differs from nonce/grid/generation")
            take = min(count, remaining)
            hasher.update(bytes(run[1:]) * take)
            count -= take
            remaining -= take
            if not remaining:
                index += 1
                if index < len(runs):
                    remaining = runs[index][0]
    require(index == len(runs) and remaining == 0
            and value["checkedPixelsSHA256"] == hasher.hexdigest(), "checked generated pixel digest differs")
    return visible
