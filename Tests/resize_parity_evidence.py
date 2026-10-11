"""Read-only admission of complete, explicitly guarded paired resize campaigns.

Single events, private fixture variants, pilot flags and producer summaries cannot
authorize this adapter. Every batch and the complete supervised campaign replay.
"""
from pathlib import Path
import hashlib
import json
import math

from competitive_bench import BenchOptions, terminal_config
from history_export_binding import validate_binding
from resize_batch_reader import validate_batch
from resize_calibration_evidence import validate_display_capture


KIND = "resize-full-viewport-campaign-v1"


def require(value, message):
    if not value: raise ValueError("resize campaign: " + message)


def read(path):
    require(path.is_file() and path.stat().st_size <= 128 * 1024 * 1024, "missing or unbounded evidence file")
    return json.loads(path.read_text())


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def contained(root, name):
    require(type(name) is str and not Path(name).is_absolute() and ".." not in Path(name).parts,
            "evidence path leaves campaign")
    value = root / name
    require(value.resolve().is_relative_to(root), "evidence symlink leaves campaign")
    return value


def expected_cases():
    result = []
    for block in range(6):
        for profile in ("matched", "cmdy-defaults"):
            order = ("ghostty", "cmdy") if (block + (profile == "cmdy-defaults")) % 2 == 0 else ("cmdy", "ghostty")
            result.extend(dict(profile=profile, terminal=terminal, block=block) for terminal in order)
    return result


def validate_plan(plan, binaries):
    require(plan["cases"] == expected_cases() and plan["nativeAppLaunches"] == 24
            and plan["pairsPerProfile"] == 6 and plan["eventsPerApp"] == 42
            and plan["warmupsPerApp"] == 2 and plan["measuredEventsPerApp"] == 40
            and type(plan["historyGrowthGuardRows"]) is int and plan["historyGrowthGuardRows"] == 4
            and plan["fixtureVariant"] == "explicit-four-row-history-growth-guard-v1"
            and "fixtureOverlays" not in plan and plan["performanceAdmission"] is False,
            "not a complete prospectively declared guarded campaign")
    require(plan["candidateExecutableSHA256"] == binaries["cmdy"]
            and plan["comparatorExecutableSHA256"] == binaries["ghostty"]
            and plan["powerSource"] in ("AC Power", "Battery Power")
            and plan["minimumInitialIdleSeconds"] >= 300
            and plan["lowPowerMode"] is False and plan["thermalState"] == 0,
            "binary or native condition declaration differs")
    require(plan["policySHA256"] == digest(Path(__file__).with_name("parity-policy.json")), "policy differs")


def validate_raw_audit(audit, plan, plan_hash):
    label = {"AC Power": "AC", "Battery Power": "battery"}.get(plan["powerSource"])
    require(label is not None
            and audit["status"] == f"pass-independent-complete-{label}-resize-campaign-audit"
            and audit["planSHA256"] == plan_hash, "completed raw audit missing")


def validate_supervision(root, plan, episode):
    parent, supervisor = read(root / "run-process.json"), read(root / "supervisor-process.json")
    plan_hash = digest(root / "episode-01/plan.json")
    require(episode["status"] == "pass" and len(episode["steps"]) == 24
            and supervisor["reaped"] is True and supervisor["exitCode"] == 0
            and supervisor["pid"] == episode["supervisorPID"]
            and supervisor["parentPID"] == parent["pid"] == episode["parentPID"]
            and parent["planSHA256"] == supervisor["planSHA256"] == plan_hash
            and not episode.get("forcedControllerKill"), "supervisor or parent cleanup differs")
    require(episode["initialPowerSignature"] == episode["finalPowerSignature"]
            and episode["initialPowerSignature"]["source"] == plan["powerSource"], "power changed")
    for key in ("initialNativeConditions", "finalNativeConditions"):
        value = episode[key]
        require(value["ok"] is True and value["lowPowerMode"] is False and value["thermalState"] == 0,
                "native conditions invalid")
    require(episode["initialNativeConditions"]["os"] == episode["finalNativeConditions"]["os"], "OS build changed")
    initial = episode["initialActivity"]
    require(all(type(initial[k]) in (int, float) and math.isfinite(initial[k]) and initial[k] >= 300
                for k in ("idleSeconds", "hardwareIdleSeconds")), "initial idle requirement failed")
    previous = initial["sessionReadFinishedMonotonicNS"]
    samples = [json.loads(line) for line in (root / "episode-01/activity.jsonl").read_text().splitlines()]
    require(bool(samples), "activity chronology missing")
    for sample in samples:
        tick = sample["readStartedMonotonicNS"]
        elapsed = (tick - initial["sessionReadFinishedMonotonicNS"]) / 1e9
        require(type(tick) is int and tick >= previous and sample["returned"] is False
                and sample["sessionClockReset"] is False and type(sample["idleSeconds"]) in (int, float)
                and math.isfinite(sample["idleSeconds"])
                and sample["idleSeconds"] + 2 >= initial["idleSeconds"] + elapsed,
                "activity reset or missing clock order")
        previous = tick
    return {parent["pid"], supervisor["pid"]}


