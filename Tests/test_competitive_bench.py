"""Small deterministic harness checks. No GUI, real credentials, or benchmarks."""
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

import competitive_bench as bench
from terminal_bench_worker import expected_reply, read_reply, write_all


class DrainProtocolTests(unittest.TestCase):
    def response(self, value, expected=b"\x1b[2;2R"):
        reader, writer = os.pipe()
        try:
            os.write(writer, value)
            return read_reply(reader, expected, time.monotonic() + 0.02)
        finally:
            os.close(reader)
            os.close(writer)

    def test_complete_literal_response_is_required(self):
        self.assertEqual(self.response(b"\x1b[2;2R"), b"\x1b[2;2R")
        for value in (b"R", b"\x1b[6n", b"[2;2R", b"\x1b[2;3R", b"\x1b[2;2Rjunk",
                      b"junk\x1b[2;2R", b"\x1b[2;2R\x1b[2;2R"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.response(value)

    def test_partial_response_times_out_instead_of_passing(self):
        with self.assertRaises(TimeoutError):
            self.response(b"\x1b[2;2")

    def test_fragmented_response_is_assembled_byte_accurately(self):
        reader, writer = os.pipe()
        def produce():
            for piece in (b"\x1b", b"[2;", b"2R"):
                os.write(writer, piece)
                time.sleep(0.005)
        thread = threading.Thread(target=produce)
        try:
            thread.start()
            self.assertEqual(read_reply(reader, b"\x1b[2;2R", time.monotonic() + 1), b"\x1b[2;2R")
        finally:
            thread.join()
            os.close(reader)
            os.close(writer)

    def test_sequence_changes_expected_cursor_without_leaving_grid(self):
        seen = set()
        for sequence in range(27):
            footer, reply = expected_reply(4, 10, sequence)
            self.assertTrue(footer.endswith(b"\x1b[6n"))
            self.assertNotIn(reply, seen)
            seen.add(reply)
        with self.assertRaises(ValueError):
            expected_reply(3, 10, 0)

    def test_write_backpressure_has_a_deadline(self):
        reader, writer = os.pipe()
        os.set_blocking(writer, False)
        try:
            with self.assertRaises(TimeoutError):
                write_all(writer, b"A" * 100_000, time.monotonic() + 0.02)
        finally:
            os.close(reader)
            os.close(writer)


class EvidenceAndIsolationTests(unittest.TestCase):
    def test_outer_controller_can_own_foreground_restoration_on_human_abort(self):
        metadata = {}
        with patch.object(bench, "window_command") as command:
            bench.restore_frontmost(metadata, Path("/helper"), 123, managed=True)
            command.assert_not_called()
        self.assertEqual(metadata, {"restoreFrontmostManagedExternally": True})
        self.assertFalse(bench.make_parser().parse_args([]).no_restore_frontmost)
        self.assertTrue(bench.make_parser().parse_args(["--no-restore-frontmost"]).no_restore_frontmost)

    def test_unmanaged_restoration_preserves_success_and_failure_evidence(self):
        metadata = {}
        with patch.object(bench, "window_command", return_value={"frontmostPID": 123}) as command:
            bench.restore_frontmost(metadata, Path("/helper"), 123, managed=False)
            command.assert_called_once_with(Path("/helper"), "activate", 123)
        self.assertEqual(metadata["restoreFrontmost"], {"frontmostPID": 123})
        with patch.object(bench, "window_command", side_effect=RuntimeError("owner exited")):
            bench.restore_frontmost(metadata, Path("/helper"), 123, managed=False)
        self.assertEqual(metadata["restoreFrontmostError"], "owner exited")

    def test_workload_has_exact_bytes_including_partial_last_line(self):
        pattern = b"A" * 76 + b"\r\n"
        for count in (1, 76, 77, 78, 79, 160):
            self.assertEqual(bench.payload_bytes("lines", count), (pattern * 3)[:count])
            self.assertEqual(bench.payload_bytes("continuous", count), b"A" * count)
        with self.assertRaises(ValueError):
            bench.payload_bytes("unknown", 10)

    def test_richer_workloads_never_truncate_utf8_or_control_sequences(self):
        for kind in ("styled", "unicode", "source"):
            pattern = bench.WORKLOAD_PATTERNS[kind]
            for count in range(1, len(pattern) * 2 + 1):
                with self.subTest(kind=kind, count=count):
                    payload = bench.payload_bytes(kind, count)
                    self.assertEqual(len(payload), count)
                    payload.decode("utf-8", errors="strict")
                    # Every ESC is a complete SGR; no dangling parser state
                    # can absorb the benchmark's independently validated DSR.
                    self.assertNotIn(b"\x1b", re.sub(rb"\x1b\[[0-9;]*m", b"", payload))
            self.assertEqual(bench.payload_bytes(kind, len(pattern)), pattern)

    def test_phase_trace_is_explicit_and_only_enters_cmdy_diagnostic_launches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for diagnostic in (False, True):
                for terminal in ("cmdy", "ghostty"):
                    options = bench.BenchOptions(Path("/cmdy"), Path("/ghostty"),
                                                 diagnostic_frame_trace=diagnostic)
                    with patch.dict(os.environ, {"CMDY_FRAME_TRACE": "1"}):
                        session = bench.TerminalSession(
                            options, Path("/helper"), terminal,
                            root / f"{terminal}-{diagnostic}", fixture_command=["/fixture"])
                    try:
                        self.assertEqual(session.environment.get("CMDY_FRAME_TRACE"),
                                         "1" if diagnostic and terminal == "cmdy" else None)
                    finally:
                        session.close()

    def test_balanced_order_and_requested_first_terminal(self):
        self.assertEqual(bench.block_order(0), ["cmdy", "ghostty"])
        self.assertEqual(bench.block_order(1), ["ghostty", "cmdy"])
        self.assertEqual(bench.block_order(0, "ghostty"), ["ghostty", "cmdy"])

    def test_grid_gate_uses_measured_rows_and_columns(self):
        bench.assert_grid({"columns": 100, "rows": 30}, (100, 30))
        with self.assertRaises(ValueError):
            bench.assert_grid({"columns": 99, "rows": 30}, (100, 30))

    def test_environment_does_not_inherit_credentials_or_shell_customization(self):
        source = {"HOME": "/real/home", "USER": "fixture", "ANTHROPIC_API_KEY": "fake-secret",
                  "OPENAI_API_KEY": "another-fake", "ZDOTDIR": "/user/rc", "DYLD_INSERT_LIBRARIES": "/user/lib",
                  "PATH": "/user/bin", "CMDY_CONFIG_DIR": "/user/config"}
        result = bench.launch_environment(source, Path("/isolated"), Path("/private/tmp/owned/work"), "com.cmdy.bench.fake")
        self.assertEqual(result["HOME"], "/real/home")
        self.assertEqual(result["CMDY_CONFIG_DIR"], "/isolated/cmdy-config")
        self.assertEqual(result["ZDOTDIR"], "/isolated/zsh")
        self.assertFalse({"ANTHROPIC_API_KEY", "OPENAI_API_KEY", "DYLD_INSERT_LIBRARIES"} & result.keys())
        self.assertNotIn("fake-secret", json.dumps(result))
        self.assertEqual(source["ZDOTDIR"], "/user/rc")

    def test_defaults_profile_is_distinct_and_keeps_network_help_disabled(self):
        options = bench.BenchOptions(Path("/cmdy"), Path("/ghostty"))
        matched = bench.terminal_config("cmdy", options, None, Path("/tmp/fixture"))
        options.profile = "cmdy-defaults"
        defaults = bench.terminal_config("cmdy", options, None, Path("/tmp/fixture"))
        self.assertIn("smooth-scroll = false", matched)
        self.assertNotIn("smooth-scroll", defaults)
        for config in (matched, defaults):
            self.assertIn("automatic-error-help = false", config)
            self.assertIn("marketplace-update-checks = false", config)
            self.assertIn("font-family = Menlo-Regular", config)
        ghostty = bench.terminal_config("ghostty", options, (100, 30), Path("/tmp/fixture"))
        self.assertIn("auto-update = off", ghostty)
        self.assertIn("window-width = 100", ghostty)
        self.assertIn("window-height = 30", ghostty)
        self.assertNotIn("adjust-cell", ghostty)

    def test_binary_evidence_reads_plist_without_running_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            contents = Path(temporary) / "Example.app/Contents"
            (contents / "MacOS").mkdir(parents=True)
            binary = contents / "MacOS/example"
            binary.write_bytes(b"not executable, must never run")
            (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "123", "CFBundleShortVersionString": "1.2.3"}))
            evidence = bench.binary_metadata(binary)
            self.assertEqual(evidence["version"], "1.2.3")
            self.assertEqual(evidence["build"], "123")
            self.assertEqual(evidence["sha256"], bench.sha256(binary))

    def test_summary_excludes_warmups_and_pairs_blocks(self):
        samples = []
        for block in range(2):
            for terminal, duration in (("cmdy", 4), ("ghostty", 2)):
                for warmup, multiplier in ((True, 100), (False, 1)):
                    samples.append(dict(block=block, terminal=terminal, warmup=warmup,
                                        elapsedNS=duration * multiplier * 1_000_000_000))
        report = bench.summary(samples, 2)
        self.assertEqual(report["medianPairedDrainRatio"], 2)
        self.assertEqual(report["terminals"]["cmdy"]["medianSeconds"], 4)

    def test_cpu_time_formats(self):
        self.assertEqual(bench.cpu_seconds("0:01.25"), 1.25)
        self.assertEqual(bench.cpu_seconds("1:02:03.50"), 3723.5)
        self.assertEqual(bench.cpu_seconds("2-01:00:00"), 176400)

    def test_process_ancestry_must_reach_owned_app(self):
        with patch.object(bench, "command_result", side_effect=[{"stdout": "100"}, {"stdout": "50"}]):
            self.assertTrue(bench.is_descendant(200, 50))
        with patch.object(bench, "command_result", return_value={"stdout": "1"}):
            self.assertFalse(bench.is_descendant(200, 50))
        with patch.object(bench, "command_result", return_value={"stdout": "200"}):
            self.assertFalse(bench.is_descendant(200, 50))

    def test_reused_fixture_pid_is_never_signalled(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "run"
            options = bench.BenchOptions(Path("/cmdy"), Path("/ghostty"))
            session = bench.TerminalSession(options, Path("/helper"), "ghostty", directory,
                                            fixture_command=["/fixture"])
            session.process = Mock(pid=12345, returncode=0)
            session.process.poll.return_value = None
            session.worker_identity = (12346, "original start")
            with patch.object(bench, "process_identity", return_value="different start"), patch("os.kill") as kill:
                session.close()
                kill.assert_not_called()
            session.process.terminate.assert_called_once_with()

    def test_cleanup_signals_only_the_retained_process_and_keeps_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "run"
            options = bench.BenchOptions(Path("/cmdy"), Path("/ghostty"))
            session = bench.TerminalSession(options, Path("/helper"), "ghostty", directory,
                                            fixture_command=["/fixture"], ready_path=directory / "fixture/ready.json")
            process = Mock(pid=12345, returncode=0)
            process.poll.return_value = None
            session.process = process
            with patch("os.kill") as signal_process:
                session.close()
            process.terminate.assert_called_once_with()
            process.kill.assert_not_called()
            signal_process.assert_not_called()
            self.assertTrue((directory / "ghostty.config").is_file())
            self.assertTrue((directory / "cleanup.json").is_file())
            self.assertFalse((directory / "fixture").exists())
            state = json.loads((directory / "cmdy-config/app-update-state.json").read_text())
            self.assertGreater(state["lastCheck"], time.time() - 5)
            self.assertNotIn("cachedRelease", state)


class WindowSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name) / "run"
        self.session = bench.TerminalSession(
            bench.BenchOptions(Path("/cmdy"), Path("/ghostty")), Path("/helper"),
            "ghostty", self.directory, fixture_command=["/fixture"])
        self.session.process = Mock(pid=12345, returncode=0)
        self.session.process.poll.return_value = None

    def tearDown(self):
        self.session.close()
        self.temporary.cleanup()

    def state(self, frontmost=12345, windows=1):
        window = {"windowID": 42, "displayID": 1, "bounds": {"width": 858, "height": 540, "x": 120, "y": 120}}
        return {"ok": True, "pid": 12345, "frontmostPID": frontmost, "windows": [window] * windows}

    def test_strict_window_check_persists_actual_failure_without_activation(self):
        failed = self.state(frontmost=999, windows=2)
        with patch.object(bench, "window_command", return_value=failed) as command:
            with self.assertRaises(bench.WindowStateError):
                self.session.window()
        command.assert_called_once_with(Path("/helper"), "inspect", 12345)
        record = json.loads((self.directory / "window-checks/0000.json").read_text())
        self.assertEqual(record["response"], failed)
        self.assertEqual(record["status"], "invalid")
        self.assertFalse(record["requestedActivation"])

    def test_helper_activation_failure_retains_followup_inspection_and_error(self):
        failure = bench.WindowHelperError("activation rejected", {"returncode": 2, "stderr": "detail"})
        failed = self.state(frontmost=999)
        with patch.object(bench, "window_command", side_effect=[failure, failed]):
            with self.assertRaises(bench.WindowStateError):
                self.session.window(activate=True)
        record = json.loads((self.directory / "window-checks/0000.json").read_text())
        self.assertEqual(record["response"], failed)
        self.assertEqual(record["helperFailure"]["stderr"], "detail")

    def test_explicit_activation_waits_for_window_publication_and_retains_each_poll(self):
        responses = [self.state(windows=0), self.state(windows=0), self.state()]
        with patch.object(bench, "window_command", side_effect=responses) as command, \
                patch.object(bench.time, "sleep"):
            self.assertEqual(self.session.window(activate=True), self.state())
        self.assertEqual([call.args[1] for call in command.call_args_list], ["activate", "inspect", "inspect"])
        first = json.loads((self.directory / "window-checks/0000.json").read_text())
        last = json.loads((self.directory / "window-checks/0002.json").read_text())
        self.assertEqual(first["response"]["windows"], [])
        self.assertEqual(first["status"], "invalid")
        self.assertEqual(last["status"], "valid")
        self.assertTrue(last["setupWindowWait"])

    def test_window_publication_wait_has_a_two_second_deadline(self):
        with patch.object(bench, "window_command", return_value=self.state(windows=0)) as command, \
                patch.object(bench.time, "monotonic", side_effect=[0, 0.1, 2.1]), \
                patch.object(bench.time, "sleep"):
            with self.assertRaises(bench.WindowStateError):
                self.session.window(activate=True)
        self.assertEqual([call.args[1] for call in command.call_args_list], ["activate", "inspect"])

    def test_exited_process_failure_is_retained_without_borrowing_another_window(self):
        self.session.process.poll.return_value = 7
        with patch.object(bench, "window_command") as command:
            with self.assertRaises(bench.WindowStateError):
                self.session.window()
        command.assert_not_called()
        record = json.loads((self.directory / "window-checks/0000.json").read_text())
        self.assertEqual(record["processReturncode"], 7)
        self.assertIsNone(record["response"])

    def test_fit_grid_retains_transient_failure_then_activates_only_in_setup(self):
        initial = {"columns": 98, "rows": 29}
        target = {"columns": 120, "rows": 36}
        failed = self.state(frontmost=999)
        responses = [self.state(), {"ok": True}, failed, self.state()]
        with patch.object(self.session, "grid", side_effect=[initial, target]), \
                patch.object(bench, "window_command", side_effect=responses) as command, \
                patch.object(bench.time, "sleep"):
            self.assertEqual(self.session.fit_grid((120, 36), allow_resize=True), target)
        self.assertEqual([call.args[1] for call in command.call_args_list], ["inspect", "resize", "inspect", "activate"])
        evidence = json.loads((self.directory / "geometry.json").read_text())
        self.assertEqual(evidence["attempts"][1]["windowFailures"][0]["response"], failed)
        self.assertEqual(evidence["attempts"][1]["status"], "matched")
        self.assertEqual(evidence["setupActivationAttemptsRemaining"], 2)

    def test_setup_activation_has_a_fixed_total_budget(self):
        failed = self.state(frontmost=999)
        with patch.object(self.session, "grid", return_value={"columns": 120, "rows": 36}), \
                patch.object(bench, "window_command", return_value=failed) as command, \
                patch.object(bench.time, "sleep"):
            with self.assertRaises(bench.WindowStateError):
                self.session.fit_grid((120, 36), allow_resize=True)
        self.assertEqual([call.args[1] for call in command.call_args_list], ["inspect", "activate", "activate", "activate"])
        evidence = json.loads((self.directory / "geometry.json").read_text())
        self.assertEqual(evidence["setupActivationAttemptsRemaining"], 0)
        self.assertEqual(evidence["attempts"][0]["status"], "failed")
        self.assertEqual(len(evidence["attempts"][0]["windowFailures"]), 4)


