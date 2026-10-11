"""Reconstruct v2 calibration geometry from its exact native discovery preimage."""
from __future__ import annotations

import hashlib
import json
import math

from resize_protocol import FIXTURE_VERSION, PALETTE, START_RGB, END_RGB, check_nonce, check_sequence, check_grid


def require(condition, message):
    if not condition: raise ValueError("resize calibration: " + message)


def number(value, name, minimum=None):
    require(type(value) in (int, float) and math.isfinite(value), "invalid " + name)
    require(minimum is None or value >= minimum, "out-of-range " + name)
    return value


def integer(value, name, minimum=0):
    require(type(value) is int and minimum <= value <= (1 << 63) - 1, "invalid " + name)
    return value


def rectangle(value):
    for field in ("x", "y", "width", "height"):
        number(value[field], field, 1 if field in ("width", "height") else None)
    return value


def validate_display_mode(value):
    require(set(value) == {"modeID", "flags", "width", "height", "pixelWidth", "pixelHeight",
                           "refreshRate", "rotation"}, "display mode signature differs")
    for field in ("modeID", "flags"):
        require(integer(value[field], field) <= 0xffffffff, "display mode field exceeds uint32")
    for field in ("width", "height", "pixelWidth", "pixelHeight"):
        integer(value[field], field, 1)
    number(value["refreshRate"], "refresh rate", 0)
    require(number(value["rotation"], "display rotation") == 0, "unsupported display rotation")
    return value


def validate_display_capture(display):
    mode = validate_display_mode(display["displayMode"])
    rectangle(display["displayBounds"])
    require(integer(display["captureWidth"], "capture width", 1) == mode["pixelWidth"]
            and integer(display["captureHeight"], "capture height", 1) == mode["pixelHeight"]
            and number(display["displayRefreshRate"], "announced refresh rate", 0) == mode["refreshRate"]
            and integer(display["requestedFPS"], "requested capture rate", 1) == 120,
            "native capture does not match its pinned display mode")


def validate_discovery(result, observed_display=None, before_ticks=None):
    """No pixels are invented: the pinned native discovery checks those in memory.

    This reconstructs geometry, palette bounds and hash bindings independently;
    it is not proof that a synthetic calibration came from a live application.
    """
    raw = result["evidenceUTF8"]
    require(isinstance(raw, str) and len(raw.encode()) <= 256 * 1024, "unbounded preimage")
    expected_hash = hashlib.sha256(raw.encode()).hexdigest()
    geometry = result["calibration"]
    require(expected_hash == result["evidenceSHA256"] == geometry["discoveryEvidenceSHA256"],
            "discovery preimage or bound hash differs")
    evidence = json.loads(raw)
    require(type(geometry["fixtureVersion"]) is int
            and geometry["fixtureVersion"] == evidence["fixtureVersion"] == FIXTURE_VERSION,
            "v1/unknown calibration cannot be relabeled v2")
    check_nonce(evidence["nonce"]); check_sequence(evidence["sequence"])
    columns, rows = check_grid(evidence["columns"], evidence["rows"])
    require((geometry["columns"], geometry["rows"]) == (columns, rows), "target dimensions differ")
    integer(evidence["displayTicks"], "display clock", 1)
    width = integer(evidence["captureWidth"], "capture width", 1)
    height = integer(evidence["captureHeight"], "capture height", 1)
    display = rectangle(evidence["displayBounds"])
    mode = validate_display_mode(evidence["displayMode"])
    window = rectangle(evidence["window"]["bounds"])
    require(geometry["outerBounds"] == window and geometry["displayBounds"] == display
            and geometry["captureWidth"] == width and geometry["captureHeight"] == height
            and geometry["displayMode"] == mode
            and width == mode["pixelWidth"] and height == mode["pixelHeight"],
            "capture or owned window differs")
    require(display["x"] <= window["x"] and display["y"] <= window["y"]
            and window["x"] + window["width"] <= display["x"] + display["width"]
            and window["y"] + window["height"] <= display["y"] + display["height"],
            "window extends outside display")
    require(evidence["window"].get("proofScope") is None and evidence["window"].get("schemaVersion") is None
            and evidence["window"]["occluded"] is False
            and evidence["window"]["foregroundPID"] == evidence["window"]["identity"]["pid"],
            "discovery lacks visible owned window")
    integer(evidence["window"]["queriedTicks"], "window proof clock", 1)
    if observed_display is not None:
        validate_display_capture(observed_display)
        require(display == observed_display["displayBounds"] and mode == observed_display["displayMode"]
                and width == observed_display["captureWidth"] and height == observed_display["captureHeight"],
                "calibration and observed display capture differ")
        owner = evidence["window"]
        require(owner["identity"] == observed_display["identity"]
                and integer(owner["windowID"], "calibration window", 1) == observed_display["windowID"]
                and integer(owner["displayID"], "calibration display", 1) == observed_display["displayID"],
                "calibration and observed app/window/display identity differ")
    if before_ticks is not None:
        require(max(evidence["displayTicks"], evidence["window"]["queriedTicks"])
                < integer(before_ticks, "native request start", 1),
                "calibration is not strictly before the measured request")
    left = integer(evidence["markerLeft"], "left sentinel")
    right = integer(evidence["markerRight"], "right sentinel", left + columns * 3)
    bands = evidence["rowBands"]
    require(len(bands) == rows, "not every row has a band")
    previous = -1
    for band in bands:
        first = integer(band["first"], "row band start", previous + 1)
        previous = integer(band["last"], "row band end", first + 4)
        require(previous < height, "row band extends outside capture")
    cell = (right - left) / columns
    pitch = (bands[-1]["first"] - bands[0]["first"]) / (rows - 1)
    interior = min(band["last"] - band["first"] + 1 for band in bands)
    offsets = [interior * .25, interior * .5, interior * .75]
    sx, sy = width / display["width"], height / display["height"]
    x = left - (window["x"] - display["x"]) * sx
    y = bands[0]["first"] - (window["y"] - display["y"]) * sy
    require(pitch >= interior and offsets[-1] < pitch - 1
            and x >= 0 and y >= 0
            and x + columns * cell <= window["width"] * sx
            and y + rows * pitch <= window["height"] * sy + 1,
            "entire generated viewport does not fit owned crop")
    for name, actual in (("xWithinWindowPixels", x), ("yWithinWindowPixels", y),
                         ("cellWidthPixels", cell), ("rowPitchPixels", pitch), ("rowSampleOffsets", offsets)):
        require(geometry[name] == actual, "derived " + name + " differs")
    require(type(geometry["tolerance"]) is int and geometry["tolerance"] == evidence["frozenMatchTolerance"] == 3
            and evidence["discoveryNominalTolerance"] == 12, "frozen palette tolerances differ")
    require(integer(evidence["maximumColorDeviation"], "maximum color deviation") <= 3,
            "unstable observed palette")
    colors = evidence["sampledColors"]
    require(geometry["colors"] == colors and len(colors) == 18, "palette is incomplete or differs")
    values = []
    for color, nominal in zip(colors, PALETTE + (START_RGB, END_RGB)):
        value = tuple(integer(color[field], "color channel") for field in ("red", "green", "blue"))
        require(all(channel <= 255 for channel in value)
                and max(abs(a-b) for a,b in zip(value, nominal)) <= 12, "palette differs from nominal discovery bound")
        values.append(value)
    require(all(max(abs(a-b) for a,b in zip(left, right)) > 12
                for index, left in enumerate(values) for right in values[index+1:]), "ambiguous palette")
    return geometry