def validate_machine(root, plan, episode, first_start, last_finish, display):
    """Supplementary static identity is explicitly post-run, never a condition probe.

    Native conditions and full display-mode proofs come from the campaign itself.
    The system font is on the read-only OS volume, with identity times predating
    the first app. The raw CoreText/CG and hardware queries remain separately bound.
    """
    directory = root / "post-campaign-machine"; identity = read(directory / "identity.json")
    require(identity["scope"] == "supplementary-post-campaign-machine-identification"
            and identity["capturedBeforeCampaign"] is False
            and identity["doesNotReplaceNativeConditionsOrPerEventDisplayProof"] is True,
            "machine observation timing/scope differs")
    calls = {}
    for name, checksum in identity["files"].items():
        path = contained(directory.resolve(), name)
        require(digest(path) == checksum, "machine query receipt changed")
        call = read(path)
        require(call["reaped"] is True and call["exitCode"] == 0 and call["stderr"] == ""
                and last_finish <= call["startedMonotonicNS"] <= call["finishedMonotonicNS"],
                "machine query failed or was not post-campaign")
        calls[name] = call
    require(set(calls) == {"display-font-probe.json", "hardware.json", "conditions.json"}, "machine query coverage differs")
    require(calls["display-font-probe.json"]["arguments"] == [plan["helper"], "probe", "14"]
            and calls["conditions.json"]["arguments"] == [plan["helper"], "conditions"]
            and calls["hardware.json"]["arguments"] == ["/usr/sbin/sysctl", "hw.model", "hw.memsize",
                "hw.physicalcpu", "hw.logicalcpu", "machdep.cpu.brand_string"], "machine query arguments differ")
    probe = json.loads(calls["display-font-probe.json"]["stdout"])
    conditions = json.loads(calls["conditions.json"]["stdout"])
    signature = identity["signature"]; font = identity["fontIdentity"]
    require(signature["font"] == probe["font"] == dict(family="Menlo", file="/System/Library/Fonts/Menlo.ttc",
                postScriptName="Menlo-Regular", sizePoints=14)
            and signature["fontSHA256"] == digest(Path(font["path"]))
            and font["path"] == signature["font"]["file"] and font["filesystemReadOnly"] is True
            and font["mtimeNS"] < first_start * 1_000_000_000
            and font["ctimeNS"] < first_start * 1_000_000_000,
            "font identity differs or postdates campaign")
    require(signature["hardware"] == calls["hardware.json"]["stdout"].strip() and signature["hardware"]
            and signature["displays"] == probe["displays"] and signature["display"] == plan["displayID"]
            and signature["power"] == episode["initialPowerSignature"]
            and conditions["os"] == episode["initialNativeConditions"]["os"] == episode["finalNativeConditions"]["os"]
            and identity["helperSHA256"] == digest(Path(plan["helper"])), "static machine signature differs")
    targets = [v for v in probe["displays"] if v["displayID"] == display["displayID"]]
    require(len(targets) == 1 and targets[0]["bounds"] == display["displayBounds"]
            and targets[0]["pixelWidth"] == display["captureWidth"]
            and targets[0]["pixelHeight"] == display["captureHeight"]
            and targets[0]["refreshRate"] == display["displayRefreshRate"], "post-run display differs from native observations")
    return signature


