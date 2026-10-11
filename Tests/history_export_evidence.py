"""Independent generated file, native ownership, and viewport proof validators."""
from __future__ import annotations

import base64
import json
import math
import stat

from bench_ancestry import validate_kernel_ancestry
from history_export_files import INVENTORY_LIMIT, PATH_COMPONENT_LIMIT, parse_owned_path
from history_export_protocol import (ACTION, FILE_PROOF_SCOPE, KEY_CODE, MODIFIER_FLAGS, PATH_LIMIT, RECEIVE_SECONDS, SHORTCUT, digest,
                                     expected_bytes, require, resize_batch_expectation, validate_export_bytes)
from history_export_phase import POLICY, selected_action, validate_phase
from resize_calibration_evidence import validate_discovery
from resize_protocol import cell_classes_bytes, growth_guard_enabled


VISUAL_MEMORY_SCOPE = "strict-visual-memory-v1"
VISUAL_MEMORY_TRANSPORT = "public-case-file-paste-path-post-sample-visual-v1"


def integer(value, low=0):
    require(type(value) is int and low <= value <= (1 << 63) - 1, "invalid-evidence-integer")
    return value


def file_metadata(value):
    require(type(value) is dict and set(value) == {"dev", "ino", "uid", "gid", "mode", "nlink", "size", "mtime_ns", "ctime_ns"},
            "file-metadata-fields-differ")
    for item in value.values(): integer(item)
    integer(value["dev"], 1); integer(value["ino"], 1)
    return (value["dev"], value["ino"])


def validate_recursive_inventory(prior):
    """Replay the complete tree graph, not just an unlabelled inode list."""
    require(type(prior.get("schemaVersion")) is int and prior["schemaVersion"] == 2
            and prior.get("scope") == "complete-recursive-private-tree" and prior.get("complete") is True
            and prior.get("maximumEntries") == INVENTORY_LIMIT
            and prior.get("maximumPathComponents") == PATH_COMPONENT_LIMIT,
            "recursive-inventory-version-or-scope-differs")
    root = prior["directory"]; root_id = file_metadata(root)
    require(stat.S_ISDIR(root["mode"]) and root["mode"] & 0o077 == 0, "recursive-root-not-private")
    entries = prior["entries"]
    require(type(entries) is list and integer(prior["entryCount"]) == len(entries) <= INVENTORY_LIMIT,
            "recursive-inventory-count-differs")
    nodes, parents = {root_id: root}, {}
    for entry in entries:
        require(set(entry) == {"parentIdentity", "metadata"}, "recursive-entry-fields-differ")
        value = entry["metadata"]; identity = file_metadata(value)
        parent = entry["parentIdentity"]
        require(type(parent) is list and len(parent) == 2, "recursive-parent-identity-differs")
        for item in parent: integer(item, 1)
        require(identity not in nodes and value["uid"] == root["uid"] and value["dev"] == root["dev"]
                and (stat.S_ISREG(value["mode"]) or stat.S_ISDIR(value["mode"])), "recursive-entry-type-owner-or-identity-differs")
        if stat.S_ISDIR(value["mode"]): require(value["mode"] & 0o077 == 0, "recursive-child-not-private")
        nodes[identity] = value; parents[identity] = tuple(parent)
    require(prior["identities"] == sorted([list(identity) for identity in parents]), "recursive-identity-list-differs")
    child_counts = {key: 0 for key, value in nodes.items() if stat.S_ISDIR(value["mode"])}
    for identity, parent in parents.items():
        require(parent in child_counts, "recursive-parent-not-in-inventory")
        child_counts[parent] += 1
        current, visited, depth = identity, set(), 0
        while current != root_id:
            require(current not in visited and current in parents, "recursive-inventory-disconnected-or-cyclic")
            visited.add(current); current = parents[current]; depth += 1
            require(depth <= PATH_COMPONENT_LIMIT, "recursive-inventory-depth-differs")
        require(depth < PATH_COMPONENT_LIMIT if stat.S_ISDIR(nodes[identity]["mode"]) else depth <= PATH_COMPONENT_LIMIT,
                "recursive-inventory-depth-differs")
    scans = prior["directoryScans"]
    require(type(scans) is list and len(scans) == len(child_counts), "recursive-directory-coverage-differs")
    scanned = set()
    for scan in scans:
        require(set(scan) == {"identity", "before", "after", "childCount"}, "recursive-scan-fields-differ")
        identity = file_metadata(scan["before"])
        require(scan["identity"] == list(identity) and identity in child_counts and identity not in scanned
                and scan["before"] == scan["after"] == nodes[identity]
                and integer(scan["childCount"]) == child_counts[identity], "recursive-directory-scan-incomplete-or-unstable")
        scanned.add(identity)
    require(scanned == set(child_counts), "recursive-directory-coverage-differs")
    return nodes


