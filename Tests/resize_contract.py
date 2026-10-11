"""Standalone resize admission boundary; complete campaigns use their own reader."""

OBSERVATION_SCOPE = "complete-generated-cell-viewport-v2"
BLOCKERS = (
    "A standalone event or pilot cannot establish complete paired campaign evidence.",
    "Use resize_parity_evidence.load_resize_evidence for the complete guarded six-pair campaign; caller flags cannot qualify an event.",
)


def blocked_status():
    return {"schemaVersion": 1, "fixtureVersion": 2, "case": "resize", "status": "blocked",
            "qualifying": False, "nativeReady": False,
            "observationScope": OBSERVATION_SCOPE, "blockers": list(BLOCKERS)}


def require_qualifying_adapter(*_untrusted_claims, **_untrusted_fields):
    """Neither a caller flag nor an old history/row-code receipt is an adapter."""
    raise ValueError("resize admission blocked: " + " ".join(BLOCKERS))
