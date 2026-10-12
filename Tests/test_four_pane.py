#!/usr/bin/env python3
"""Fixture correctness only: real private PTYs and pure receipt validation."""
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

from four_pane_evidence import (GRID, QUANTUM, PERIOD_NS, interval_bounds,
                                validate_busy, validate_marker, validate_rectangles, validate_stream)
from four_pane_worker import LINE, payload

HERE = Path(__file__).resolve().parent
TOKEN = "ab" * 16


def ideal_record(count=800):
    start = 1_000_000_000
    offers = [[i, start + i * PERIOD_NS, start + i * PERIOD_NS, i * QUANTUM, QUANTUM] for i in range(count)]
    writes = [[i, i * QUANTUM, QUANTUM, offer[2] + 1_000, offer[2] + 20_000] for i, offer in enumerate(offers)]
    return {"requestedBytesPerSecond": 4_000_000, "quantumBytes": QUANTUM, "periodNs": PERIOD_NS,
            "payloadPeriodHex": LINE.hex(), "payloadPeriodSHA256": hashlib.sha256(LINE).hexdigest(),
            "activeStartNs": start, "offers": offers, "writes": writes,
            "completedBytes": count * QUANTUM, "offeredBytes": count * QUANTUM, "pendingBytes": 0,
            "status": "stopped", "stopReason": "control-stop", "stoppedMonotonicNs": start + count * PERIOD_NS + 10_000_000,
            "activeGrid": GRID.copy(), "finalGrid": GRID.copy(), "geometryChanges": [], "received": [],
            "cleanup": {"termiosRestored": True, "stdoutRestored": True}}