def validate_file_proof(proof, raw, spec, temporary_directory):
    expected_bytes(spec)
    require(type(proof["schemaVersion"]) is int and proof["schemaVersion"] in (1, 2)
            and proof["status"] == "recognized-generated-export", "file-proof-version-or-status")
    receipt = proof["pathReceiptASCII"].encode("ascii")
    components = parse_owned_path(receipt, temporary_directory).split("/")
    require(proof["pathFraming"] == "raw-absolute-path-no-delimiter"
            and proof["pathBytes"] == len(receipt) <= PATH_LIMIT, "path-framing-or-count-differs")
    opened, after, prior = proof["opened"], proof["afterRead"], proof["beforeInventory"]
    file_metadata(opened)
    if proof["schemaVersion"] == 1:
        # Old flat evidence remains replayable. A version-1 proof can never
        # borrow the new lexical parser to admit an unproved descendant.
        require(len(components) == 1 and "schemaVersion" not in prior and "ancestorChain" not in proof,
                "legacy-file-proof-must-be-flat")
    else:
        nodes = validate_recursive_inventory(prior)
        require(proof["pathTraversal"] == "descriptor-relative-nofollow" and proof["rootNameRevalidated"] is True
                and proof["beforeUnlink"] == proof["namedAtOpen"] == proof["namedAfterRead"] == proof["namedBeforeUnlink"] == opened,
                "descriptor-traversal-or-file-cleanup-proof-differs")
        chain = proof["ancestorChain"]
        require(type(chain) is list and len(chain) == len(components), "ancestor-chain-path-coverage-differs")
        seen = set()
        for index, entry in enumerate(chain):
            parent = None if index == 0 else [chain[index - 1]["opened"][key] for key in ("dev", "ino")]
            require(set(entry) == {"component", "parentIdentity", "opened", "afterRead", "beforeUnlink",
                                   "namedAtOpen", "namedAfterRead", "namedBeforeUnlink"}
                    and entry["component"] == (None if index == 0 else components[index - 1])
                    and entry["parentIdentity"] == parent,
                    "ancestor-chain-path-link-differs")
            value = entry["opened"]; identity = file_metadata(value)
            require(identity not in seen and value == entry["afterRead"] == entry["beforeUnlink"]
                    == entry["namedAtOpen"] == entry["namedAfterRead"] == entry["namedBeforeUnlink"]
                    and stat.S_ISDIR(value["mode"]) and value["mode"] & 0o077 == 0
                    and value["uid"] == prior["directory"]["uid"] and value["dev"] == prior["directory"]["dev"],
                    "ancestor-chain-private-stable-identity-differs")
            if index == 0:
                require(all(value[key] == prior["directory"][key] for key in ("dev", "ino", "uid", "mode")),
                        "ancestor-root-prearm-identity-differs")
            elif identity in nodes:
                require(all(value[key] == nodes[identity][key] for key in ("dev", "ino", "uid", "mode")),
                        "ancestor-prior-identity-differs")
            seen.add(identity)
        require(opened["dev"] == prior["directory"]["dev"], "export-device-differs-from-owned-tree")
    require(opened == after and stat.S_ISREG(opened["mode"]) and stat.S_IMODE(opened["mode"]) == 0o600
            and opened["nlink"] == 1 and opened["size"] == len(raw)
            and opened["uid"] == prior["directory"]["uid"]
            and [opened["dev"], opened["ino"]] not in prior["identities"], "private-new-file-identity-differs")
    require(prior["entryCount"] == len(prior["identities"]) <= 128
            and stat.S_ISDIR(prior["directory"]["mode"]) and prior["directory"]["mode"] & 0o077 == 0,
            "private-directory-inventory-differs")
    actual = validate_export_bytes(raw, spec)
    require(proof["validation"] == actual, "observed-file-validation-differs")
    require(proof["cleanup"] == dict(sourceUnlinked=True, descriptorClosed=True,
                                    directoryDescriptorClosed=True, sameInodeOnly=True), "export-file-cleanup-incomplete")
    return actual


