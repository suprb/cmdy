"""Independent receipt failures and bounded pipe ownership; no native UI."""
from copy import deepcopy
import base64
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from resize_controller import expected_event
from resize_evidence import config_signature, signed_ns, validate_event, validate_document
from resize_protocol import digest, cell_classes_bytes
from resize_contract import OBSERVATION_SCOPE, require_qualifying_adapter
from test_bench_ancestry import ancestry_fixture

NONCE = "0123456789abcdef0123456789abcdef"


def display_mode(width=1800, height=1200):
    return dict(modeID=7, flags=0, width=width, height=height, pixelWidth=width,
                pixelHeight=height, refreshRate=60, rotation=0)


def fixture():
    identity = dict(pid=123, parentPID=100, uid=501, startSeconds=1, startMicroseconds=2, executable="/generated/owned")
    display = dict(identity=identity, workerIdentity={**identity, "pid": 124, "parentPID": 123}, fixtureVersion=2, windowID=456, displayID=1,
                   timebase=dict(numer=1, denom=1), observationScope=OBSERVATION_SCOPE, qualifying=False,
                   requestClock="mach_absolute_time", frameClock="SCStreamFrameInfo.displayTime",
                   displayBounds=dict(x=0, y=0, width=1800, height=1200), captureWidth=1800,
                   captureHeight=1200, requestedFPS=120, displayRefreshRate=60, displayMode=display_mode())
    display["initialAncestry"] = ancestry_fixture(identity, display["workerIdentity"], start=100)[0]
    source = dict(columns=120, rows=36, outerBounds=dict(x=10, y=10, width=1000, height=600))
    target = dict(columns=132, rows=40, outerBounds=dict(x=10, y=10, width=1100, height=700))
    def proof(ticks, bounds):
        return dict(identity=identity, windowID=456, displayID=1, bounds=bounds,
                    foregroundPID=123, occluded=False, queriedTicks=ticks)
    def frame(ticks, matching):
        bounds = target["outerBounds"] if matching else source["outerBounds"]
        callback = ticks + 100_000
        return dict(displayTicks=ticks, callbackTicks=callback, checkedTicks=callback+3, matching=matching,
            before=proof(callback+1, bounds), after=proof(callback+2, bounds))
    planned = dict(sequence=1, columns=132, rows=40, warmup=True)
    expected = expected_event(NONCE, planned)
    frames = [frame(89_000_000, False), frame(100_000_000, True)]
    first = frames[1]
    observed = base64.b64encode(cell_classes_bytes(NONCE, 1, 132, 40)).decode()
    first["observedCellClasses"] = observed
    worker = dict(sequence=1, grid=dict(columns=132, rows=40), sourceGrid=[120, 36],
        offeredBytes=expected["payloadBytes"], completedBytes=expected["payloadBytes"],
        payloadSHA256=expected["payloadSHA256"], armSignalCounter=0, signalCounter=1,
        armedTicks=89_500_000, signalReceivedTicks=91_000_000, observedTicks=92_000_000,
        startedTicks=93_000_000, completedTicks=100_200_000)
    observer = dict(ok=True, op="complete", observationScope=OBSERVATION_SCOPE, fixtureVersion=2, qualifying=False, sequence=1, finalTTYGrid=worker["grid"],
        action=dict(beforeTicks=90_000_000, afterTicks=100_500_000, axCallCount=1, axResult=0,
                    requestedBounds=target["outerBounds"], beforeProof=proof(89_900_000, source["outerBounds"]),
                    afterProof=proof(100_500_001, target["outerBounds"])),
        frames=frames, firstCompleteFrame=dict(complete=True, matchedRows=40, matchedCells=5280, cellClassesSHA256=expected["cellClassesSHA256"], words=expected["words"], observedCellClasses=observed,
            **{key:first[key] for key in ("displayTicks", "callbackTicks", "checkedTicks")},
            beforeProof=first["before"], afterProof=first["after"]),
        finalProof=proof(150_100_009, target["outerBounds"]), finishedTicks=150_100_029,
        finalAncestry=ancestry_fixture(identity, display["workerIdentity"], start=150_100_010)[0],
        stableAfterFirst=True, ownershipValid=True, signedClockValid=True, observerFailures=[],
        metricsNS=dict(requestToFrameNS=10_000_000, requestReturnOffsetNS=10_500_000,
                       frameMinusRequestReturnNS=-500_000, captureCallbackLagNS=100_000, stabilityValidationNS=50_000_029),
        statusRecords=[dict(status=2, callbackTicks=88_000_000)] +
            [dict(status=0, callbackTicks=row["callbackTicks"], displayTicks=row["displayTicks"]) for row in frames] +
            [dict(status=1, callbackTicks=150_000_000, displayTicks=100_000_000)])
    entry = dict(expected=expected, worker=worker, observer=observer,
        arm=dict(ok=True, pid=124, pending=dict(sequence=1, target=[132,40], signalCounter=0)))
    return entry, planned, display, source, target


