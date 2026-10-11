#!/usr/bin/env python3
"""Matched same-machine terminal drain evidence. Does not measure display latency."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

from terminal_bench_worker import atomic_json, grid as tty_grid

ROOT = Path(__file__).resolve().parent.parent
METRIC = "raw-PTY-write-to-validated-DSR-response"
WORKLOAD_PATTERNS = {
    "continuous": b"A",
    "lines": b"A" * 76 + b"\r\n",
    "styled": (b"\x1b[1;32mPASS\x1b[0m parser/streaming.test.swift "
               b"\x1b[38;2;150;170;200m(42 assertions, 0 failures)\x1b[0m\r\n"
               b"\x1b[33mWARN\x1b[0m source.swift:128:9: unused local value\r\n"),
    "unicode": ("ASCII 0123456789 | cafe\u0301 | 中文 日本語 한국어 | "
                "Ελληνικά | العربية | 👩🏽‍💻 🏳️‍🌈 | ┌─┬─┐ █▄▀\r\n").encode("utf-8"),
    "source": (b"\x1b[38;2;190;120;220mfunc\x1b[0m consume(bytes: [UInt8]) {\r\n"
               b"    \x1b[36mfor\x1b[0m byte in bytes { parser.feed(byte) }\r\n"
               b"    // Publish a coherent snapshot after processing.\r\n"
               b"    observer?.didUpdate(snapshot)\r\n}\r\n"),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_result(arguments: list[str], cwd: Path | None = None) -> dict:
    try:
        result = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, timeout=15)
        return {"command": arguments, "returncode": result.returncode,
                "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"command": arguments, "error": str(error)}


def power_snapshot() -> dict:
    battery = command_result(["/usr/bin/pmset", "-g", "batt"])
    settings = command_result(["/usr/bin/pmset", "-g", "custom"])
    match = re.search(r"Now drawing from '([^']+)'", battery.get("stdout", ""))
    return {"timeUTC": datetime.now(timezone.utc).isoformat(), "battery": battery,
            "settings": settings, "thermal": command_result(["/usr/bin/pmset", "-g", "therm"]),
            "signature": {"source": match[1] if match else None,
                          "settings": settings.get("stdout")},
            "loadAverage": list(os.getloadavg())}


def binary_metadata(path: Path) -> dict:
    path = path.resolve()
    info_path = path.parent.parent / "Info.plist"
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    return {"path": str(path), "sha256": sha256(path), "bytes": path.stat().st_size,
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "bundleID": info.get("CFBundleIdentifier"),
            "infoPlist": str(info_path) if info else None,
            "infoPlistSHA256": sha256(info_path) if info else None}


def payload_bytes(kind: str, count: int) -> bytes:
    if count < 1:
        raise ValueError("payload must contain at least one byte")
    if kind not in WORKLOAD_PATTERNS:
        raise ValueError("unknown workload")
    pattern = WORKLOAD_PATTERNS[kind]
    remainder = count % len(pattern)
    # Keep the original ASCII corpora byte-for-byte stable. New corpora end
    # on a complete UTF-8/control-sequence boundary, then pad with plain ASCII.
    # A truncated SGR could consume the DSR footer and change the measured work.
    tail = pattern[:remainder] if kind in ("continuous", "lines") else b"A" * remainder
    return pattern * (count // len(pattern)) + tail


def block_order(block: int, first: str = "cmdy") -> list[str]:
    if first not in ("cmdy", "ghostty") or block < 0:
        raise ValueError("invalid block order")
    order = [first, "ghostty" if first == "cmdy" else "cmdy"]
    return order if block % 2 == 0 else order[::-1]


def assert_grid(actual: dict, expected: tuple[int, int]) -> None:
    if (actual["columns"], actual["rows"]) != expected:
        raise ValueError(f"actual grid {actual} differs from required {expected[0]}x{expected[1]}")


@dataclass
class BenchOptions:
    cmdy_bin: Path
    ghostty_bin: Path
    payload: Path | None = None
    profile: str = "matched"
    font_size: float = 14
    timeout: float = 60
    settle_seconds: float = 15
    tooling_dir: Path | None = None
    diagnostic_frame_trace: bool = False
    diagnostic_marker_row: int | None = None


def terminal_config(terminal: str, options: BenchOptions,
                    target_grid: tuple[int, int] | None, cwd: Path) -> str:
    if terminal == "cmdy":
        # Both profiles retain these safety/isolation and comparability settings.
        settings = ["restore-session = false", "marketplace-update-checks = false",
                    "automatic-error-help = false", "font-family = Menlo-Regular",
                    f"font-size = {options.font_size:g}"]
        if options.profile == "matched":
            settings += ["shell-integration = false", "clean-prompt = false",
                         "sounds = false", "ghost-text = false", "shader = None",
                         "smooth-cursor = false", "smooth-scroll = false",
                         "cursor-style = block", "cursor-blink = false",
                         "line-height = 1", "opacity = 1", "window-grid = false",
                         "workspace-navigator = false", "workspace-inspector = false"]
    elif terminal == "ghostty":
        settings = ["font-family = Menlo", "font-style = Regular",
                    f"font-size = {options.font_size:g}", "shell-integration = none",
                    "background-opacity = 1", "cursor-style = block", "cursor-style-blink = false",
                    "window-save-state = never", "window-inherit-font-size = false",
                    "window-inherit-working-directory = false", "window-padding-x = 10",
                    "window-padding-y = 10", "confirm-close-surface = false",
                    "quit-after-last-window-closed = true", "auto-update = off",
                    f"working-directory = {cwd}", "command = direct:/bin/zsh -l"]
        if target_grid:
            settings += [f"window-width = {target_grid[0]}", f"window-height = {target_grid[1]}"]
    else:
        raise ValueError("unknown terminal")
    return "\n".join(settings) + "\n"


def launch_environment(base: dict[str, str], directory: Path, cwd: Path,
                       defaults_domain: str) -> dict[str, str]:
    # Deliberate allowlist: never carry cloud keys, project env, user ZDOTDIR,
    # DYLD overrides, or shell customization into either terminal.
    environment = {key: base[key] for key in ("HOME", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING")
                   if key in base}
    environment.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
                        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                        "TMPDIR": str(cwd.parent) + "/", "ZDOTDIR": str(directory / "zsh"),
                        "XDG_CONFIG_HOME": str(directory / "xdg-config"),
                        "XDG_DATA_HOME": str(directory / "xdg-data"),
                        "XDG_CACHE_HOME": str(directory / "xdg-cache"),
                        "XDG_STATE_HOME": str(directory / "xdg-state"),
                        "CMDY_CONFIG_DIR": str(directory / "cmdy-config"),
                        "CMDY_DEFAULTS_DOMAIN": defaults_domain})
    return environment


class WindowHelperError(RuntimeError):
    def __init__(self, message: str, evidence: dict):
        super().__init__(message)
        self.evidence = evidence


class WindowStateError(RuntimeError):
    def __init__(self, message: str, evidence: dict):
        super().__init__(message)
        self.evidence = evidence


def window_command(helper: Path, command: str, *arguments: object) -> dict:
    argv = [str(helper), command, *map(str, arguments)]
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise WindowHelperError(str(error), {"command": argv, "error": str(error)}) from error
    evidence = {"command": argv, "returncode": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr}
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise WindowHelperError(f"window helper failed: {result.stderr or result.stdout}", evidence) from error
    evidence["response"] = value
    if result.returncode or not value.get("ok"):
        raise WindowHelperError(value.get("error", "window helper failed"), evidence)
    return value


def create_helper(output: Path, existing: Path | None = None) -> Path:
    if existing:
        if not os.access(existing, os.X_OK):
            raise ValueError(f"window helper is not executable: {existing}")
        return existing.resolve()
    directory = output / "bin"
    directory.mkdir()
    helper = directory / "terminal-bench-window"
    source = output / "tooling/TerminalBenchWindow.swift"
    if not source.is_file():
        source = ROOT / "Tests/TerminalBenchWindow.swift"
    arguments = ["/usr/bin/xcrun", "swiftc", str(source),
                 "-o", str(helper)]
    result = subprocess.run(arguments, capture_output=True, text=True)
    atomic_json(directory / "build.json", {"command": arguments, "returncode": result.returncode,
                                          "stdout": result.stdout, "stderr": result.stderr})
    if result.returncode:
        raise RuntimeError(f"standalone helper compilation failed; see {directory / 'build.json'}")
    return helper


class TerminalSession:
    """Reusable owned launch/isolation for a drain or independent visual fixture.

    Custom fixtures write ready_path with {pid, ttyPath, rows, columns}; their
    output directory is not created here. This class never injects input into
    a custom fixture, and never discovers/borrows a caller's existing process.
    """
    def __init__(self, options: BenchOptions, helper: Path, terminal: str, run_dir: Path,
                 target_grid: tuple[int, int] | None = None,
                 fixture_command: list[str] | None = None, ready_path: Path | None = None,
                 *, child_umask: int | None = None):
        if child_umask is not None and (type(child_umask) is not int or child_umask != 0o077):
            raise ValueError("child umask must be explicitly 0077 or omitted")
        self.child_umask = child_umask
        self.options, self.helper, self.terminal = options, helper, terminal
        self.directory, self.target_grid = run_dir.resolve(), target_grid
        self.directory.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.temporary = tempfile.TemporaryDirectory(prefix="cmdy-drain-", dir="/private/tmp")
        self.cwd = Path(self.temporary.name) / "work"
        self.cwd.mkdir()
        self.socket_path = str(Path(self.temporary.name) / "control.sock")
        self.domain = "com.cmdy.bench." + uuid.uuid4().hex
        self.process: subprocess.Popen | None = None
        self.log = None
        self.ready: dict = {}
        self.window_check_count = 0
        self.last_window_check: dict | None = None
        self.worker_identity: tuple[int, str] | None = None
        self.is_drain = fixture_command is None
        self.ready_path = ready_path or self.directory / "ready.json"
        self.environment = launch_environment(dict(os.environ), self.directory, self.cwd, self.domain)
        if options.diagnostic_frame_trace and terminal == "cmdy":
            self.environment["CMDY_FRAME_TRACE"] = "1"
            if options.diagnostic_marker_row is not None:
                self.environment["CMDY_TRACE_MARKER_ROW"] = str(options.diagnostic_marker_row)
        for name in ("cmdy-config", "zsh", "xdg-config", "xdg-data", "xdg-cache", "xdg-state", "window-checks"):
            (self.directory / name).mkdir()
        (self.directory / "cmdy-config/extensions").mkdir()
        config = terminal_config(terminal, options, target_grid, self.cwd)
        self.config_path = self.directory / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
        self.config_path.write_text(config)
        # Packaged CMDY checks for app updates at startup independently of the
        # Marketplace preference. Seed only our isolated cooldown, with no cache.
        atomic_json(self.directory / "cmdy-config/app-update-state.json", {"lastCheck": time.time()})
        self.fixture_source: dict | None = None
        if fixture_command is None:
            if options.payload is None:
                raise ValueError("drain fixture needs a payload")
            if options.tooling_dir is not None:
                worker = options.tooling_dir.resolve() / "terminal_bench_worker.py"
                if not worker.is_file():
                    raise ValueError(f"frozen drain fixture is missing: {worker}")
            else:
                # Reusable sessions outside main() still execute a retained
                # snapshot, never a live source path that can change mid-run.
                (self.directory / "tooling").mkdir()
                worker = self.directory / "tooling/terminal_bench_worker.py"
                shutil.copy2(ROOT / "Tests/terminal_bench_worker.py", worker)
            self.fixture_source = {"path": str(worker), "sha256": sha256(worker)}
            fixture_command = [sys.executable, str(worker),
                               "--directory", str(self.directory), "--payload", str(options.payload),
                               "--socket", self.socket_path]
        self.fixture_command = list(map(str, fixture_command))
        # Both launch /bin/zsh -l, which reads only this controlled .zshenv and
        # execs the same fixture before any user rc, shell history or hooks.
        (self.directory / "zsh/.zshenv").write_text(
            "unsetopt RCS\nexec " + shlex.join(self.fixture_command) + "\n")

    @property
    def app_pid(self) -> int:
        if self.process is None:
            raise RuntimeError("session has not launched")
        return self.process.pid

    def launch(self) -> dict:
        binary = self.options.cmdy_bin if self.terminal == "cmdy" else self.options.ghostty_bin
        arguments = [str(binary)]
        if self.terminal == "ghostty":
            # This CLI-only switch prevents user config from being merged in.
            arguments += ["--config-default-files=false", f"--config-file={self.config_path}"]
        self.log = (self.directory / "app.log").open("wb")
        child_options = {} if self.child_umask is None else {"umask": self.child_umask}
        started = time.perf_counter_ns()
        self.process = subprocess.Popen(arguments, cwd=self.cwd, env=self.environment,
                                        stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log, **child_options)
        launch = {"appPID": self.app_pid, "terminal": self.terminal, "arguments": arguments,
                  "startedMonotonicNS": started, "cwd": str(self.cwd),
                  "defaultsDomain": self.domain, "fixtureCommand": self.fixture_command,
                  "drainFixtureSource": self.fixture_source,
                  "config": str(self.config_path), "configSHA256": sha256(self.config_path),
                  "environment": self.environment, "profile": self.options.profile,
                  "readyPath": str(self.ready_path)}
        if self.child_umask is not None: launch["childUmask"] = self.child_umask
        atomic_json(self.directory / "launch.json", launch)
        deadline = time.monotonic() + self.options.timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"owned {self.terminal} exited before fixture readiness; see {self.directory / 'app.log'}")
            if self.ready_path.exists():
                try:
                    self.ready = json.loads(self.ready_path.read_text())
                    break
                except json.JSONDecodeError:
                    pass  # independent fixtures may not use an atomic rename
            time.sleep(0.05)
        else:
            raise TimeoutError(f"{self.terminal} fixture did not become ready")
        observed = time.perf_counter_ns()
        ready_time = self.ready.get("readyMonotonicNS", self.ready.get("startedMonotonicNs", observed))
        launch["fixtureReadyMonotonicNS"] = ready_time
        launch["fixtureReadyObservedMonotonicNS"] = observed
        launch["processLaunchToFixtureReadyNS"] = ready_time - started
        launch["workerPID"] = self.ready.get("workerPID", self.ready.get("pid"))
        worker_pid = launch["workerPID"]
        if isinstance(worker_pid, int) and is_descendant(worker_pid, self.app_pid):
            identity = process_identity(worker_pid)
            if identity:
                self.worker_identity = worker_pid, identity
        atomic_json(self.directory / "launch.json", launch)
        return self.ready

    def request(self, command: str, **values: object) -> dict:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(self.options.timeout + 5)
            connection.connect(self.socket_path)
            connection.sendall(json.dumps({"command": command, **values}).encode() + b"\n")
            data = bytearray()
            while not data.endswith(b"\n"):
                chunk = connection.recv(16384)
                if not chunk or len(data) + len(chunk) > 1024 * 1024:
                    raise RuntimeError("invalid fixture response")
                data.extend(chunk)
        result = json.loads(data)
        if not result.get("ok"):
            raise RuntimeError(result.get("error", "fixture command failed"))
        return result

    def grid(self) -> dict:
        if self.is_drain:
            return self.request("grid")["grid"]
        tty_path = self.ready.get("ttyPath", "")
        if not re.fullmatch(r"/dev/ttys[0-9]+", tty_path):
            raise RuntimeError("custom fixture must report its /dev/ttysNNN ttyPath")
        fd = os.open(tty_path, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            return tty_grid(fd)
        finally:
            os.close(fd)

    def window(self, activate: bool = False) -> dict:
        if not activate:
            return self._window_check()
        deadline = time.monotonic() + 2
        request_activation = True
        while True:
            try:
                return self._window_check(activate=request_activation, setup_wait=True)
            except WindowStateError as error:
                state = error.evidence.get("response") or {}
                remaining = deadline - time.monotonic()
                # Fixture readiness can precede native-window publication.
                # Only explicit setup activation waits, and it activates once;
                # subsequent polls merely observe and retain their own records.
                if (remaining <= 0 or state.get("frontmostPID") != self.app_pid
                        or len(state.get("windows", [])) == 1
                        or self.process is None or self.process.poll() is not None):
                    raise
                request_activation = False
                time.sleep(min(0.05, remaining))

    def _window_check(self, activate: bool = False, setup_wait: bool = False) -> dict:
        # Timed checks stay strict: only an explicit activate=True may change
        # foreground focus. Retain the failed response before propagating it.
        record = {"check": self.window_check_count, "requestedActivation": activate,
                  "setupWindowWait": setup_wait,
                  "monotonicNS": time.perf_counter_ns(),
                  "appPID": self.process.pid if self.process else None, "response": None}
        self.window_check_count += 1
        path = self.directory / f"window-checks/{record['check']:04d}.json"
        try:
            record["processReturncode"] = self.process.poll() if self.process else None
            if self.process is None or record["processReturncode"] is not None:
                raise RuntimeError("owned application exited")
            result = window_command(self.helper, "activate" if activate else "inspect", self.app_pid)
            record["response"] = result
            if result["frontmostPID"] != self.app_pid or len(result["windows"]) != 1:
                raise RuntimeError("comparison needs exactly one visible owned window, frontmost")
            record["status"] = "valid"
            return result
        except Exception as error:
            record.update(status="invalid", error=str(error))
            if isinstance(error, WindowHelperError):
                record["helperFailure"] = error.evidence
            if record["response"] is None and self.process is not None and self.process.poll() is None:
                try:
                    # Activation can fail without returning window metadata.
                    # Inspect for evidence only; never turn a failed check into
                    # a pass just because this second observation succeeds.
                    record["response"] = window_command(self.helper, "inspect", self.app_pid)
                except Exception as inspection_error:
                    record["inspectionError"] = str(inspection_error)
                    if isinstance(inspection_error, WindowHelperError):
                        record["inspectionFailure"] = inspection_error.evidence
            raise WindowStateError(str(error), record) from error
        finally:
            self.last_window_check = record
            atomic_json(path, record)

    def fit_grid(self, target: tuple[int, int], allow_resize: bool = False) -> dict:
        attempts = []
        activation_budget = 3
        def save():
            atomic_json(self.directory / "geometry.json", {
                "target": target, "attempts": attempts,
                "setupActivationAttemptsRemaining": activation_budget})
        # Let asynchronous layout converge; no artificial stty row/column writes.
        time.sleep(0.35)
        for _ in range(14):
            attempt: dict = {"status": "checking"}
            attempts.append(attempt)
            try:
                actual = self.grid()
                attempt["grid"] = actual
                activate = False
                while True:
                    try:
                        state = self.window(activate=activate)
                        break
                    except WindowStateError as error:
                        attempt.setdefault("windowFailures", []).append(error.evidence)
                        save()
                        if (activation_budget <= 0 or self.process is None
                                or self.process.poll() is not None):
                            raise
                        # Setup only: a resize may momentarily move focus. A
                        # fixed total budget prevents stealing focus indefinitely.
                        activation_budget -= 1
                        activate = True
                        time.sleep(0.1)
                attempt["window"] = state
                if (actual["columns"], actual["rows"]) == target:
                    self.target_grid = target
                    attempt["status"] = "matched"
                    return actual
                if not allow_resize:
                    assert_grid(actual, target)
                bounds = state["windows"][0]["bounds"]
                # Approximate cell metrics, then converge against the actual PTY.
                cell_width = bounds["width"] / (actual["columns"] + 2)
                cell_height = max(1, (bounds["height"] - 45) / (actual["rows"] + 1))
                width = bounds["width"] + (target[0] - actual["columns"]) * cell_width
                height = bounds["height"] + (target[1] - actual["rows"]) * cell_height
                attempt["resizeResponse"] = window_command(self.helper, "resize", self.app_pid, width, height)
                attempt["status"] = "resized"
                time.sleep(0.15)
            except Exception as error:
                attempt.update(status="failed", error=str(error))
                if isinstance(error, WindowHelperError):
                    attempt["helperFailure"] = error.evidence
                raise
            finally:
                save()
        raise RuntimeError(f"could not converge to actual {target[0]}x{target[1]} grid; see geometry.json")

    def place_window(self, x: float, y: float) -> dict:
        evidence = {"target": {"x": x, "y": y}, "status": "checking"}
        try:
            before = self.window()
            evidence["windowBefore"] = before
            bounds = before["windows"][0]["bounds"]
            evidence["resizeResponse"] = window_command(
                self.helper, "resize", self.app_pid, bounds["width"], bounds["height"], x, y)
            time.sleep(0.2)
            state = self.window()
            evidence.update(status="valid", windowAfter=state)
            atomic_json(self.directory / "window-position.json", state)
            return state
        except Exception as error:
            evidence.update(status="failed", error=str(error))
            if isinstance(error, WindowHelperError):
                evidence["helperFailure"] = error.evidence
            raise
        finally:
            atomic_json(self.directory / "window-position-resize.json", evidence)

    def close(self) -> None:
        cleanup: dict = {"appPID": self.process.pid if self.process else None}
        if self.process is not None:
            if self.is_drain and self.process.poll() is None and Path(self.socket_path).exists():
                try:
                    self.request("quit")
                    cleanup["fixtureQuit"] = True
                except (OSError, RuntimeError, ValueError) as error:
                    cleanup["fixtureQuitError"] = str(error)
            elif not self.is_drain and self.worker_identity and self.process.poll() is None:
                # Give an independent fixture a chance to write its final raw
                # records. Verify both original start identity and ancestry;
                # never signal a PID from an unverified/stale ready.json alone.
                worker_pid, identity = self.worker_identity
                if process_identity(worker_pid) == identity and is_descendant(worker_pid, self.app_pid):
                    try:
                        os.kill(worker_pid, signal.SIGTERM)
                        cleanup["fixtureTerminate"] = worker_pid
                        deadline = time.monotonic() + 2
                        while process_identity(worker_pid) == identity and time.monotonic() < deadline:
                            time.sleep(0.05)
                    except ProcessLookupError:
                        pass
            if self.process.poll() is None:
                self.process.terminate()  # Popen checks ownership/reaping before signaling.
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
                    cleanup["forcedKill"] = True
            cleanup["returncode"] = self.process.returncode
        if self.log:
            self.log.close()
        if self.terminal == "cmdy" and self.process is not None:
            cleanup["defaultsExport"] = command_result(["/usr/bin/defaults", "export", self.domain, "-"])
            cleanup["defaultsDelete"] = command_result(["/usr/bin/defaults", "delete", self.domain])
        self.temporary.cleanup()
        atomic_json(self.directory / "cleanup.json", cleanup)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def process_identity(pid: int) -> str | None:
    result = command_result(["/bin/ps", "-p", str(pid), "-o", "lstart="])
    return result.get("stdout") if result.get("returncode") == 0 else None


def is_descendant(pid: int, ancestor: int) -> bool:
    seen = set()
    for _ in range(32):
        if pid in seen or pid <= 1:
            return False
        if pid == ancestor:
            return True
        seen.add(pid)
        result = command_result(["/bin/ps", "-p", str(pid), "-o", "ppid="])
        try:
            pid = int(result.get("stdout", ""))
        except ValueError:
            return False
    return False


def cpu_seconds(raw: str) -> float:
    days = 0
    if "-" in raw:
        day, raw = raw.split("-", 1)
        days = int(day)
    parts = list(map(float, raw.split(":")))
    if len(parts) not in (2, 3):
        raise ValueError(f"unrecognized ps CPU time: {raw}")
    return days * 86400 + sum(value * 60 ** index for index, value in enumerate(reversed(parts)))


def process_sample(pid: int) -> dict:
    result = command_result(["/bin/ps", "-p", str(pid), "-o", "pid=", "-o", "time=", "-o", "rss="])
    fields = result.get("stdout", "").split()
    if result.get("returncode") != 0 or len(fields) != 3 or int(fields[0]) != pid:
        raise RuntimeError("owned process disappeared while sampling CPU/RSS")
    return {"monotonicNS": time.perf_counter_ns(), "pid": pid,
            "cpuSeconds": cpu_seconds(fields[1]), "rssBytes": int(fields[2]) * 1024,
            "raw": result}


def idle_sample(pid: int, seconds: float) -> dict:
    before = process_sample(pid)
    time.sleep(seconds)
    after = process_sample(pid)
    wall = (after["monotonicNS"] - before["monotonicNS"]) / 1e9
    return {"before": before, "after": after, "wallSeconds": wall,
            "cpuPercentOfOneCore": (after["cpuSeconds"] - before["cpuSeconds"]) / wall * 100,
            "scope": "owned app process only; excludes child fixture and WindowServer",
            "cpuClockResolutionSeconds": 0.01}


def native_condition_signature(value: dict) -> dict:
    if (value.get("ok") is not True or type(value.get("lowPowerMode")) is not bool
            or type(value.get("thermalState")) is not int or value["thermalState"] != 0
            or not isinstance(value.get("os"), str) or not value["os"]):
        raise RuntimeError("nominal native thermal and low-power conditions are required")
    return {key: value[key] for key in ("lowPowerMode", "thermalState", "os")}


def summary(samples: list[dict], blocks: int) -> dict:
    measured = [item for item in samples if not item["warmup"]]
    terminals = {}
    for name in ("cmdy", "ghostty"):
        values = [item["elapsedNS"] / 1e9 for item in measured if item["terminal"] == name]
        if not values:
            raise ValueError("cannot summarize without both terminals")
        terminals[name] = {"samples": len(values), "medianSeconds": statistics.median(values),
                           "minimumSeconds": min(values), "maximumSeconds": max(values)}
    ratios = []
    for block in range(blocks):
        medians = {name: statistics.median(item["elapsedNS"] for item in measured
                                         if item["terminal"] == name and item["block"] == block)
                   for name in terminals}
        ratios.append({"block": block, "cmdyOverGhostty": medians["cmdy"] / medians["ghostty"]})
    return {"metric": METRIC, "terminals": terminals, "pairedBlockRatios": ratios,
            "medianPairedDrainRatio": statistics.median(item["cmdyOverGhostty"] for item in ratios),
            "interpretation": "lower drain duration is better; no display-latency or physical-input claim"}


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=os.environ.get("CMDY_BENCH_OUTPUT"),
                        help="required new evidence directory; existing paths are never overwritten")
    parser.add_argument("--cmdy-bin", type=Path, default=os.environ.get("CMDY_BIN", ROOT / ".build/release/cmdy"))
    parser.add_argument("--ghostty-bin", type=Path,
                        default=Path(os.environ.get("GHOSTTY_APP", "/Applications/Ghostty.app")) / "Contents/MacOS/ghostty")
    parser.add_argument("--profile", choices=("matched", "cmdy-defaults"), default="matched")
    parser.add_argument("--workload", choices=tuple(WORKLOAD_PATTERNS), default=os.environ.get("CMDY_BENCH_WORKLOAD", "continuous"))
    parser.add_argument("--bytes", type=int, default=int(os.environ.get("CMDY_BENCH_BYTES", "3000000")))
    parser.add_argument("--font-size", type=float, default=14)
    parser.add_argument("--columns", type=int, help="explicit grid; requires --rows and may need Accessibility")
    parser.add_argument("--rows", type=int)
    parser.add_argument("--display-id", type=int, help="require this CoreGraphics display ID for every measured window")
    parser.add_argument("--blocks", type=int, default=4)
    parser.add_argument("--samples", type=int, default=3, help="measured drains per process, after warmups")
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--first", choices=("cmdy", "ghostty"), default="cmdy")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--settle-seconds", type=float, default=15)
    parser.add_argument("--idle-seconds", type=float, default=3)
    parser.add_argument("--between-samples-seconds", type=float, default=0.25,
                        help="equal untimed pause for pending frame work between drains")
    parser.add_argument("--window-helper", type=Path, help="reuse an already compiled TerminalBenchWindow helper")
    parser.add_argument("--prepare-only", action="store_true", help="write configs/metadata without compiling or launching GUI")
    parser.add_argument("--no-restore-frontmost", action="store_true",
                        help="leave focus restoration to an outer controller that monitors human input")
    parser.add_argument("--diagnostic-frame-trace", action="store_true",
                        help="enable CMDY phase logging; output is diagnostic, never comparative qualification")
    parser.add_argument("--note", action="append", default=[], help="record relevant conditions, without credentials")
    return parser


def restore_frontmost(metadata: dict, helper: Path | None, prior: int | None, managed: bool) -> None:
    if managed:
        metadata["restoreFrontmostManagedExternally"] = True
    elif helper and prior:
        try:
            metadata["restoreFrontmost"] = window_command(helper, "activate", prior)
        except Exception as error:
            metadata["restoreFrontmostError"] = str(error)


def main() -> int:
    parser = make_parser()
    args = parser.parse_args()
    if args.output is None:
        parser.error("--output (or CMDY_BENCH_OUTPUT) is required so evidence has a durable location")
    if sys.platform != "darwin":
        parser.error("the GUI harness requires macOS; unit tests do not")
    if bool(args.columns) != bool(args.rows) or (args.columns is not None and (args.columns < 10 or args.rows < 4)):
        parser.error("supply both --columns >= 10 and --rows >= 4")
    if not (1 <= args.bytes <= 100_000_000 and 6 <= args.font_size <= 40
            and 1 <= args.blocks <= 100 and 1 <= args.samples <= 100 and 0 <= args.warmups <= 20
            and 1 <= args.timeout <= 600 and 0 <= args.settle_seconds <= 60 and 0.1 <= args.idle_seconds <= 60
            and 0 <= args.between_samples_seconds <= 60):
        parser.error("counts/durations are outside the supported bounds")
    for binary in (args.cmdy_bin, args.ghostty_bin):
        if not os.access(binary, os.X_OK):
            parser.error(f"missing executable: {binary}; build/install it separately")
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    os.chmod(output, 0o700)
    (output / "runs").mkdir()
    (output / "tooling").mkdir()
    for name in ("competitive-bench.sh", "competitive_bench.py", "terminal_bench_worker.py", "TerminalBenchWindow.swift"):
        shutil.copy2(ROOT / "Tests" / name, output / "tooling" / name)
    payload = output / "payload.bin"
    payload.write_bytes(payload_bytes(args.workload, args.bytes))
    options = BenchOptions(args.cmdy_bin.resolve(), args.ghostty_bin.resolve(), payload,
                           args.profile, args.font_size, args.timeout, args.settle_seconds,
                           tooling_dir=output / "tooling", diagnostic_frame_trace=args.diagnostic_frame_trace)
    metadata = {"schemaVersion": 2, "state": "preparing", "metric": METRIC,
                "startedUTC": datetime.now(timezone.utc).isoformat(),
                "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
                "notes": args.note, "python": sys.version, "architecture": platform.machine(),
                "diagnostic": args.diagnostic_frame_trace,
                "os": command_result(["/usr/bin/sw_vers"]),
                "hardware": command_result(["/usr/sbin/sysctl", "hw.model", "hw.memsize", "hw.physicalcpu",
                                             "hw.logicalcpu", "machdep.cpu.brand_string"]),
                "sourceCommit": command_result(["/usr/bin/git", "rev-parse", "HEAD"], ROOT),
                "sourceStatus": command_result(["/usr/bin/git", "status", "--porcelain"], ROOT),
                "binaries": {"cmdy": binary_metadata(options.cmdy_bin), "ghostty": binary_metadata(options.ghostty_bin)},
                "harnessSHA256": {name: sha256(output / "tooling" / name) for name in
                                  ("competitive_bench.py", "terminal_bench_worker.py", "TerminalBenchWindow.swift")},
                "workload": {"kind": args.workload, "bytes": args.bytes, "sha256": sha256(payload),
                             "transport": "raw PTY, OPOST off; no ONLCR translation; exact byte count",
                             "patternHex": WORKLOAD_PATTERNS[args.workload].hex(),
                             "tail": "truncated pattern" if args.workload in ("continuous", "lines") else "complete pattern then ASCII A padding",
                             "screenReset": "ED3 + ED2 + CUP, validated DSR before each timer",
                             "screen": "primary, native terminal scrollback limits; not memory-capacity-normalized"},
                "powerBefore": power_snapshot()}
    atomic_json(output / "manifest.json", metadata)
    print(f"Evidence: {output}", flush=True)
    target = (args.columns, args.rows) if args.columns else None
    if args.prepare_only:
        for name in ("cmdy", "ghostty"):
            (output / f"{name}.config.example").write_text(terminal_config(name, options, target, Path("<isolated-cwd>")))
        metadata["state"] = "prepared-no-GUI-launched"
        atomic_json(output / "manifest.json", metadata)
        return 0
    helper = None
    prior_frontmost = None
    samples = []
    powers = [metadata["powerBefore"]]
    reference_window = None
    try:
        helper = create_helper(output, args.window_helper)
        probe = window_command(helper, "probe", args.font_size)
        atomic_json(output / "display-font-permissions.json", probe)
        if probe["font"]["postScriptName"] != "Menlo-Regular" or not probe["font"]["file"]:
            raise RuntimeError("Menlo-Regular did not resolve; no font was installed or fallback accepted")
        metadata["fontSHA256"] = sha256(Path(probe["font"]["file"]))
        metadata["helperSHA256"] = sha256(helper)
        metadata["nativeConditionsBefore"] = window_command(helper, "conditions")
        native_reference = native_condition_signature(metadata["nativeConditionsBefore"])
        prior_frontmost = probe["frontmostPID"]
        allow_resize = probe["accessibilityTrusted"]
        # Automatic geometry uses a separate, unmeasured CMDY launch. Thus the
        # measured block order can alternate without guessing CMDY's grid.
        if target is None:
            with TerminalSession(options, helper, "cmdy", output / "runs/calibration-cmdy") as session:
                session.launch()
                session.window(activate=True)
                time.sleep(1)
                actual = session.grid()
                target = (actual["columns"], actual["rows"])
                if target[0] < 10 or target[1] < 4:
                    raise RuntimeError(f"calibration produced an invalid grid: {actual}")
                atomic_json(output / "calibration.json", {"grid": actual, "window": session.window()})
                reference_window = session.window()["windows"][0]
        metadata["targetGrid"] = {"columns": target[0], "rows": target[1]}
        metadata["state"] = "running"
        atomic_json(output / "manifest.json", metadata)
        for block in range(args.blocks):
            for terminal in block_order(block, args.first):
                directory = output / f"runs/{block:02d}-{terminal}"
                before_power = power_snapshot()
                powers.append(before_power)
                with TerminalSession(options, helper, terminal, directory, target) as session:
                    print(f"Block {block + 1}/{args.blocks}: {terminal}, {target[0]}x{target[1]}, {args.profile}", flush=True)
                    session.launch()
                    session.window(activate=True)
                    if args.columns:
                        session.place_window(120, 120)
                    session.fit_grid(target, allow_resize=allow_resize)
                    if reference_window and allow_resize:
                        session.place_window(reference_window["bounds"]["x"], reference_window["bounds"]["y"])
                        session.fit_grid(target, allow_resize=True)
                    current_window = session.window()["windows"][0]
                    if args.display_id is not None and current_window["displayID"] != args.display_id:
                        raise RuntimeError(f"owned window is not on required display {args.display_id}")
                    if reference_window is None:
                        reference_window = current_window
                    elif current_window["displayID"] != reference_window["displayID"]:
                        raise RuntimeError("owned windows are on different displays; comparison rejected")
                    time.sleep(args.settle_seconds)
                    atomic_json(directory / "window-before.json", session.window())
                    atomic_json(directory / "idle.json", idle_sample(session.app_pid, args.idle_seconds))
                    native_before = window_command(helper, "conditions")
                    atomic_json(directory / "native-conditions.json", {"before": native_before})
                    if native_condition_signature(native_before) != native_reference:
                        raise RuntimeError("native power/thermal conditions changed before drain")
                    for index in range(args.warmups + args.samples):
                        state_before = session.window()
                        assert_grid(session.grid(), target)
                        started = time.perf_counter_ns()
                        raw = {"terminal": terminal, "block": block, "index": index,
                               "warmup": index < args.warmups, "windowBefore": state_before}
                        try:
                            raw.update(session.request("drain", sequence=index, timeout=args.timeout))
                            raw["hostRequestElapsedNS"] = time.perf_counter_ns() - started
                            raw["windowAfter"] = session.window()
                            assert_grid(raw["gridBefore"], target)
                            assert_grid(raw["gridAfter"], target)
                            if raw["windowAfter"]["windows"] != state_before["windows"]:
                                raise RuntimeError("owned window geometry/visibility changed during drain")
                            raw["status"] = "valid"
                            samples.append(raw)
                        except Exception as error:
                            raw.update(status="invalid", error=str(error))
                            raise
                        finally:
                            atomic_json(directory / f"sample-{index:02d}.json", raw)
                        time.sleep(args.between_samples_seconds)
                    atomic_json(directory / "window-after.json", session.window())
                    atomic_json(directory / "process-after.json", process_sample(session.app_pid))
                    native_after = window_command(helper, "conditions")
                    atomic_json(directory / "native-conditions.json", {"before": native_before, "after": native_after})
                    if native_condition_signature(native_after) != native_reference:
                        raise RuntimeError("native power/thermal conditions changed during drain")
                after_power = power_snapshot()
                powers.append(after_power)
                atomic_json(directory / "power.json", {"before": before_power, "after": after_power})
        if any(not power["signature"]["source"] or not power["signature"]["settings"] for power in powers):
            raise RuntimeError("power source/settings could not be recorded; comparison is not qualified")
        if any(power["signature"] != powers[0]["signature"] for power in powers[1:]):
            raise RuntimeError("power source/settings changed; retained samples are not a qualified comparison")
        metadata["nativeConditionsAfter"] = window_command(helper, "conditions")
        if native_condition_signature(metadata["nativeConditionsAfter"]) != native_reference:
            raise RuntimeError("final native power/thermal conditions changed")
        report = summary(samples, args.blocks)
        report.update(profile=args.profile, targetGrid=metadata["targetGrid"],
                      status="diagnostic" if args.diagnostic_frame_trace else "qualified")
        atomic_json(output / "summary.json", report)
        metadata["state"] = "complete"
        print(f"Median paired CMDY/Ghostty drain ratio: {report['medianPairedDrainRatio']:.3f}x (lower is better)")
        print("This measures PTY/terminal processing through a validated DSR response, not frame latency.")
        return 0
    except Exception as error:
        metadata.update(state="failed", error=str(error))
        print(f"Comparison failed; evidence retained: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        metadata.update(state="interrupted", error="benchmark interrupted; partial evidence retained")
        return 130
    finally:
        metadata["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        metadata["powerAfter"] = power_snapshot()
        restore_frontmost(metadata, helper, prior_frontmost, args.no_restore_frontmost)
        atomic_json(output / "manifest.json", metadata)


if __name__ == "__main__":
    # Ensure Ctrl-C/termination unwinds the owned-session cleanup and preserves
    # evidence. Nothing signals a process by name, global pgrep diff, or killall.
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