def validate_owner(owner, native_spec, *, file_transport=False):
    app, worker = owner["identity"], owner["workerIdentity"]
    validate_kernel_ancestry(owner["ancestry"], app, worker)
    require(app["pid"] == native_spec["pid"] and worker["pid"] == native_spec["workerPID"]
            and owner["ttyPath"] == native_spec["ttyPath"] and owner["grid"] == dict(columns=120, rows=36),
            "native-owner-or-real-tty-grid-differs")
    require(owner["workerTTYDevice"] == (owner["ttyDevice"] & 0xffffffff)
            and integer(owner["workerProcessGroup"], 1) == owner["workerForegroundGroup"], "tty-device-or-foreground-group-differs")
    window = owner["window"]
    require(window["identity"] == app and window["foregroundPID"] == app["pid"]
            and window["windowID"] == native_spec["windowID"] and window["displayID"] == native_spec["displayID"],
            "native-window-not-exact-owned-target")
    if file_transport:
        require(native_spec.get("proofScope") == FILE_PROOF_SCOPE and window.get("proofScope") == FILE_PROOF_SCOPE
                and type(window.get("schemaVersion")) is int and window["schemaVersion"] == 2
                and window.get("visualVisibilityVerified") is False and "occluded" not in window
                and window.get("onScreen") is True and type(window.get("alpha")) in (int, float)
                and math.isfinite(window["alpha"]) and 0.999 <= window["alpha"] <= 1,
                "file-transport-proof-scope-or-owned-window-differs")
        bounds = window["bounds"]
        require(set(bounds) == {"x", "y", "width", "height"}
                and all(type(v) in (int, float) and math.isfinite(v) for v in bounds.values())
                and bounds["width"] > 0 and bounds["height"] > 0,
                "file-transport-window-geometry-differs")
    else:
        require(native_spec.get("proofScope") is None and window.get("proofScope") is None
                and window.get("schemaVersion") is None and window.get("occluded") is False,
                "native-window-not-exact-visible-owned-target")
    require(integer(window["queriedTicks"], 1) >= owner["ancestry"]["finishedTicks"], "window-proof-precedes-owner-proof")
    return app, worker, window["bounds"]