class EvidenceTests(unittest.TestCase):
    def test_independent_signed_first_frame_and_idle_validation(self):
        entry, planned, display, source, target = fixture()
        self.assertEqual(validate_event(entry, planned, NONCE, display, source, target), 10_000_000)
        self.assertLess(entry["observer"]["metricsNS"]["frameMinusRequestReturnNS"], 0)

    def test_signed_fractional_clock_matches_integer_native_conversion(self):
        self.assertEqual(signed_ns(5, 2, dict(numer=125, denom=3)), 125)
        self.assertEqual(signed_ns(2, 4, dict(numer=125, denom=3)), -83)

    def test_future_display_keeps_negative_callback_lag_and_first_endpoint(self):
        entry, planned, display, source, target = fixture()
        observer = entry["observer"]
        first = observer["frames"][-1]
        first["callbackTicks"] = 95_000_000
        first["before"]["queriedTicks"] = 95_000_001
        first["after"]["queriedTicks"] = 95_000_002
        first["checkedTicks"] = 95_000_003
        observer["statusRecords"][2]["callbackTicks"] = first["callbackTicks"]
        observer["firstCompleteFrame"].update({key: first[key] for key in ("displayTicks", "callbackTicks", "checkedTicks")})
        observer["metricsNS"]["captureCallbackLagNS"] = -5_000_000
        observer["metricsNS"]["stabilityValidationNS"] = observer["finishedTicks"] - first["callbackTicks"]
        self.assertEqual(validate_event(entry, planned, NONCE, display, source, target), 10_000_000)
        self.assertEqual(observer["firstCompleteFrame"]["displayTicks"], 100_000_000)
        self.assertLess(observer["metricsNS"]["captureCallbackLagNS"], 0)
        # Waiting 50ms only after callback must not qualify the later display.
        observer["statusRecords"][-1]["callbackTicks"] = 144_999_999
        observer["finishedTicks"] = 145_000_020
        observer["finalProof"]["queriedTicks"] = 145_000_000
        observer["finalAncestry"] = ancestry_fixture(display["identity"], display["workerIdentity"], start=145_000_001)[0]
        observer["metricsNS"]["stabilityValidationNS"] = 50_000_020
        with self.assertRaisesRegex(ValueError, "stability"):
            validate_event(entry, planned, NONCE, display, source, target)

    def test_blank_or_restarted_status_cannot_hide_behind_earlier_callback(self):
        for status in (2, 4):
            for display_ticks in (100_000_000, 100_100_000):
                with self.subTest(status=status, display_ticks=display_ticks):
                    entry, planned, display, source, target = fixture()
                    entry["observer"]["statusRecords"].insert(2,
                        dict(status=status, callbackTicks=99_000_000, displayTicks=display_ticks))
                    with self.assertRaisesRegex(ValueError, "blank/restarted"):
                        validate_event(entry, planned, NONCE, display, source, target)

    def test_wholly_pre_first_blank_status_with_absent_or_zero_display_is_retained(self):
        for display_ticks in (None, 0, 99_999_999):
            with self.subTest(display_ticks=display_ticks):
                entry, planned, display, source, target = fixture()
                entry["observer"]["statusRecords"].insert(2,
                    dict(status=2, callbackTicks=99_000_000, displayTicks=display_ticks))
                self.assertEqual(validate_event(entry, planned, NONCE, display, source, target), 10_000_000)

    def test_future_status_and_later_frame_must_be_enclosed_by_final_validation(self):
        for kind in ("status", "later-frame", "callback-query-order", "pre-request-matching-callback", "oversized-clock"):
            with self.subTest(kind=kind):
                entry, planned, display, source, target = fixture()
                observer = entry["observer"]
                if kind == "status":
                    observer["statusRecords"][-1]["displayTicks"] = observer["finishedTicks"] + 1
                elif kind == "later-frame":
                    later = deepcopy(observer["frames"][-1])
                    later["displayTicks"] = observer["finishedTicks"] + 1
                    later["callbackTicks"] = 110_000_000
                    later["before"]["queriedTicks"] = 110_000_001
                    later["after"]["queriedTicks"] = 110_000_002
                    later["checkedTicks"] = 110_000_003
                    observer["frames"].append(later)
                    observer["statusRecords"].insert(-1, dict(status=0,
                        callbackTicks=later["callbackTicks"], displayTicks=later["displayTicks"]))
                elif kind == "callback-query-order":
                    observer["frames"][-1]["before"]["queriedTicks"] = 99_000_000
                elif kind == "pre-request-matching-callback":
                    observer["frames"][-1]["callbackTicks"] = 89_500_000
                else:
                    observer["frames"][-1]["displayTicks"] = (1 << 64) - 1
                with self.assertRaises(ValueError):
                    validate_event(entry, planned, NONCE, display, source, target)

    def test_malformed_clock_types_and_event_validation_deadline_fail(self):
        for clock in (-1, True, (1 << 64) - 1):
            with self.subTest(clock=clock):
                entry, planned, display, source, target = fixture()
                entry["observer"]["statusRecords"][-1]["displayTicks"] = clock
                with self.assertRaises(ValueError):
                    validate_event(entry, planned, NONCE, display, source, target)
        entry, planned, display, source, target = fixture()
        observer = entry["observer"]
        observer["finishedTicks"] = observer["action"]["beforeTicks"] + 3_100_000_000
        observer["finalProof"]["queriedTicks"] = observer["finishedTicks"] - 21
        observer["finalAncestry"] = ancestry_fixture(display["identity"], display["workerIdentity"], start=observer["finishedTicks"] - 20)[0]
        observer["metricsNS"]["stabilityValidationNS"] = observer["finishedTicks"] - observer["frames"][-1]["callbackTicks"]
        with self.assertRaisesRegex(ValueError, "stability"):
            validate_event(entry, planned, NONCE, display, source, target)

    def test_each_required_receipt_boundary_rejects_corruption(self):
        def alter(path, value):
            item = fixture()
            current = item[0]
            for part in path[:-1]: current = current[part]
            current[path[-1]] = value
            return item
        cases = [(["worker","signalCounter"],0), (["worker","completedBytes"],1),
            (["observer","action","axCallCount"],2), (["observer","action","axResult"],-1),
            (["observer","action","beforeProof","foregroundPID"],999),
            (["observer","firstCompleteFrame","displayTicks"],100_000_001),
            (["observer","firstCompleteFrame","matchedRows"],39),
            (["observer","metricsNS","frameMinusRequestReturnNS"],500_000),
            (["observer","metricsNS","requestToFrameNS"],1),
            (["observer","finalProof","windowID"],999),
            (["observer","frames",1,"after","occluded"],True),
            (["observer","frames",1,"before","queriedTicks"],1),
            (["observer","statusRecords",-1,"status"],2),
            (["observer","statusRecords",-1,"status"],3),
            (["observer","statusRecords",-1,"status"],4),
            (["observer","statusRecords",-1,"status"],5),
            (["arm","pending","sequence"],2)]
        for path, value in cases:
            with self.subTest(path=path, value=value), self.assertRaises(ValueError):
                entry, planned, display, source, target = alter(path, value)
                validate_event(entry, planned, NONCE, display, source, target)

    def test_correct_later_frame_cannot_replace_first(self):
        entry, planned, display, source, target = fixture()
        later = deepcopy(entry["observer"]["frames"][-1])
        later.pop("observedCellClasses")
        for key in ("displayTicks","callbackTicks","checkedTicks"): later[key] += 1_000_000
        for key in ("before","after"): later[key]["queriedTicks"] += 1_000_000
        entry["observer"]["frames"].append(later)
        entry["observer"]["statusRecords"].insert(-1, dict(status=0, callbackTicks=later["callbackTicks"], displayTicks=later["displayTicks"]))
        entry["observer"]["firstCompleteFrame"].update({key:later[key] for key in ("displayTicks","callbackTicks","checkedTicks")})
        with self.assertRaisesRegex(ValueError, "substituted"):
            validate_event(entry, planned, NONCE, display, source, target)

    def test_config_normalizes_only_exact_private_working_directory(self):
        a = "font-size = 14\nworking-directory = /private/owned-a\n"
        b = "font-size = 14\nworking-directory = /private/owned-b\n"
        self.assertEqual(config_signature(a,"/private/owned-a","ghostty"), config_signature(b,"/private/owned-b","ghostty"))
        self.assertNotEqual(config_signature(a+"extra = true\n","/private/owned-a","ghostty"), config_signature(b,"/private/owned-b","ghostty"))
        with self.assertRaises(ValueError): config_signature(a,"/private/unrelated","ghostty")

    def test_complete_status_and_checked_frame_are_bijective(self):
        for kind in ("missing-frame", "missing-status", "duplicate-frame", "duplicate-status", "duplicate-both"):
            entry, planned, display, source, target = fixture()
            frames, statuses = entry["observer"]["frames"], entry["observer"]["statusRecords"]
            if kind == "missing-frame": frames.pop(0)
            if kind == "missing-status": statuses.pop(1)
            if kind in ("duplicate-frame", "duplicate-both"): frames.insert(0, deepcopy(frames[0]))
            if kind in ("duplicate-status", "duplicate-both"): statuses.insert(1, deepcopy(statuses[1]))
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "one-to-one"):
                validate_event(entry, planned, NONCE, display, source, target)

    def test_full_width_cells_digest_and_version_required(self):
        for field, value in (("matchedCells", 62 * 40), ("matchedCells", 5279),
                             ("cellClassesSHA256", "0" * 64)):
            entry, planned, display, source, target = fixture()
            entry["observer"]["firstCompleteFrame"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "full-width"):
                validate_event(entry, planned, NONCE, display, source, target)

    def test_observed_stream_rejects_tail_corruption_even_with_matching_forged_hash(self):
        for kind in ("last-cell", "interior-cell", "missing-cell", "duplicate-row", "invalid-base64", "missing-stream"):
            entry, planned, display, source, target = fixture()
            result = entry["observer"]["firstCompleteFrame"]
            observed = bytearray(base64.b64decode(result["observedCellClasses"]))
            if kind == "last-cell": observed[-1] = 0
            if kind == "interior-cell": observed[20 * 132 + 93] ^= 1
            if kind == "missing-cell": observed.pop()
            if kind == "duplicate-row": observed[132:264] = observed[:132]
            encoded = base64.b64encode(observed).decode()
            if kind == "invalid-base64": encoded = "not base64!"
            if kind == "missing-stream": encoded = ""
            result.update(observedCellClasses=encoded, cellClassesSHA256=digest(observed), matchedCells=len(observed))
            entry["observer"]["frames"][-1]["observedCellClasses"] = encoded
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                validate_event(entry, planned, NONCE, display, source, target)
        for version in (1, None):
            entry, planned, display, source, target = fixture()
            entry["observer"]["fixtureVersion"] = version
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "version"):
                validate_event(entry, planned, NONCE, display, source, target)

    def test_boolean_count_and_forged_ancestry_or_clock_fail(self):
        for kind in ("AX", "cell-count", "metric", "ancestry", "ancestry-clock"):
            entry, planned, display, source, target = fixture()
            o = entry["observer"]
            if kind == "AX": o["action"]["axCallCount"] = True
            if kind == "cell-count": o["firstCompleteFrame"]["matchedCells"] = True
            if kind == "metric": o["metricsNS"]["requestToFrameNS"] = 10_000_000.0
            if kind == "ancestry": o["finalAncestry"]["secondWalkReverse"].pop()
            if kind == "ancestry-clock": o["finalAncestry"]["finishedTicks"] = o["finishedTicks"] + 1
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                validate_event(entry, planned, NONCE, display, source, target)

    def test_signed_conversion_rejects_native_overflow(self):
        with self.assertRaisesRegex(ValueError, "overflow"):
            signed_ns((1 << 63) - 1, 0, dict(numer=1_000_000_000, denom=1))

    def test_qualifying_admission_cannot_be_enabled_by_raw_receipts(self):
        # Generated fixtures and legacy export claims cannot authorize an
        # unimplemented native transport, even when every event is well formed.
        for claimed in ({}, {"valid": True}, {"historyBefore": {"clipboardRestored": True}},
                        {"nativeExportVerified": True, "retainedRows": 1000}):
            with self.subTest(claimed=claimed), self.assertRaisesRegex(ValueError, "admission blocked"):
                require_qualifying_adapter(claimed)

    def test_qualifying_clis_fail_before_native_launch_or_evidence_read(self):
        from resize_recorder import main as recorder_main
        from resize_evidence import main as evidence_main
        for main, arguments in ((recorder_main, ["--qualify"]),
                                (evidence_main, ["/not-a-real-resize-receipt.json", "--qualify"])):
            output = io.StringIO()
            with redirect_stdout(output), patch("subprocess.Popen", side_effect=AssertionError("native launch")):
                self.assertEqual(main(arguments), 2)
            result = json.loads(output.getvalue())
            self.assertFalse(result["qualifying"])
            self.assertIn("admission blocked", result["error"])