def load_resize_evidence(directory, expected_binaries):
    root = Path(directory).resolve(); manifest = read(root / "manifest.json")
    require(manifest["schemaVersion"] == 1 and manifest["benchmarkKind"] == KIND
            and manifest["state"] == "complete", "campaign manifest incomplete")
    plan = read(root / "episode-01/plan.json"); episode = read(root / "episode-01/episode.json")
    require(manifest["planSHA256"] == digest(root / "episode-01/plan.json")
            and manifest["rawAuditSHA256"] == digest(root / "independent-audit.json")
            and manifest["machineIdentitySHA256"] == digest(root / "post-campaign-machine/identity.json"),
            "campaign binding changed")
    validate_plan(plan, expected_binaries)
    audit = read(root / "independent-audit.json")
    validate_raw_audit(audit, plan, manifest["planSHA256"])
    for name, checksum in audit["files"].items():
        require(digest(contained(root, name)) == checksum, "sealed raw evidence changed")
    snapshots = manifest["sourceSnapshots"]
    for original, checksum in plan["frozenInputs"].items():
        source = contained(root, snapshots[original]) if original in snapshots else Path(original)
        require(digest(source) == checksum, "recorded runtime/source input changed")
    require(set(snapshots) <= set(plan["frozenInputs"]), "unregistered source snapshot")
    owned = validate_supervision(root, plan, episode)
    blocks = {profile: {} for profile in ("matched", "cmdy-defaults")}
    previous_finish = 0; first_start = None; reference_display = None
    for case, step in zip(plan["cases"], episode["steps"]):
        label = f"{case['profile']}-block{case['block']:02d}-{case['terminal']}"
        run = root / label; controller = read(root / (label + "-controller.json"))
        launch, cleanup = read(run / "launch.json"), read(run / "cleanup.json")
        ready, worker = read(run / "fixture/ready.json"), read(run / "fixture/cleanup.json")
        request, binding = read(run / "batch/request.json"), read(run / "binding.json")
        require(step["name"] == label and step["reaped"] is True and step["exitCode"] == 0
                and step["pid"] == controller["controllerPID"] and controller["status"] == "pass"
                and controller["appReaped"] is True and controller["originalWorkerAbsent"] is True
                and cleanup["returncode"] in (0, -15) and not cleanup.get("forcedKill"), "app/controller cleanup failed")
        require(launch["appPID"] == controller["appPID"] == cleanup["appPID"] == request["nativeSpec"]["pid"]
                and launch["workerPID"] == controller["workerPID"] == ready["pid"] == worker["pid"]
                and launch["arguments"][0] == plan["binaries"][case["terminal"]]
                and request["nativeSpec"]["executableSHA256"] == expected_binaries[case["terminal"]], "app or worker provenance differs")
        require(request["block"] == case["block"] and request["terminal"] == case["terminal"]
                and request["profile"] == case["profile"] and request["nonce"] == plan["nonce"]
                and ready["calibrationNonce"] == plan["calibrationNonce"]
                and request["historyGrowthGuardRows"] == ready["historyGrowthGuardRows"] == 4,
                "paired workload provenance differs")
        require(launch["fixtureCommand"] == binding["worker"] and "--history-growth-guard" in binding["worker"]
                and launch["childUmask"] == binding["childUmask"] == 0o077
                and launch["environment"]["TMPDIR"] == binding["temporaryDirectory"] + "/",
                "public export isolation differs")
        expected_private = {binding["temporaryDirectory"], binding["controlDirectory"], str(Path(launch["cwd"]).parent)}
        require(len(controller["privatePaths"]) == 3
                and {v["path"] for v in controller["privatePaths"]} == expected_private
                and all(v["absent"] is True for v in controller["privatePaths"]), "private cleanup incomplete")
        config = Path(launch["config"])
        expected = terminal_config(case["terminal"], BenchOptions(Path(plan["binaries"]["cmdy"]),
            Path(plan["binaries"]["ghostty"]), profile=case["profile"], font_size=14), (120, 36), Path(launch["cwd"]))
        if case["terminal"] == "ghostty":
            expected += "scrollback-limit = 100000000\nkeybind = ctrl+shift+enter=write_scrollback_file:paste\n"
        require(config.read_text() == expected and digest(config) == launch["configSHA256"], "native profile/config differs")
        validate_binding(case["terminal"], config, binding["shortcutBinding"])
        if case["terminal"] == "cmdy":
            exported, deleted = cleanup["defaultsExport"], cleanup["defaultsDelete"]
            # Reuse the isolated launcher's exact empty-domain classification.
            import sys
            native = Path(__file__).resolve().parent / "NativePerformance"
            if str(native) not in sys.path: sys.path.append(str(native))
            from owned_defaults_cleanup import classify_owned_defaults_cleanup
            classify_owned_defaults_cleanup(launch["defaultsDomain"], exported, deleted)
        result = validate_batch(run)
        require(result == read(run / "batch-audit.json") and result["historyGrowthGuardRows"] == 4,
                "recorded batch audit differs")
        observed = read(run / "batch/timed/native/0001.json"); validate_display_capture(observed)
        display = {k: observed[k] for k in ("displayID", "displayMode", "displayBounds", "captureWidth",
            "captureHeight", "displayRefreshRate", "requestedFPS", "timebase")}
        if reference_display is None: reference_display = display
        require(display == reference_display and observed["identity"]["executable"] == plan["binaries"][case["terminal"]]
                and launch["startedMonotonicNS"] >= previous_finish, "display changed or app runs overlap")
        previous_finish = worker["finishedMonotonicNS"]
        first_start = min(first_start or observed["identity"]["startSeconds"], observed["identity"]["startSeconds"])
        owned.update((step["pid"], launch["appPID"], worker["pid"], worker["parentPID"], *result["observerPIDs"]))
        for path in run.rglob("cleanup.json"):
            value = read(path)
            if "ownedPID" in value:
                require(value["exited"] is True and value["pipesClosed"] is True and value["returncode"] == 0,
                        "native observer cleanup failed")
                owned.add(value["ownedPID"])
        for path in run.rglob("process.json"):
            value = read(path)
            if "pid" in value:
                require(value["reaped"] is True and value["exitCode"] == 0, "history helper cleanup failed")
                owned.add(value["pid"])
        blocks[case["profile"]].setdefault(case["block"], {})[case["terminal"]] = [v / 1e6 for v in result["samplesNS"]]
    require(sorted(owned) == audit["allRecordedOwnedPIDsAbsent"], "owned process audit coverage differs")
    signature = validate_machine(root, plan, episode, first_start, previous_finish, reference_display)
    return [dict(path=str(root), case="resize", kind="input", profile=profile,
        binaries=expected_binaries, blocks=groups, grid=[120, 36], observerEnvironment=dict(
            historyGrowthGuardRows=4, pixelFixtureVersion=2, supplementaryMachineIdentity="post-campaign"), **signature)
        for profile, groups in blocks.items()]