def validate_transfer(document, raw):
    """Memory may consume this without a viewport claim; resize adds the pair below."""
    require(type(document["schemaVersion"]) is int and document["schemaVersion"] in (1, 2, 3, 4, 5)
            and document["terminal"] in ("cmdy", "ghostty"), "transfer-version-or-terminal")
    spec, native = document["expectation"], document["nativeSpec"]
    phase_enabled = document["schemaVersion"] in (3, 4)
    visual_memory = document["schemaVersion"] == 4
    require(native.get("verificationScope") == VISUAL_MEMORY_SCOPE if visual_memory
            else "verificationScope" not in native, "transfer-verification-scope-differs")
    file_transport = document["schemaVersion"] in (2, 3)
    require((native.get("proofScope") == FILE_PROOF_SCOPE and spec["case"] != "resize") if file_transport
            else native.get("proofScope") is None, "transfer-proof-scope-differs")
    ready, arm, action, proof = (document[key] for key in ("workerReady", "workerArm", "action", "export"))
    if document["schemaVersion"] == 5:
        block, phase = ready.get("pairedBlock"), arm.get("phase")
        require(type(block) is int and 0 <= block < 6 and phase in ("before", "after")
                and ready.get("historyTransferScope") == "resize-same-lifetime-history-v1"
                and arm.get("sequence") == block * 42 + (0 if phase == "before" else 42)
                and spec == resize_batch_expectation(spec["nonce"], phase,
                    history_growth_guard=growth_guard_enabled(ready)),
                "resize-batch-history-phase-or-plan-differs")
    else:
        require("resizeBatchPadding" not in spec, "resize-batch-padding-requires-batch-transfer")
    if visual_memory:
        require(type(proof.get("schemaVersion")) is int and proof["schemaVersion"] == 2,
                "visual-memory-requires-descriptor-anchored-file-proof")
    if phase_enabled:
        require(native.get("verificationPolicy") == ready.get("verificationPolicy") == POLICY
            and native.get("exportCase") == spec["case"], "verification-native-worker-policy-differs")
        phase = document["verificationPhase"]
        validate_phase(phase, spec, ready["pid"], document["workerPrepared"])
        require(arm.get("verificationPhase") == phase
            and phase["finishedTicks"] <= integer(arm["armedTicks"], 1)
            and phase["finishedMonotonicNS"] <= integer(arm["armedMonotonicNS"], 1)
            and integer(ready["startedTicks"], 1) <= phase["startedTicks"],
            "verification-phase-must-precede-arm")
        require(ready["payloadBytes"] == document["workerPrepared"]["bytes"]
            and ready["payloadSHA256"] == document["workerPrepared"]["sha256"]
            and integer(document["beforeOwner"]["window"]["queriedTicks"], 1) <= phase["startedTicks"],
            "verification-ready-payload-or-owner-binding-differs")
    else:
        require(not any(key in native for key in ("verificationPolicy", "exportCase"))
            and "verificationPolicy" not in ready and "verificationPhase" not in arm
            and "verificationPhase" not in document and "workerPrepared" not in document,
            "legacy-transfer-cannot-borrow-verification-phase")
    require(ready["pid"] == native["workerPID"] and ready["ttyPath"] == native["ttyPath"]
            and ready["nonce"] == native["nonce"] == spec["nonce"], "worker-native-fixture-identity-differs")
    value = validate_file_proof(proof, raw, spec, ready["temporaryDirectory"])
    owners = [document["beforeOwner"], action["beforeOwner"], action["afterOwner"], document["afterOwner"]]
    signatures = [validate_owner(owner, native, file_transport=file_transport) for owner in owners]
    require(all(item == signatures[0] for item in signatures), "owner-lifetime-window-or-viewport-bounds-changed")
    require(proof["opened"]["uid"] == signatures[0][0]["uid"], "export-owner-differs-from-native-app")
    intended = selected_action(spec["case"] if phase_enabled else None, POLICY if phase_enabled else None)
    require(action["ok"] is True and action["op"] == "post-key" and action["intendedAction"] == intended
            and action["actionInvocationVerified"] is False and "action" not in action
            and action["shortcut"] == SHORTCUT and action["keyCode"] == KEY_CODE and action["eventCount"] == 2
            and action["modifierFlags"] == MODIFIER_FLAGS and action["eventTypes"] == ["keyDown", "keyUp"]
            and action["autorepeat"] == 0
            and action["targetPID"] == native["pid"] and action["foregroundActivated"] is False,
            "public-shortcut-posting-differs")
    start = integer(arm["armedTicks"], 1)
    require(start <= integer(action["beforeTicks"], 1) <= integer(action["betweenTicks"], 1)
            <= integer(action["afterTicks"], 1) <= integer(proof["receiveCompletedTicks"], 1), "arm-action-receipt-clock-order")
    require(owners[0]["window"]["queriedTicks"] <= action["beforeTicks"]
            and owners[1]["window"]["queriedTicks"] <= action["beforeTicks"]
            and owners[2]["ancestry"]["startedTicks"] >= action["afterTicks"]
            and owners[3]["ancestry"]["startedTicks"] >= proof["receiveCompletedTicks"], "owner-proofs-do-not-bracket-action-and-export")
    require(proof["receiveStartedTicks"] == start and proof["beforeInventory"] == arm["beforeInventory"], "arm-file-inventory-differs")
    ns = integer(arm["armedMonotonicNS"], 1); end = ns + RECEIVE_SECONDS * 1_000_000_000
    require(arm["deadlineMonotonicNS"] == proof["receiveDeadlineMonotonicNS"] == end
            and proof["receiveStartedMonotonicNS"] == ns and proof["receiveWindowSeconds"] == RECEIVE_SECONDS
            and integer(proof["receiveCompletedMonotonicNS"], 1) >= end, "fixed-path-receive-window-differs")
    chunks = proof["chunks"]
    require(1 <= len(chunks) <= PATH_LIMIT and sum(integer(row["bytes"], 1) for row in chunks) == proof["pathBytes"], "path-chunk-coverage-differs")
    previous_tick, previous_ns = action["beforeTicks"], ns
    for row in chunks:
        require(previous_tick <= integer(row["ticks"], 1) <= proof["receiveCompletedTicks"]
                and previous_ns <= integer(row["monotonicNS"], 1) < end, "path-chunk-outside-armed-window")
        previous_tick, previous_ns = row["ticks"], row["monotonicNS"]
    return dict(status="valid-generated-file-transfer", qualifying=False, terminal=document["terminal"],
                generatedHistory=value, viewportVerified=False)