class NativePipeTests(unittest.TestCase):
    def test_foreign_calibration_is_rejected_before_arming_native_or_worker(self):
        from resize_recorder import record_diagnostic
        from test_resize_calibration import document_fixture, rehash
        for side in ("source", "target"):
            document = document_fixture()
            item = document[side + "Discovery"]
            evidence = json.loads(item["evidenceUTF8"])
            evidence["window"]["windowID"] = 999
            rehash(item, evidence); document[side] = item["calibration"]
            request = {key: document[key] for key in ("schemaVersion", "qualifying", "nonce", "source",
                "target", "sourceDiscovery", "targetDiscovery", "planned")}
            request.update(nativeSpec=dict(nonce=NONCE, workerPID=124, ttyPath="/dev/ttys123"),
                workerReady=dict(pid=124, ttyPath="/dev/ttys123"), workerCapability=NONCE, sourceSequence=0)
            started = document["display"]
            started["initialTTYGrid"] = dict(columns=120, rows=36)
            with self.subTest(side=side), tempfile.TemporaryDirectory(prefix="resize-join-") as temporary:
                with patch("resize_recorder.validate_build", return_value={}), patch("resize_recorder.Native") as native, \
                        patch("resize_recorder.worker_request", side_effect=AssertionError("worker armed")):
                    native.return_value.started = started
                    with self.assertRaisesRegex(ValueError, "identity differ"):
                        record_diagnostic(Path("/unused"), Path("/unused"), request, Path(temporary) / "run")
                    native.return_value.request.assert_not_called()
                    native.return_value.close.assert_called_once_with(False)

    def executable(self, directory, mode):
        script=directory/"owned-fake-native.py"
        script.write_text(f"#!{sys.executable}\n" +
            "import json,sys\n" +
            ("print(json.dumps({'ok':False,'op':'startup-failure'}),flush=True)\n" if mode=="failure" else
             "print(json.dumps({'ok':True,'op':'started'}),flush=True)\n") +
            "for line in sys.stdin:\n" +
            " v=json.loads(line)\n" +
            " if v['op']=='finish': print(json.dumps({'ok':True,'op':'finished'}),flush=True); break\n" +
            " print(json.dumps({'ok':True,'op':v['op'],'sequence':v.get('sequence',0)+" + ("1" if mode=="stale" else "0") + "}),flush=True)\n")
        script.chmod(0o700); return script

    def test_native_pipe_finishes_and_reaps_exact_owned_process(self):
        from resize_recorder import Native
        with tempfile.TemporaryDirectory(prefix="resize-pipe-") as temporary:
            directory=Path(temporary)
            process=Native(self.executable(directory,"valid"),directory,{})
            process.request("verify",sequence=3); process.close(True)
            record=json.loads((directory/"native/cleanup.json").read_text())
            self.assertTrue(record["exited"]); self.assertEqual(record["returncode"],0)

    def test_failed_startup_retains_receipt_and_reaps_before_raising(self):
        from resize_recorder import Native
        with tempfile.TemporaryDirectory(prefix="resize-pipe-") as temporary:
            directory=Path(temporary)
            with self.assertRaises(RuntimeError): Native(self.executable(directory,"failure"),directory,{})
            record=json.loads((directory/"native/cleanup.json").read_text())
            self.assertTrue(record["exited"]); self.assertFalse(record["successfulBlock"])
            with self.assertRaises(ProcessLookupError): os.kill(record["ownedPID"],0)

    def test_wrong_native_sequence_fails_and_owned_cleanup_survives(self):
        from resize_recorder import Native
        with tempfile.TemporaryDirectory(prefix="resize-pipe-") as temporary:
            directory=Path(temporary)
            process=Native(self.executable(directory,"stale"),directory,{})
            try:
                with self.assertRaises(RuntimeError): process.request("verify",sequence=3)
            finally: process.close(False)
            self.assertIsNotNone(process.process.returncode)


if __name__ == "__main__": unittest.main()
