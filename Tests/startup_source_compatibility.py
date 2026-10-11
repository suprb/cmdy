"""Exact startup-reader compatibility; never relax native collection pins."""
import hashlib
from pathlib import Path

INVENTORY = "c9d7744ec0fd487bf6049b1421b7905f231995ea232626d6d986748dbbc0a3de"
FROZEN_GATE = "6253171989d01b6a348afab300cff479710859bff06fd1c8bb41e45ddc8da87a"
FROZEN_CONTRACT = "6e3a659ac2a1607b23bde80e82322ec2f5d314ba49db6fe5314b699e9c7f2c52"
# Startup uses its own Witness.frame_bytes. Its unchanged display validator
# imports this module, whose only edits add an opt-in resize repaint guard.
FROZEN_RESIZE_PROTOCOL = "98d604a91c2979146da3eca06219f345c68accf7359fdf369415561d8110b7cf"
GUARDED_RESIZE_PROTOCOL = "813282f6634ac45b864c8e4f64eba14a7e9a3803eee4f952a77c88c747bdd83a"
GATE_ADDITION = b'''            elif benchmark_kind == "resize-full-viewport-campaign-v1":
                from resize_parity_evidence import load_resize_evidence
                items = load_resize_evidence(path, expected_binaries)
'''
CONTRACT_ADDITION = b'''    if frozen != current and inventory == 'c9d7744ec0fd487bf6049b1421b7905f231995ea232626d6d986748dbbc0a3de':
        from startup_source_compatibility import routing_extension_matches
        if routing_extension_matches(name, frozen, current, inventory): return True
'''


def digest(value):
    return hashlib.sha256(value).hexdigest()


def routing_extension_matches(name, frozen, current, inventory, *, source=None):
    """Removing only the reviewed additions must reproduce every frozen byte.

    Source bytes are data, never imported from a campaign. This also binds the
    contract's own compatibility hook without a self-referential hash allowlist.
    Any other edit, including a statistical/collection change, fails closed.
    """
    if inventory != INVENTORY or name not in ("parity_gate.py", "startup_campaign_contract.py", "resize_protocol.py"):
        return False
    data = source if source is not None else Path(__file__).with_name(name).read_bytes()
    if digest(data) != current:
        return False
    if name == "resize_protocol.py":
        return frozen == FROZEN_RESIZE_PROTOCOL and current == GUARDED_RESIZE_PROTOCOL
    expected, additions = ((FROZEN_GATE, (GATE_ADDITION,)) if name == "parity_gate.py"
                           else (FROZEN_CONTRACT, (CONTRACT_ADDITION,)))
    if frozen != expected:
        return False
    for addition in additions:
        if data.count(addition) != 1:
            return False
        data = data.replace(addition, b"", 1)
    return digest(data) == frozen


V5_INVENTORY = "ebf4d34494b6b9568a5b9495b12caba0bc074a41f5f385d0c0662fd4963cb6b5"
V5_NATIVE = "eb3ee4a8754db78d254879242f495f0a446e8cdb86e7e1f6f447a4a5264729c7"
V5_CONTRACT = "da1b986904df76a689773224adf6b1644ef436def824b392eaec309d0345c6b6"
NATIVE_FAILURE_REPORTING = "        // Report metadata only on rejection; the successful measurement path is unchanged.\n        if occluded {\n            var details: [[String: Any]] = []\n            var total = 0\n            for other in items {\n                if other.id == window.id { break }\n                if other.alpha > 0 && other.bounds.rectangle.intersects(window.bounds.rectangle)\n                    && !(!spec.captureShowsCursor && scrollIsCaptureExcludedCursor(\n                        layer: other.layer, ownerExecutable: other.ownerExecutable)) {\n                    total += 1\n                    if details.count < 16 {\n                        var detail: [String: Any] = [\"pid\": other.pid, \"windowID\": other.id,\n                            \"layer\": other.layer, \"alpha\": other.alpha, \"bounds\": try encoded(other.bounds)]\n                        if let identity = try? ResizeProcessIdentity.read(other.pid) {\n                            detail[\"identityObservedAfterWindowQuery\"] = try encoded(identity)\n                        }\n                        details.append(detail)\n                    }\n                }\n            }\n            let detailsJSON: [String: Any] = [\"windowQueryTicks\": ticks,\n                \"failureTicks\": mach_absolute_time(), \"ownedPID\": app.pid,\n                \"ownedWindowID\": window.id, \"ownedBounds\": try encoded(window.bounds),\n                \"occluders\": details, \"occluderCount\": total, \"windowTitlesOrContentsRead\": false]\n            let data = try JSONSerialization.data(withJSONObject: detailsJSON, options: [.sortedKeys])\n            throw ResizeFailure(\"startup owned crop is occluded; metadata=\" + String(decoding: data, as: UTF8.self))\n        }\n".encode()
CONTRACT_FAILURE_HOOK = b'''    if frozen == current: return True
    from startup_source_compatibility import failure_metadata_extension_matches
    return failure_metadata_extension_matches(name, frozen, current, inventory)
'''


