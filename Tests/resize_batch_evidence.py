"""Independent untimed viewport proofs used around a same-lifetime resize batch.

These helpers do not open the public resize admission gate.
"""
import base64
import binascii

from resize_calibration_evidence import validate_discovery, validate_display_capture
from resize_contract import OBSERVATION_SCOPE
from resize_evidence import integer, require, validate_proof
from resize_protocol import FIXTURE_VERSION, cell_classes_bytes, digest


def validate_frozen_view(value, nonce, sequence, display, discovery, *, after_ticks=0, before_ticks=None):
    validate_display_capture(display)
    geometry = validate_discovery(discovery, display)
    require(value["ok"] is True and value["op"] == "verify"
            and value["observationScope"] == OBSERVATION_SCOPE
            and type(value["fixtureVersion"]) is int and value["fixtureVersion"] == FIXTURE_VERSION
            and value["nonce"] == nonce and type(value["sequence"]) is int and value["sequence"] == sequence,
            "untimed viewport identity or scope differs")
    encoded = value["observedCellClasses"]
    require(type(encoded) is str and len(encoded) <= 7040, "untimed cell stream exceeds bound")
    try: raw = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error): raise ValueError("untimed cell stream is not base64") from None
    expected = cell_classes_bytes(nonce, sequence, geometry["columns"], geometry["rows"])
    require(raw == expected and type(value["matchedCells"]) is int and value["matchedCells"] == len(expected)
            and value["cellClassesSHA256"] == digest(raw), "untimed decoded cells differ")
    for key in ("beforeProof", "afterProof"):
        validate_proof(value[key], display, geometry["outerBounds"])
    callback = integer(value["callbackTicks"], "viewport callback", 1)
    shown = integer(value["displayTicks"], "viewport display", 1)
    checked = integer(value["checkedTicks"], "viewport validation", 1)
    minimum = integer(after_ticks, "viewport minimum")
    require(type(value["afterTicks"]) is int and value["afterTicks"] == minimum and shown >= minimum
            and callback <= value["beforeProof"]["queriedTicks"]
            <= value["afterProof"]["queriedTicks"] <= checked,
            "untimed viewport is stale or clock order differs")
    # SCK may deliver a frame before its display timestamp. Preserve both clocks;
    # an explicit upper boundary must enclose display and decode, not only callback.
    if before_ticks is not None:
        require(max(shown, checked) <= integer(before_ticks, "viewport upper boundary", 1),
                "untimed viewport does not precede the export")
    return dict(status="valid-untimed-frozen-viewport", qualifying=False,
                sequence=sequence, matchedCells=len(raw), cellClassesSHA256=digest(raw))