def validate_viewport(observation, spec, native):
    require(spec["case"] == "resize" and observation["ok"] is True and observation["op"] == "observe"
            and observation["scope"] == "complete-generated-cell-viewport-v2" and observation["streamStopped"] is True,
            "missing-complete-generated-viewport")
    require(observation["nonce"] == spec["nonce"] and observation["sequence"] == 0, "viewport-nonce-or-sequence")
    geometry = validate_discovery(observation["discovery"])
    raw = base64.b64decode(observation["cellClassesBase64"], validate=True)
    require(raw == cell_classes_bytes(spec["nonce"], 0, 120, 36)
            and observation["matchedCells"] == len(raw) == 4320
            and observation["cellClassesSHA256"] == digest(raw), "observed-viewport-cell-stream-differs")
    before, after = validate_owner(observation["beforeOwner"], native), validate_owner(observation["afterOwner"], native)
    require(before == after and geometry["outerBounds"] == before[2], "viewport-owner-or-bounds-changed")
    require(integer(observation["displayTicks"], 1) >= max(integer(observation["captureStartedTicks"], 1), integer(observation["afterTicks"]))
            and observation["callbackTicks"] >= observation["displayTicks"], "viewport-frame-is-not-fresh")
    discovered = json.loads(observation["discovery"]["evidenceUTF8"])
    require(discovered["displayTicks"] == observation["displayTicks"]
            and discovered["nonce"] == spec["nonce"] and discovered["sequence"] == 0
            and discovered["window"]["identity"] == before[0]
            and discovered["window"]["windowID"] == native["windowID"]
            and discovered["window"]["displayID"] == native["displayID"], "discovery-came-from-another-frame-or-owner")
    statuses = observation["statuses"]
    require(1 <= len(statuses) <= 600 and all(row["status"] in (0, 1, 2, 4) for row in statuses), "capture-status-invalid")
    require(statuses[-1]["status"] == 0 and statuses[-1]["displayTicks"] == observation["displayTicks"]
            and statuses[-1]["callbackTicks"] == observation["callbackTicks"], "complete-frame-status-missing")
    return before, geometry


def validate_resize_pilot(document, raw, cleanup):
    require(document["schemaVersion"] == 1 and document["nativeSpec"].get("proofScope") is None,
            "file-transport-proof-cannot-authorize-resize-viewport")
    transfer = validate_transfer(document, raw)
    before = validate_viewport(document["beforeViewport"], document["expectation"], document["nativeSpec"])
    after = validate_viewport(document["afterViewport"], document["expectation"], document["nativeSpec"])
    require(before[0] == after[0] and before[1]["outerBounds"] == after[1]["outerBounds"], "viewport-position-changed")
    require(document["beforeViewport"]["callbackTicks"] < document["action"]["beforeTicks"]
            and document["afterViewport"]["afterTicks"] >= document["export"]["receiveCompletedTicks"], "viewport-does-not-bracket-export")
    require(cleanup["status"] == "pass" and cleanup["pid"] == document["workerReady"]["pid"]
            and cleanup["nonce"] == document["expectation"]["nonce"] and cleanup["unexpectedInputBytes"] == 0
            and cleanup["termiosRestored"] is True and cleanup["fileFlagsRestored"] is True
            and cleanup["terminalRestoreWritten"] is True and cleanup["controlSocketRemoved"] is True,
            "worker-cleanup-or-late-input-failed")
    return dict(transfer, status="valid-untimed-resize-history-pilot", viewportVerified=True,
                nativeResizeTimingAdmitted=False)