class AccountingTests(unittest.TestCase):
    def setUp(self):
        self.observation = {"startedMonotonicNs": 2_005_000_000, "finishedMonotonicNs": 7_005_000_000}

    def test_valid_schedule_and_complete_interval(self):
        result = validate_busy(ideal_record(), self.observation)
        self.assertEqual(result["wholeInterval"]["lowerBytesPerSecond"], 4_000_000)
        self.assertEqual(len(result["oneSecondBuckets"]), 5)

    def test_boundary_uncertainty_only_counts_intersecting_writes(self):
        result = interval_bounds([[0, 0, 10, 9, 11], [1, 10, 20, 12, 14],
                                  [2, 30, 30, 19, 22], [3, 60, 40, 23, 24]], 10, 20)
        self.assertEqual((result["lowerBytes"], result["upperBytes"]), (20, 60))

    def test_positive_but_insufficient_load_is_rejected(self):
        record = ideal_record()
        # A valid contiguous stream with low actual service cannot be rescued
        # by startup bytes or by nominal offered throughput.
        for i, offer in enumerate(record["offers"]):
            offer[2] = record["activeStartNs"] + i * 20_000_000
            record["writes"][i][3:] = [offer[2] + 1000, offer[2] + 20_000]
        record["stoppedMonotonicNs"] = 18_000_000_000
        with self.assertRaisesRegex(ValueError, "throughput"):
            validate_busy(record, self.observation)

    def test_rejects_gaps_duplicates_unoffered_and_catchup(self):
        changes = [lambda r: r["writes"][5].__setitem__(1, 0),
                   lambda r: r["offers"][5].__setitem__(0, 9),
                   lambda r: r["offers"][5].__setitem__(2, r["offers"][4][2] + 1),
                   lambda r: r["writes"][5].__setitem__(0, 799),
                   lambda r: r.__setitem__("completedBytes", 1)]
        for change in changes:
            record = ideal_record()
            change(record)
            with self.assertRaises(ValueError):
                validate_stream(record)

    def test_one_second_stall_fails_even_with_acceptable_total_rate(self):
        record = ideal_record()
        for i in range(200, len(record["offers"])):
            record["offers"][i][2] += 120_000_000
            record["writes"][i][3] += 120_000_000
            record["writes"][i][4] += 120_000_000
        record["stoppedMonotonicNs"] += 120_000_000
        observation = {"startedMonotonicNs": 2_005_000_000, "finishedMonotonicNs": 8_505_000_000}
        validate_stream(record)
        total = interval_bounds(record["writes"], observation["startedMonotonicNs"], observation["finishedMonotonicNs"])
        self.assertGreaterEqual(total["lowerBytesPerSecond"], 4_000_000 * .98)
        with self.assertRaisesRegex(ValueError, "one-second"):
            validate_busy(record, observation)

    def test_geometry_lifetime_and_wrong_pane_input_fail_closed(self):
        changes = [lambda r: r["finalGrid"].__setitem__("rows", 17),
                   lambda r: r["geometryChanges"].append({"monotonicNs": 3_000_000_000, "grid": GRID}),
                   lambda r: r["received"].append({"byte": 97}),
                   lambda r: r.__setitem__("stoppedMonotonicNs", 6_000_000_000)]
        for change in changes:
            record = ideal_record()
            change(record)
            with self.assertRaises(ValueError):
                validate_busy(record, self.observation)

    def test_marker_must_match_exact_expected_count_and_order(self):
        record = ideal_record()
        record["received"] = [{"sequence": i, "byte": 97, "receivedMonotonicNs": 3_000_000_000 + i,
                                "repliedMonotonicNs": 3_000_000_100 + i, "replied": True} for i in range(1, 6)]
        latency = {"samples": [{"sequence": i} for i in range(1, 6)]}
        validate_marker(record, latency, self.observation, 5)
        with self.assertRaises(ValueError):
            validate_marker(record, latency, self.observation, 40)
        record["received"][2]["sequence"] = 1
        with self.assertRaises(ValueError):
            validate_marker(record, latency, self.observation, 5)

    def test_rectangles_require_correct_2x2_slot_mapping(self):
        rects = [{"slot": i, "x": .02 + (i % 2) * .5, "y": .07 + (i // 2) * .46,
                  "width": .45, "height": .42, "fillFraction": .999} for i in range(4)]
        roi = validate_rectangles(rects)
        self.assertLess(roi["x"] + roi["width"], .5)
        rects[0]["slot"], rects[1]["slot"] = 1, 0
        with self.assertRaises(ValueError):
            validate_rectangles(rects)

    def test_rectangle_extents_and_fill_must_fit_the_capture(self):
        for mutation in (
            lambda rs: [r.__setitem__("x", r["x"] - .1) for r in rs],
            lambda rs: [r.__setitem__("y", r["y"] + .1) for r in rs],
            lambda rs: rs[0].__setitem__("fillFraction", float("inf")),
            lambda rs: rs[0].__setitem__("slot", False),
        ):
            rects = [{"slot": i, "x": .02 + (i % 2) * .5, "y": .07 + (i // 2) * .46,
                      "width": .45, "height": .42, "fillFraction": .999} for i in range(4)]
            mutation(rects)
            with self.assertRaises(ValueError):
                validate_rectangles(rects)


class PTYTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmdy-4p-test-", dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.sockets = self.root / "sock"
        self.sockets.mkdir(mode=0o700)
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child["process"].poll() is None:
                child["process"].terminate()
            try:
                child["process"].wait(timeout=3)
            except subprocess.TimeoutExpired:
                child["process"].kill()
                child["process"].wait(timeout=3)
            if child["master"] is not None:
                os.close(child["master"])
            child["process"].stderr.close()
        self.temporary.cleanup()

    def launch(self, timeout=5, token=TOKEN, expect_slot=None):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 18, 60, 0, 0))
        process = subprocess.Popen([sys.executable, str(HERE / "four_pane_worker.py"),
            "--output", str(self.root / "fixture"), "--socket-directory", str(self.sockets),
            "--run-token", token, "--timeout", str(timeout)], stdin=slave, stdout=slave,
            stderr=subprocess.PIPE, start_new_session=True)
        os.close(slave)
        os.set_blocking(master, False)
        child = {"master": master, "process": process, "bytes": bytearray()}
        self.children.append(child)
        if expect_slot is not None:
            path = self.root / f"fixture/worker-{expect_slot}.json"
            deadline = time.monotonic() + 2
            while not path.exists() and time.monotonic() < deadline and process.poll() is None:
                self.drain(.01)
            self.assertTrue(path.exists(), process.stderr.read().decode() if process.poll() is not None else "readiness timeout")
            child["ready"] = json.loads(path.read_text())
        return child

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            descriptors = [child["master"] for child in self.children if child["master"] is not None]
            if not descriptors:
                return
            readable, _, _ = select.select(descriptors, [], [], min(.01, max(0, deadline - time.monotonic())))
            for descriptor in readable:
                child = next(child for child in self.children if child["master"] == descriptor)
                try:
                    child["bytes"].extend(os.read(descriptor, 65536))
                except (BlockingIOError, OSError):
                    pass

    def request(self, child, operation, token=TOKEN, **values):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(1)
            connection.connect(child["ready"]["socketPath"])
            connection.sendall(json.dumps({"runToken": token, "op": operation, **values}).encode() + b"\n")
            data = b""
            while not data.endswith(b"\n"):
                data += connection.recv(65536)
        return json.loads(data)

    def wait_for(self, child, predicate, seconds=3):
        # Hosted CI runners can be tens of milliseconds late, so wait for the
        # worker's own state rather than a fixed delay.
        deadline = time.monotonic() + seconds
        while True:
            status = self.request(child, "status")
            if predicate(status):
                return status
            self.assertLess(time.monotonic(), deadline, status)
            self.drain(.01)

    def finish(self, child):
        self.request(child, "stop")
        self.drain(.05)
        child["process"].wait(timeout=2)
        return json.loads((self.root / f"fixture/final-{child['ready']['slot']}.json").read_text())

    def test_four_roles_are_unique_and_fifth_is_rejected(self):
        children = [self.launch(expect_slot=i) for i in range(4)]
        self.assertEqual([child["ready"]["role"] for child in children], ["marker", "busy", "busy", "busy"])
        self.assertEqual(len({child["ready"]["ttyPath"] for child in children}), 4)
        extra = self.launch()
        self.assertNotEqual(extra["process"].wait(timeout=2), 0)
        self.assertIn("already claimed", extra["process"].stderr.read().decode())

    def test_token_and_unknown_control_do_not_mutate_fixture(self):
        child = self.launch(expect_slot=0)
        self.assertFalse(self.request(child, "status", token="cd" * 16)["ok"])
        self.assertFalse(self.request(child, "shell", command="echo should-never-run")["ok"])
        self.assertEqual(self.request(child, "status")["mode"], "setup")
        wrong = self.launch(token="cd" * 16)
        self.assertNotEqual(wrong["process"].wait(timeout=2), 0)

    def test_setup_input_is_separate_from_ordered_marker_receipts(self):
        child = self.launch(expect_slot=0)
        os.write(child["master"], b"zz")
        self.drain(.03)
        self.assertEqual(self.request(child, "status")["setupKeys"], [122, 122])
        self.assertTrue(self.request(child, "arm", startNs=time.monotonic_ns() + 50_000_000)["ok"])
        self.wait_for(child, lambda status: status["mode"] == "active")
        for _ in range(3):
            os.write(child["master"], b"a")
            self.drain(.015)
        final = self.finish(child)
        self.assertEqual([entry["sequence"] for entry in final["received"]], [1, 2, 3])
        self.assertTrue(all(entry["replied"] for entry in final["received"]))
        self.assertEqual(final["setupKeys"], [122, 122])
        self.assertTrue(final["cleanup"]["termiosRestored"])

    def test_busy_payload_partial_writes_and_receipts_reconcile(self):
        self.launch(expect_slot=0)
        child = self.launch(expect_slot=1)
        self.assertTrue(self.request(child, "arm", startNs=time.monotonic_ns() + 50_000_000)["ok"])
        self.wait_for(child, lambda status: status["completedBytes"] >= QUANTUM)
        self.assertFalse((self.root / "fixture/final-1.json").exists())
        final = self.finish(child)
        validate_stream(final)
        self.assertGreaterEqual(final["completedBytes"], QUANTUM)
        start = bytes(child["bytes"]).find(LINE[:20])
        self.assertGreaterEqual(start, 0)
        self.assertEqual(bytes(child["bytes"])[start:start + final["completedBytes"]], payload(0, final["completedBytes"]))
        self.assertEqual(final["activeGrid"], GRID)

    def test_timeout_retains_cleanup_before_process_exit(self):
        child = self.launch(timeout=1, expect_slot=0)
        self.drain(1.05)
        self.assertEqual(child["process"].wait(timeout=2), 0)
        final = json.loads((self.root / "fixture/final-0.json").read_text())
        self.assertEqual(final["stopReason"], "timeout")
        self.assertTrue(final["cleanup"]["termiosRestored"])

    def test_all_four_restored_ptys_remain_alive_until_final_records_are_released(self):
        children = [self.launch(timeout=10, expect_slot=i) for i in range(4)]
        fixture = self.root / "fixture"
        for child in children:
            self.assertTrue(self.request(child, "stop", holdExit=True)["ok"])
            path = fixture / f"final-{child['ready']['slot']}.json"
            until = time.monotonic() + 1
            while not path.exists() and time.monotonic() < until:
                self.drain(.01)
            self.assertTrue(path.exists())
            # Even the first finalized pane must keep its PTY open while the
            # controller gathers the other panes' records.
            self.assertTrue(all(c["process"].poll() is None for c in children))
            final = json.loads(path.read_text())
            self.assertEqual(final["finalGrid"], GRID)
            self.assertTrue(final["cleanup"]["termiosRestored"])
            self.assertTrue(final["pacingTimerClosed"])
        release = {"runToken": TOKEN, "releaseMonotonicNs": time.monotonic_ns(),
                   "workerPIDs": {str(i): c["process"].pid for i, c in enumerate(children)},
                   "finalSHA256": {str(i): hashlib.sha256((fixture / f"final-{i}.json").read_bytes()).hexdigest()
                                   for i in range(4)}}
        temporary = fixture / "release.tmp"
        temporary.write_text(json.dumps(release))
        temporary.replace(fixture / "exit-release.json")
        for i, child in enumerate(children):
            self.assertEqual(child["process"].wait(timeout=2), 0)
            exited = json.loads((fixture / f"exit-{i}.json").read_text())
            self.assertEqual(exited["status"], "released")
            self.assertGreaterEqual(exited["exitingMonotonicNs"], release["releaseMonotonicNs"])

    def test_wrong_release_is_rejected_and_does_not_hang_restored_worker(self):
        child = self.launch(expect_slot=0)
        self.request(child, "stop", holdExit=True)
        fixture = self.root / "fixture"
        until = time.monotonic() + 1
        while not (fixture / "final-0.json").exists() and time.monotonic() < until:
            self.drain(.01)
        temporary = fixture / "release.tmp"
        temporary.write_text(json.dumps({"runToken": "cd" * 16}))
        temporary.replace(fixture / "exit-release.json")
        self.assertEqual(child["process"].wait(timeout=2), 0)
        self.assertEqual(json.loads((fixture / "exit-0.json").read_text())["status"], "invalid-release")

    def test_sighup_or_disconnected_pty_retains_evidence(self):
        child = self.launch(expect_slot=0)
        os.close(child["master"])
        child["master"] = None
        child["process"].send_signal(signal.SIGHUP)
        self.assertEqual(child["process"].wait(timeout=2), 0)
        final = json.loads((self.root / "fixture/final-0.json").read_text())
        self.assertIn(final["stopReason"], ("signal-SIGHUP", "pty-disconnected", "pty-eof"))
        self.assertEqual(final["status"], "stopped")


if __name__ == "__main__":
    unittest.main(verbosity=2)
