#!/usr/bin/env python3
"""Fail closed on missing, invalid, unresolved or slower comparative evidence.

Reads retained raw benchmark directories without launching apps or changing
them. Every required case is evaluated independently; wins cannot offset losses.
Bootstrap intervals describe repeated block measurements on the recorded setup,
not a guarantee about all workloads, machines or future versions.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import re
import statistics
import sys

from terminal_bench_worker import expected_reply

HERE = Path(__file__).resolve().parent
TERMINALS = ("cmdy", "ghostty")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values, fraction):
    require(bool(values), "empty sample group")
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def assess_ratios(ratios, policy, seed=0):
    require(all(math.isfinite(value) and value > 0 for value in ratios), "invalid ratio")
    point = statistics.median(ratios) if ratios else None
    result = {"pairedBlocks": len(ratios), "medianPairedRatio": point,
              "pairedRatios": ratios, "maximumRatio": policy["maximumRatio"]}
    if len(ratios) < policy["minimumPairedBlocks"]:
        return {**result, "status": "insufficient-samples"}
    rng = random.Random(seed)
    samples = [statistics.median(rng.choices(ratios, k=len(ratios)))
               for _ in range(policy["bootstrapResamples"])]
    alpha = 1 - policy["confidence"]
    lower, upper = percentile(samples, alpha / 2), percentile(samples, 1 - alpha / 2)
    status = ("pass" if upper <= policy["maximumRatio"] else
              "behind" if lower > policy["maximumRatio"] else "inconclusive")
    return {**result, "status": status, "confidence": policy["confidence"],
            "ratioInterval": [lower, upper]}


def assess_cpu_differences(differences, policy, seed=0):
    # Idle counters can validly be zero in either app. Paired absolute CPU-rate
    # differences preserve exact parity without division by zero or pseudocounts.
    require(all(math.isfinite(value) for value in differences), "invalid CPU difference")
    result = {"pairedBlocks": len(differences), "pairedDifferences": differences,
              "medianPairedDifference": statistics.median(differences) if differences else None,
              "maximumDifference": 0, "unit": "CPU nanoseconds per wall second"}
    if len(differences) < policy["minimumPairedBlocks"]:
        return {**result, "status": "insufficient-samples"}
    rng = random.Random(seed)
    samples = [statistics.median(rng.choices(differences, k=len(differences)))
               for _ in range(policy["bootstrapResamples"])]
    alpha = 1 - policy["confidence"]
    lower, upper = percentile(samples, alpha / 2), percentile(samples, 1 - alpha / 2)
    return {**result, "status": "pass" if upper <= 0 else "behind" if lower > 0 else "inconclusive",
            "confidence": policy["confidence"], "differenceInterval": [lower, upper]}


def power_signature(snapshot):
    signature = snapshot.get("signature", {})
    require(signature.get("source") in ("Battery Power", "AC Power")
            and isinstance(signature.get("settings"), str) and signature["settings"],
            "missing power source/settings")
    return signature


def grid_value(value):
    result = [value.get("columns"), value.get("rows")]
    require(all(type(part) is int and part > 0 for part in result), "invalid grid")
    return result


def checked_window(value):
    require(value.get("ok") is True and value.get("pid") == value.get("frontmostPID"),
            "owned app was not frontmost")
    windows = value.get("windows", [])
    require(len(windows) == 1 and windows[0].get("onScreen") is True
            and windows[0].get("ownerPID") == value["pid"], "invalid owned window")
    return windows[0]


def input_frame_durations(report):
    """Recompute durations; callback delivery may precede display time."""
    require(isinstance(report, dict), "missing input clock report")
    require(report.get("schemaVersion") == 3 and report.get("clockSource") == "mach_absolute_time",
            "input observer needs schema-3 raw clock evidence; legacy results remain descriptive")
    timebase = report.get("timebase", {})
    require(isinstance(timebase, dict), "invalid input clock timebase")
    numer, denom = timebase.get("numer"), timebase.get("denom")
    require(all(type(value) is int and 0 < value <= 0xffffffff for value in (numer, denom)),
            "invalid input clock timebase")
    samples = report.get("samples")
    require(isinstance(samples, list) and samples, "missing input clock samples")
    values, previous_validation = [], 0
    for index, sample in enumerate(samples, 1):
        require(isinstance(sample, dict), "invalid input clock sample")
        require(type(sample.get("sequence")) is int and sample["sequence"] == index,
                "missing/duplicate input clock sequence")
        frame = sample.get("frame", {})
        require(isinstance(frame, dict), "invalid input clock frame")
        before, after, validated = (sample.get(name) for name in
                                   ("postBeforeTicks", "postAfterTicks", "validationFinishedTicks"))
        display, callback = frame.get("displayTicks"), frame.get("callbackTicks")
        require(all(type(value) is int and 0 < value <= 0xffffffffffffffff
                    for value in (before, after, validated, display, callback)), "invalid input clock ticks")
        require(previous_validation <= before <= after <= validated
                and before < display <= validated and before <= callback <= validated,
                "invalid input clock order or overlapping key observations")
        duration = float(display - before) * numer / denom / 1_000_000
        offset_ticks = callback - display
        offset = float(abs(offset_ticks)) * numer / denom / 1_000_000
        if offset_ticks < 0:
            offset = -offset
        for field, expected in (("eventToFrameMs", duration), ("captureCallbackLagMs", offset)):
            value = sample.get(field)
            require(type(value) in (float, int) and math.isfinite(value)
                    and math.isclose(value, expected, rel_tol=1e-12, abs_tol=1e-12),
                    "input clock-derived " + field + " mismatch")
        values.append(duration)
        previous_validation = validated
    return values


def load_evidence(directory):
    directory = directory.resolve()
    require(not (directory / "failure.json").exists(), "failed benchmark")
    is_drain = (directory / "manifest.json").exists()
    metadata = read(directory / ("manifest.json" if is_drain else "metadata.json"))
    summary = read(directory / "summary.json")
    require(metadata.get("schemaVersion") == 2, "unsupported evidence schema")
    require(not metadata.get("diagnostic") and not summary.get("diagnostic"), "diagnostic trace run")
    if is_drain:
        require(metadata.get("state") == "complete" and summary.get("status") == "qualified", "incomplete drain")
        require(metadata.get("metric") == "raw-PTY-write-to-validated-DSR-response", "wrong drain metric")
        kind, case = "drain", "drain/" + metadata["workload"]["kind"]
        profile = metadata["arguments"]["profile"]
        target = grid_value(metadata["targetGrid"])
        machine = read(directory / "display-font-permissions.json")
        require(digest(directory / "payload.bin") == metadata["workload"]["sha256"], "payload hash mismatch")
        require((directory / "payload.bin").stat().st_size == metadata["workload"]["bytes"], "payload size mismatch")
        root = directory / "runs"
        hashes = metadata["harnessSHA256"]
    else:
        require(summary.get("valid") is True, "incomplete input observation")
        require(metadata.get("metric") == "synthetic-key-to-WindowServer-frame", "wrong input metric")
        require(metadata.get("panes") == 1, "four-pane CMDY-only evidence is not a comparative test")
        kind, case = "input", "input/" + ("editor" if metadata.get("fixture") == "vim" else metadata["markerMode"])
        profile = metadata.get("profile", "matched")
        target, machine = metadata["requestedGrid"], metadata["machine"]
        root, hashes = directory, metadata["toolingSHA256"]
    require(summary.get("metric") == metadata["metric"], "summary metric mismatch")
    require(profile in ("matched", "cmdy-defaults"), "unknown profile")
    binaries = {name: metadata["binaries"][name]["sha256"] for name in TERMINALS}
    require(all(re.fullmatch("[0-9a-f]{64}", value) for value in binaries.values()), "missing binary hashes")
    for name, expected in hashes.items():
        require(Path(name).name == name and digest(directory / "tooling" / name) == expected,
                "frozen harness hash mismatch: " + name)
    # New evidence must identify the font file, not just a fallback-prone name.
    require(re.fullmatch("[0-9a-f]{64}", metadata.get("fontSHA256", "")) is not None,
            "font hash unavailable; legacy evidence remains descriptive")
    power = power_signature(metadata["powerBefore"])
    blocks, display, observer_environment = {}, None, None
    run_paths = sorted(path for path in root.iterdir()
                       if re.fullmatch(r"\d{2}-(cmdy|ghostty)", path.name) and path.is_dir())
    require(bool(run_paths), "missing raw run directories")
    orders = {}
    for run in run_paths:
        number, terminal = run.name.split("-")
        block = int(number)
        launch = read(run / "launch.json")
        require(launch["terminal"] == terminal and launch["profile"] == profile, "launch profile mismatch")
        require("CMDY_FRAME_TRACE" not in launch["environment"], "trace environment in measured run")
        config = run / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
        require(digest(config) == launch["configSHA256"], "config hash mismatch")
        orders.setdefault(block, []).append((launch["startedMonotonicNS"], terminal))
        conditions = read(run / "power.json")
        require(all(power_signature(conditions[phase]) == power for phase in ("before", "after")),
                "power changed within/between blocks")
        before = checked_window(read(run / "window-before.json"))
        after = checked_window(read(run / "window-after.json"))
        require(before == after, "window changed during run")
        if display is None:
            display = before["displayID"]
        require(before["displayID"] == display, "display mismatch")
        values = []
        if is_drain:
            args = metadata["arguments"]
            native = read(run / "native-conditions.json")
            from competitive_bench import native_condition_signature
            # Read only; the signature function never launches native helpers.
            try:
                native_reference = native_condition_signature(metadata["nativeConditionsBefore"])
                require(native_condition_signature(metadata["nativeConditionsAfter"]) == native_reference
                        and all(native_condition_signature(native[phase]) == native_reference
                                for phase in ("before", "after")), "native drain conditions changed")
            except RuntimeError as error:
                raise ValueError(str(error)) from error
            observer_environment = native_reference
            ready = read(run / "ready.json")
            # Darwin can retain ONLCR's bit while OPOST is disabled. OPOST
            # decides whether output translation actually occurs.
            import termios
            require(ready.get("payloadSHA256") == metadata["workload"]["sha256"]
                    and ready.get("payloadBytes") == metadata["workload"]["bytes"]
                    and not (ready["ttyFlagsRaw"][1] & termios.OPOST), "fixture bytes/raw output mode mismatch")
            samples = [read(path) for path in sorted(run.glob("sample-*.json"))]
            require(len(samples) == args["warmups"] + args["samples"], "missing/extra drain samples")
            for index, sample in enumerate(samples):
                require(sample.get("status") == "valid" and sample.get("ok") is True, "invalid drain response")
                require(sample["block"] == block and sample["terminal"] == terminal
                        and sample["index"] == index and sample["sequence"] == index, "drain sequence mismatch")
                require(sample["warmup"] is (index < args["warmups"]), "warmup classification changed")
                require(grid_value(sample["gridBefore"]) == target
                        and sample["gridBefore"] == sample["gridAfter"], "drain grid mismatch")
                footer, reply = expected_reply(target[1], target[0], index)
                require(sample["footerHex"] == footer.hex() and sample["responseHex"] == reply.hex()
                        and sample["expectedResponseHex"] == reply.hex(), "DSR bytes mismatch")
                require(sample["payloadBytes"] == metadata["workload"]["bytes"], "unequal payload")
                require(checked_window(sample["windowBefore"]) == before
                        and checked_window(sample["windowAfter"]) == before, "drain focus/geometry failure")
                require(sample["finishedMonotonicNS"] - sample["startedMonotonicNS"] == sample["elapsedNS"],
                        "drain duration mismatch")
                if not sample["warmup"]:
                    values.append(sample["elapsedNS"] / 1e6)
        else:
            report = read(run / "latency.json")
            values = input_frame_durations(report)
            require(report["markerMode"] == metadata["markerMode"] and report["pid"] == launch["appPID"]
                    and report["windowID"] == before["windowID"], "observer target mismatch")
            environment = report["environment"]
            require(environment.get("thermalState") == 0 and type(environment.get("lowPowerMode")) is bool,
                    "non-nominal or missing observer thermal/power state")
            if observer_environment is None:
                observer_environment = environment
            require(environment == observer_environment, "observer environment changed")
            pane_before, pane_after = read(run / "grid-before.json"), read(run / "grid-after.json")
            require(pane_before == pane_after and grid_value(pane_before) == target, "input pane grid mismatch")
            samples, receipts = report["samples"], read(run / "fixture/received.json")
            require(read(run / "fixture-stop.json").get("complete") is True, "incomplete fixture cleanup")
            sequences = list(range(1, len(samples) + 1))
            require([item["sequence"] for item in samples] == sequences
                    and [item["sequence"] for item in receipts] == sequences, "missing/duplicate input receipts")
            require(len(samples) == metadata["samplesPerBlock"], "input sample count mismatch")
            require(all(grid_value(item) == target for item in receipts), "per-key grid mismatch")
            if metadata.get("fixture") == "vim":
                cleanup = read(run / "fixture/cleanup.json")
                require(metadata.get("editor", {}).get("binary", {}).get("sha256")
                        and metadata["editor"].get("runtimeSHA256"), "missing editor binary/runtime identities")
                require(cleanup.get("error") == "" and cleanup.get("insertedCharacters") == len(samples)
                        and cleanup.get("lastValidatedTextSHA256") == hashlib.sha256(b"a" * len(samples)).hexdigest()
                        and all(item.get("event") == "TextChangedI" for item in receipts), "editor edits were not verified")
        require(values and all(type(value) in (float, int) and math.isfinite(value) and value > 0 for value in values),
                "missing/nonpositive/nonfinite measurements")
        require(terminal not in blocks.setdefault(block, {}), "duplicate block/terminal")
        blocks[block][terminal] = values
    require(sorted(blocks) == list(range(len(blocks))), "nonconsecutive blocks")
    require(all(set(pair) == set(TERMINALS) and len(pair["cmdy"]) == len(pair["ghostty"])
                for pair in blocks.values()), "unpaired blocks or unequal counts")
    firsts = [sorted(orders[block])[0][1] for block in sorted(orders)]
    require(all(firsts[index] != firsts[index - 1] for index in range(1, len(firsts))),
            "block order was not counterbalanced")
    require(firsts.count("cmdy") == firsts.count("ghostty"), "both apps must start equally many blocks")
    if is_drain:
        require(len(blocks) == metadata["arguments"]["blocks"], "missing requested blocks")
        require(power_signature(metadata["powerAfter"]) == power, "final power changed")
    else:
        require(len(blocks) == metadata["requestedBlocks"], "missing requested blocks")
    return {"path": str(directory), "case": case, "kind": kind, "profile": profile,
            "power": power, "binaries": binaries, "grid": target, "blocks": blocks,
            "display": display, "font": machine["font"], "fontSHA256": metadata["fontSHA256"],
            "displays": machine["displays"], "observerEnvironment": observer_environment,
            "hardware": metadata.get("hardware", {}).get("stdout")}


def evaluate(paths, policy, expected_binaries):
    require(policy["maximumRatio"] == 1.0, "parity target must remain 1.0; no hidden regression allowance")
    require(policy["minimumPairedBlocks"] >= 6 and 0.95 <= policy["confidence"] < 1
            and policy["bootstrapResamples"] >= 1000, "policy weakens minimum evidence")
    require(set(expected_binaries) == set(TERMINALS), "both binary hashes must be pinned")
    require(all(re.fullmatch("[0-9a-f]{64}", value) for value in expected_binaries.values()), "invalid pinned binary hash")
    require(policy["minimumSamplesPerBlock"]["input"] >= 40
            and policy["minimumSamplesPerBlock"]["drain"] >= 20
            and policy["minimumSamplesPerBlock"].get("memory", 1) >= 1
            and policy["minimumSamplesPerBlock"].get("cpu", 3) >= 3, "policy weakens per-block sampling")
    accepted, errors, signatures = {}, [], {}
    scenarios = policy["scenarios"]
    cases = {item["id"]: item for item in policy["cases"]}
    for path in paths:
        try:
            manifest_path = path / "manifest.json"
            metadata_path = path / "metadata.json"
            benchmark_kind = read(manifest_path).get("benchmarkKind") if manifest_path.is_file() else None
            if benchmark_kind == "memory-block-campaign":
                from memory_block_evidence import load_memory_blocks
                items = load_memory_blocks(path, expected_binaries)
            elif benchmark_kind == "memory":
                from memory_parity_evidence import load_memory_evidence
                items = load_memory_evidence(path, expected_binaries)
            elif benchmark_kind == "scroll":
                from scroll_parity_evidence import load_scroll_evidence
                items = [load_scroll_evidence(path, expected_binaries)]
            elif benchmark_kind == "paste":
                from paste_parity_evidence import load_paste_evidence
                items = [load_paste_evidence(path, expected_binaries)]
            elif benchmark_kind == "startup-full-viewport-campaign-v1":
                from startup_parity_evidence import load_startup_evidence
                items = [load_startup_evidence(path, expected_binaries)]
            elif benchmark_kind == "resize-full-viewport-campaign-v1":
                from resize_parity_evidence import load_resize_evidence
                items = load_resize_evidence(path, expected_binaries)
            elif not manifest_path.is_file() and metadata_path.is_file() and read(metadata_path).get("adapter") == "comparative-four-pane":
                from four_pane_parity_evidence import load_four_pane_evidence
                items = [load_four_pane_evidence(path, expected_binaries)]
            else:
                items = [load_evidence(path)]
            for item in items:
                require(item["binaries"] == expected_binaries, "binary version differs from pinned candidate/comparator")
                matches = [entry["id"] for entry in scenarios if entry["profile"] == item["profile"]
                           and entry["powerSource"] == item["power"]["source"]]
                require(len(matches) == 1, "evidence does not identify one required scenario")
                scenario = matches[0]
                require(item["case"] in cases, "unknown case; add a required policy entry before using it")
                require("grid" not in cases[item["case"]] or cases[item["case"]]["grid"] == item["grid"],
                        "case grid differs from required grid")
                signature = {key: item[key] for key in ("power", "display", "font", "fontSHA256", "displays", "hardware")}
                require(signature["hardware"], "hardware identity unavailable")
                if scenario in signatures:
                    require(signatures[scenario] == signature, "scenario machine/font/display/power changed")
                signatures[scenario] = signature
                key = (scenario, item["case"])
                require(key not in accepted, "duplicate case/scenario; combine raw blocks explicitly instead of choosing a winner")
                accepted[key] = item
        except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
            errors.append({"path": str(path), "status": "invalid", "reason": str(error)})
    results = []
    for scenario in scenarios:
        for case in policy["cases"]:
            item = accepted.get((scenario["id"], case["id"]))
            for metric in case["metrics"]:
                result = {"scenario": scenario["id"], "case": case["id"], "metric": metric,
                          "status": "not-measured"}
                if item is not None:
                    require(metric in ("p50", "p95", "bytes", "cpuTime"), "adapter does not implement the requested metric")
                    require((metric == "bytes") == (item["kind"] == "memory"), "metric/adapter units mismatch")
                    require((metric == "cpuTime") == (item["kind"] == "cpu"), "metric/adapter units mismatch")
                    fraction = 0.95 if metric == "p95" else 0.5
                    seed = int.from_bytes(hashlib.sha256((scenario["id"] + case["id"] + metric).encode()).digest()[:8], "big")
                    if item["kind"] == "cpu":
                        require(all(math.isfinite(value) and value >= 0 for pair in item["blocks"].values()
                                    for values in pair.values() for value in values), "invalid idle CPU rate")
                        differences = [percentile(pair["cmdy"], fraction) - percentile(pair["ghostty"], fraction)
                                       for pair in item["blocks"].values()]
                        result.update(assess_cpu_differences(differences, policy, seed), evidence=item["path"])
                    else:
                        ratios = [percentile(pair["cmdy"], fraction) / percentile(pair["ghostty"], fraction)
                                  for pair in item["blocks"].values()]
                        result.update(assess_ratios(ratios, policy, seed), evidence=item["path"])
                    counts = [len(values) for pair in item["blocks"].values() for values in pair.values()]
                    result["minimumSamplesInBlock"] = min(counts)
                    if min(counts) < policy["minimumSamplesPerBlock"][item["kind"]]:
                        result["status"] = "insufficient-samples"
                results.append(result)
    passed = not errors and bool(results) and all(item["status"] == "pass" for item in results)
    return {"schemaVersion": 1, "passed": passed, "binaries": expected_binaries,
            "policy": policy, "scenarios": signatures, "results": results, "invalidEvidence": errors,
            "method": "nearest-rank per-block p50/p95; median paired CMDY/Ghostty ratios, or CPU-rate differences for zero-safe idle accounting; paired-block percentile bootstrap",
            "scope": "Recorded scenarios only. Per-metric intervals are not a simultaneous universal performance guarantee. Missing adapters/cases fail closed."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, action="append", default=[])
    parser.add_argument("--policy", type=Path, default=HERE / "parity-policy.json")
    parser.add_argument("--cmdy-sha256", required=True)
    parser.add_argument("--ghostty-sha256", required=True)
    parser.add_argument("--output", type=Path, help="new report file; an existing report is never overwritten")
    args = parser.parse_args(argv)
    try:
        report = evaluate(args.evidence, read(args.policy),
                          {"cmdy": args.cmdy_sha256, "ghostty": args.ghostty_sha256})
        encoded = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
        if args.output:
            with args.output.open("x") as stream:
                stream.write(encoded)
        counts = {status: sum(item["status"] == status for item in report["results"])
                  for status in sorted({item["status"] for item in report["results"]})}
        print(json.dumps({"passed": report["passed"], "counts": counts,
                          "invalidEvidence": report["invalidEvidence"], "output": str(args.output) if args.output else None}))
        return 0 if report["passed"] else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Parity gate failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