class FrozenFixtureTests(unittest.TestCase):
    def test_drain_uses_selected_frozen_tooling_instead_of_live_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            tooling = base / "frozen"
            tooling.mkdir()
            worker = tooling / "terminal_bench_worker.py"
            worker.write_text("# frozen fixture\n")
            options = bench.BenchOptions(Path("/cmdy"), Path("/ghostty"), payload=base / "payload.bin", tooling_dir=tooling)
            with patch.object(bench, "ROOT", base / "missing-checkout"):
                with bench.TerminalSession(options, Path("/helper"), "ghostty", base / "run") as session:
                    self.assertEqual(session.fixture_command[1], str(worker.resolve()))
                    self.assertEqual(session.fixture_source["sha256"], bench.sha256(worker))
                    self.assertIn(str(worker.resolve()), (session.directory / "zsh/.zshenv").read_text())

    def test_reusable_drain_session_snapshots_worker_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            checkout = base / "checkout"
            (checkout / "Tests").mkdir(parents=True)
            live_worker = checkout / "Tests/terminal_bench_worker.py"
            live_worker.write_text("# original\n")
            options = bench.BenchOptions(Path("/cmdy"), Path("/ghostty"), payload=base / "payload.bin")
            with patch.object(bench, "ROOT", checkout):
                with bench.TerminalSession(options, Path("/helper"), "ghostty", base / "run") as session:
                    live_worker.write_text("# changed after setup\n")
                    retained = Path(session.fixture_command[1])
                    self.assertNotEqual(retained, live_worker)
                    self.assertEqual(retained.read_text(), "# original\n")


if __name__ == "__main__":
    unittest.main()
