"""Checkpoint complete paired memory blocks; never choose blocks by their values.

A campaign is fixed before its first launch. Each checkpoint binds one complete
global block to raw files and the supervisor's quiet-clock prefix. Later input
may invalidate the next block, but cannot change a previously sealed block.
All six blocks are independently read before the ordinary parity gate runs.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import tempfile
import time

from memory_parity_evidence import load_memory_evidence, condition_signature

KIND = "memory-block-campaign"
BLOCKS = 6
RULE = "first-complete-global-block-in-order-no-result-selection-v1"


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    return json.loads(Path(path).read_text())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_new(path, value):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".checkpoint-") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
        os.link(stream.name, path)  # Atomic creation; never replaces a prior checkpoint.
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def inventory(root):
    return {str(path.relative_to(root)): sha(path)
            for path in sorted(root.rglob("*")) if path.is_file()}


def campaign_plan(root):
    root = Path(root).resolve()
    plan = read(root / "campaign.json")
    require(plan.get("kind") == KIND and plan.get("selectionRule") == RULE
            and plan.get("blocks") == BLOCKS and plan.get("nativeLaunches") == 36
            and plan.get("measuredSamples") == 216 and plan.get("expectedMetrics") == 9
            and plan.get("performanceSamplesInherited") is False,
            "campaign scope or selection rule changed")
    for name, checksum in plan["pins"].items():
        require(sha(root / name) == checksum, "campaign input changed: " + name)
    return plan


def checkpoint_paths(root):
    paths = sorted((Path(root) / "checkpoints").glob("*.json"))
    require(len(paths) <= BLOCKS and [p.name for p in paths] ==
            [f"{i:02d}.json" for i in range(len(paths))], "missing or reordered checkpoint")
    return paths


def common_signature(metadata):
    return {
        "binaries": metadata["binaries"], "profile": metadata["profile"],
        "tooling": metadata["toolingSHA256"], "helpers": metadata["helperSHA256"],
        "runtime": metadata["pythonExecutable"], "font": metadata["displayFontPermissions"]["font"],
        "fontSHA256": metadata["fontSHA256"], "displays": metadata["displayFontPermissions"]["displays"],
        "hardware": metadata["hardware"]["stdout"], "os": metadata["os"]["stdout"],
        "conditions": condition_signature(metadata["initialConditions"]),
        "payloads": metadata["payloads"], "grid": metadata["targetGrid"],
        "verificationPolicy": metadata["verificationPolicy"],
        "verificationScope": metadata["verificationScope"],
    }


def audit_block(case, campaign):
    root = Path(case["output"]).resolve()
    block = case["blockIndex"]
    require(type(block) is int and 0 <= block < BLOCKS, "invalid global block")
    metadata = read(root / "manifest.json")
    args = metadata["arguments"]
    require(metadata["schemaVersion"] == 5 and args["blocks"] == 1
            and args["block_start"] == block and args["first"] == "cmdy"
            and args["payload_marker"] == campaign["payloadMarker"]
            and args["profile"] == campaign["profile"]
            and args["display_id"] == campaign["displayID"]
            and args.get("cases") is None
            and args.get("post_sample_history") is True
            and args.get("park_pointer_outside_window") is True,
            "block command scope or global offset changed")
    require(metadata["toolingSHA256"] == campaign["toolingSHA256"]
            and metadata["helperSHA256"] == campaign["helperSHA256"]
            and metadata["pythonExecutable"] == campaign["workerRuntimeExecutable"]
            and metadata["payloads"] == campaign["payloads"]
            and metadata["initialConditions"]["power"]["signature"] == campaign["powerSignature"],
            "block does not use the preregistered inputs")
    items = load_memory_evidence(root, campaign["binaries"])
    records = read(root / "records.json")
    require(len(items) == 9 and all(set(item["blocks"]) == {block} for item in items)
            and len(records) == 6 and sum(len(row["samples"]) for row in records) == 36,
            "incomplete paired resource block")
    require(all(row["window"]["windows"][0]["bounds"]["x"] == 32
                and row["window"]["windows"][0]["bounds"]["y"] == 120 for row in records),
            "qualified window origin changed")
    starts = [read(path)["startedMonotonicNS"] for path in (root / "runs").glob("*/launch.json")]
    return items, common_signature(metadata), min(starts), metadata["finalConditions"]["finishedMonotonicNS"]


def activity_prefix(episode, initial, count=None):
    lines = (episode / "hardware-idle.jsonl").read_bytes().splitlines(keepends=True)
    if count is not None:
        require(type(count) is int and 0 < count <= len(lines), "missing activity prefix")
        lines = lines[:count]
    require(lines and initial["idleSeconds"] >= 300 and initial["hardwareIdleSeconds"] >= 300,
            "missing initial quiet interval")
    observations = [json.loads(line) for line in lines]
    for item in observations:
        require(item.get("valid", True) is True and item.get("returned") is False
                and item["clock"] == initial["clock"]
                and math.isfinite(item["idleSeconds"])
                and item["idleSeconds"] + 2 >= initial["idleSeconds"]
                    + (item["readStartedMonotonicNS"] - initial["sessionReadFinishedMonotonicNS"]) / 1e9,
                "input or invalid clock before block checkpoint")
    require(all(left["readFinishedMonotonicNS"] <= right["readStartedMonotonicNS"]
                for left, right in zip(observations, observations[1:])), "activity clocks reordered")
    return len(lines), hashlib.sha256(b"".join(lines)).hexdigest(), observations[-1]


def validate_launch_binding(episode, plan):
    binding = read(episode / "launch-binding.json")
    require(binding["planSHA256"] == sha(episode / "plan.json"), "launch plan changed")
    receipts = {}
    for key in ("preflight", "pointerSetup", "visibility"):
        require(sha(binding[key]) == binding[key + "SHA256"], "launch receipt changed")
        receipts[key] = read(binding[key])
        require(receipts[key]["planSHA256"] == binding["planSHA256"], "receipt belongs to another plan")
    ready, pointer, visibility = (receipts[key] for key in ("preflight", "pointerSetup", "visibility"))
    require(ready["status"] == "ready" and ready["sourceSHA256"] == plan["outerGuardSHA256"]
            and ready["allThreeAgentsConfirmedInactive"] is True and not ready["activeRelevantProcesses"]
            and 0 <= binding["createdUnixNS"] - ready["finishedUnixNS"] <= 30_000_000_000,
            "fresh quiet/process/power guard missing")
    require(pointer["status"] == "prelaunch-pointer-position-verified"
            and visibility["status"] == "external-visibility-change-observed"
            and all(value["preflightSHA256"] == binding["preflightSHA256"]
                    and value["ownedProcessReaped"] is True and value["humanInputDetected"] is False
                    for value in (pointer, visibility))
            and 0 <= binding["createdUnixNS"] - pointer["finishedUnixNS"] <= 30_000_000_000
            and 0 <= binding["createdUnixNS"] - visibility["finishedUnixNS"] <= 300_000_000_000,
            "qualified pointer/strict visibility prerequisites missing")
    return sha(episode / "launch-binding.json")


def seal_block(episode, plan, execution, item, activity):
    """Called only by the guarded supervisor, after child exit and raw audit."""
    root = Path(plan["campaign"])
    campaign = campaign_plan(root)
    require(sha(root / "campaign.json") == plan["campaignSHA256"], "campaign plan changed")
    binding_hash = validate_launch_binding(episode, plan)
    paths = checkpoint_paths(root)
    case = next(value for value in plan["cases"] if value["workload"] == item["workload"])
    block = case["blockIndex"]
    require(block == len(paths), "cannot replace or skip a completed block")
    _, signature, started, finished = audit_block(case, campaign)
    if paths:
        previous = read(paths[-1])
        require(previous["signature"] == signature and previous["checkpointMonotonicNS"] < started,
                "block environment changed or block lifetimes overlap")
    count, prefix_hash, last = activity_prefix(episode, execution["initialActivity"])
    require(last == activity and activity["phase"] == "checkpoint-" + case["workload"]
            and finished <= activity["readStartedMonotonicNS"], "checkpoint preceded completed history")
    audit_path = episode / (case["workload"] + "-raw-audit.json")
    require(sha(audit_path) == item["auditSHA256"] and item["status"] == "complete"
            and item["exitCode"] == 0 and item["controllerReaped"] is True
            and item["measuredSamples"] == 36 and item["warmups"] == 0,
            "supervisor did not finish the paired block")
    seal = dict(schemaVersion=1, block=block, campaignSHA256=plan["campaignSHA256"],
        episode=str(episode), episodePlanSHA256=sha(episode / "plan.json"),
        launchBindingSHA256=binding_hash,
        case=dict(item), output=case["output"], initialActivity=execution["initialActivity"],
        activityPrefixLines=count, activityPrefixSHA256=prefix_hash,
        checkpointMonotonicNS=activity["readFinishedMonotonicNS"], createdUnixNS=time.time_ns(),
        signature=signature, performanceAdmission=False, selectionRule=RULE)
    path = root / "checkpoints" / f"{block:02d}.json"
    write_new(path, seal)
    return sha(path)


def validate_checkpoint(root, campaign, path):
    seal = read(path)
    block = int(path.stem)
    require(seal["block"] == block and seal["campaignSHA256"] == sha(root / "campaign.json")
            and seal["selectionRule"] == RULE and seal["performanceAdmission"] is False,
            "checkpoint identity changed")
    episode = Path(seal["episode"]).resolve()
    require(episode.parent == root / "episodes", "checkpoint outside this fresh campaign")
    plan = read(episode / "plan.json")
    require(sha(episode / "plan.json") == seal["episodePlanSHA256"]
            and plan["campaignSHA256"] == seal["campaignSHA256"], "episode plan changed")
    require(validate_launch_binding(episode, plan) == seal["launchBindingSHA256"], "launch binding changed")
    execution = read(episode / "execution.json")
    require(execution["planSHA256"] == seal["episodePlanSHA256"]
            and execution["initialActivity"] == seal["initialActivity"], "supervisor identity changed")
    item = next(value for value in execution["cases"] if value["workload"] == seal["case"]["workload"])
    require(all(item.get(key) == value for key, value in seal["case"].items())
            and item["checkpointSHA256"] == sha(path), "supervisor checkpoint differs")
    count, prefix_hash, last = activity_prefix(episode, execution["initialActivity"], seal["activityPrefixLines"])
    require(prefix_hash == seal["activityPrefixSHA256"]
            and last["readFinishedMonotonicNS"] == seal["checkpointMonotonicNS"]
            and last["phase"] == "checkpoint-" + item["workload"], "quiet prefix changed")
    case = next(value for value in plan["cases"] if value["workload"] == item["workload"])
    require(case["blockIndex"] == block and Path(case["output"]).resolve() == episode / item["workload"]
            and case["output"] == seal["output"], "raw block provenance changed")
    audit_path = episode / (item["workload"] + "-raw-audit.json")
    require(sha(audit_path) == item["auditSHA256"], "raw block audit changed")
    audit = read(audit_path)
    require(inventory(Path(case["output"])) == audit["files"]
            and audit["measuredSamples"] == 36 and audit["warmups"] == 0,
            "checkpoint raw files changed")
    items, signature, started, finished = audit_block(case, campaign)
    require(signature == seal["signature"] and finished <= last["readStartedMonotonicNS"],
            "checkpoint signature or completion boundary changed")
    return items, signature, started, seal["checkpointMonotonicNS"]


def validate_episodes(root, paths):
    episodes = sorted((root / "episodes").iterdir())
    require([p.name for p in episodes] == [f"episode-{i:02d}" for i in range(1, len(episodes) + 1)],
            "missing campaign attempt")
    earlier = []
    for episode in episodes:
        audit = read(episode / 'episode-audit.json')
        files = inventory(episode)
        files.pop('episode-audit.json', None)
        require(audit['files'] == files, 'completed or interrupted episode files changed')
        plan = read(episode / "plan.json")
        require(plan["campaign"] == str(root) and plan["campaignSHA256"] == sha(root / "campaign.json")
                and plan["collectionOnly"] is True and plan["performanceAdmission"] is False
                and plan["priorCheckpoints"] == earlier, "attempt skipped or replaced prior evidence")
        require([case["blockIndex"] for case in plan["cases"]] == list(range(len(earlier), BLOCKS)),
                "episode did not preregister every remaining block")
        for name, checksum in plan["pins"].items():
            require(sha(episode / name) == checksum, "episode input changed: " + name)
        execution = read(episode / "execution.json")
        require(execution["planSHA256"] == sha(episode / "plan.json")
                and execution["status"] in ("complete-native-block-collection", "stopped-with-retained-evidence"),
                "episode did not finish under supervision")
        for path in paths:
            if read(path)["episode"] == str(episode):
                earlier.append(dict(block=int(path.stem), sha256=sha(path)))
    require(len(earlier) == len(paths), "checkpoint episode missing")


def merge_items(groups, root):
    root = Path(root).resolve()
    require(len(groups) == BLOCKS, "all six paired blocks are required")
    merged = {}
    names = None
    for block, items in enumerate(groups):
        require(len(items) == 9 and len({item["case"] for item in items}) == 9,
                "duplicate or missing resource metric")
        current_names = {item["case"] for item in items}
        require(names is None or names == current_names, "resource metric set changed")
        names = current_names
        for item in items:
            require(set(item["blocks"]) == {block}, "global block missing, repeated or reordered")
            common = {key: value for key, value in item.items() if key not in ("path", "blocks")}
            name = item["case"]
            if name not in merged:
                merged[name] = {**common, "path": str(root), "blocks": {}}
            require(common == {key: value for key, value in merged[name].items() if key not in ("path", "blocks")},
                    "resource metric environment or protocol changed")
            merged[name]["blocks"].update(item["blocks"])
    return list(merged.values())


def validate_fresh_owners(directory, seen):
    for record in read(directory / 'records.json'):
        run = directory / 'runs' / f"{record['block']:02d}-{record['position']:02d}-{record['case']}-{record['terminal']}"
        binding = read(run / 'public-history-binding.json')
        keys = [(key, binding[key]) for key in ('capability', 'nonce', 'temporaryDirectory', 'socketPath')]
        for role in ('app', 'worker'):
            sample = record['samples'][0][role]
            keys.append((role, sample['pid'], sample['processStartTicks']))
        require(not any(key in seen for key in keys), 'process or public binding reused across blocks')
        seen.update(keys)


def load_memory_blocks(directory, expected_binaries):
    root = Path(directory).resolve()
    campaign = campaign_plan(root)
    manifest = read(root / "manifest.json")
    paths = checkpoint_paths(root)
    require(campaign["binaries"] == expected_binaries and len(paths) == BLOCKS
            and manifest == dict(benchmarkKind=KIND, campaignSHA256=sha(root / "campaign.json"),
                                 checkpoints={p.name: sha(p) for p in paths},
                                 episodes={p.name: sha(p / 'episode-audit.json')
                                           for p in sorted((root / 'episodes').iterdir())}),
            "incomplete or changed checkpoint collection")
    validate_episodes(root, paths)
    groups, previous_signature, previous_end, owners = [], None, 0, set()
    for path in paths:
        items, signature, started, finished = validate_checkpoint(root, campaign, path)
        require(started > previous_end and (previous_signature is None or signature == previous_signature),
                "cross-block environment changed or lifetimes overlap")
        validate_fresh_owners(Path(read(path)['output']), owners)
        groups.append(items)
        previous_signature, previous_end = signature, finished
    return merge_items(groups, root)


def seal_episode(episode):
    """Retain even failed attempts before preparing the next attempt."""
    episode = Path(episode).resolve()
    execution = read(episode / 'execution.json')
    require(execution['status'] in ('complete-native-block-collection', 'stopped-with-retained-evidence')
            and execution.get('finishedUTC') and all(item.get('controllerReaped') is True
                for item in execution['cases']), 'episode is still running or cleanup is incomplete')
    path = episode / 'episode-audit.json'
    if path.exists():
        expected = inventory(episode); expected.pop('episode-audit.json')
        require(read(path)['files'] == expected, 'sealed episode changed')
    else:
        write_new(path, dict(status=execution['status'], files=inventory(episode),
                             performanceAdmission=False, createdUnixNS=time.time_ns()))