def failure_metadata_extension_matches(name, frozen, current, inventory, *, source=None):
    """Admit only the exact original v5 collection through failure-reporting readers.

    Reconstruct every original byte after removing the exact reviewed error-only
    block or reader hook. Policy, worker, timing and acceptance edits cannot match.
    Frozen campaign files and compiled observer identities remain independently
    verified by check_plan; no historical source is executed or rewritten.
    """
    if inventory != V5_INVENTORY or name not in ("startup_native.swift", "startup_campaign_contract.py"):
        return False
    data = source if source is not None else Path(__file__).with_name(name).read_bytes()
    if digest(data) != current:
        return False
    if name == "startup_native.swift":
        expected, addition = V5_NATIVE, NATIVE_FAILURE_REPORTING
        original = b'        try resizeRequire(!occluded, "startup owned crop is occluded")\n'
    else:
        if data.count(COMPLETED_STOP_HOOK) == 1:
            data = data.replace(COMPLETED_STOP_HOOK, b"", 1)
        expected, addition = V5_CONTRACT, CONTRACT_FAILURE_HOOK
        original = b'    return frozen == current\n'
    if frozen != expected or data.count(addition) != 1:
        return False
    return digest(data.replace(addition, original, 1)) == frozen


# This exact worker change only resolves a SIGTERM race after one complete
# viewport. It retains the original bytes, clocks, final-grid proof and reader
# rejection rules. Failed/partial launches remain invalid.
COMPLETED_STOP_INVENTORY = 'f6712c466b65254c03f09ec9372d6fc770fcdf5057b47be2a36c62d266f10b91'
COMPLETED_STOP_HOOK = b'    from startup_source_compatibility import completed_stop_extension_matches\n    if completed_stop_extension_matches(name, frozen, current, inventory): return True\n'
COMPLETED_STOP_SOURCES = {'startup_fixture.py': ('e22a4c43a6a7b6d7c008ac7ab18728cf52c15edf98437bcf6a010b56ad7342e8', 'c90ceeea9cf4c727cd6bafc54ad1a75e42e3070e2ca38356f2fec57fe8a9e98f'), 'startup_worker_tests.py': ('b853314074d142e34992d5a90cd74c702ea0ade8cb462c10500f49d88d64857b', '89a911be8127f415aff970bad593933174771ddad463ae32b23d1beb6fb16ed5')}


def completed_stop_extension_matches(name, frozen, current, inventory, *, source=None):
    if inventory not in (COMPLETED_STOP_INVENTORY, V5_INVENTORY):
        return False
    if name not in (*COMPLETED_STOP_SOURCES, "startup_campaign_contract.py"):
        return False
    data = source if source is not None else Path(__file__).with_name(name).read_bytes()
    if digest(data) != current:
        return False
    if name in COMPLETED_STOP_SOURCES:
        return (frozen, current) == COMPLETED_STOP_SOURCES[name]
    if data.count(COMPLETED_STOP_HOOK) != 1:
        return False
    original = data.replace(COMPLETED_STOP_HOOK, b"", 1)
    if inventory == COMPLETED_STOP_INVENTORY:
        return frozen == 'a1229176a204b487e44c74b796697ae8434cc65ab5b6341a65074f63c298fe30' and digest(original) == frozen
    return failure_metadata_extension_matches(name, frozen, digest(original), inventory, source=original)
