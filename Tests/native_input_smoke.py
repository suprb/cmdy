#!/usr/bin/env python3
"""Live native input smoke using an isolated raw recorder and PID-scoped keys.

Prebuild both helpers before reserving GUI/timing time:
  swiftc Tests/TerminalBenchWindow.swift -o /tmp/terminal-bench-window
  swiftc -O -parse-as-library Tests/NativeInputSmoke.swift -o /tmp/native-input-key
Run only in an authorized GUI slot (no helper compilation happens here):
  python3 Tests/native_input_smoke.py --app cmdy.app \
    --window-helper /tmp/terminal-bench-window --key-helper /tmp/native-input-key \
    --output /private/tmp/cmdy-native-input-smoke

Derives the current layout's acute dead key with Carbon UCKeyTranslate and
requires existing event-posting permission. It does not switch the user's input
source or evaluate typed input. The proof records keys, modifiers and UTF-8.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import termios
import time
import tty

from competitive_bench import BenchOptions, TerminalSession
from terminal_bench_worker import atomic_json


def record(directory: Path) -> int:
    """The only process receiving test keystrokes; bytes are never commands."""
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    original = termios.tcgetattr(fd)
    running = True
    received = bytearray()
    chunks: list[dict] = []

    def stop(*_):
        nonlocal running
        running = False

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, stop)
    outcome = {"ok": False, "termiosRestored": False}
    try:
        tty.setraw(fd, termios.TCSANOW)
        os.write(fd, b"\x1b[0m\x1b[2J\x1b[HNative input recorder (raw bytes, no command evaluation)\r\n> ")
        atomic_json(directory / "received.json", {"hex": "", "chunks": []})
        size = os.get_terminal_size(fd)
        atomic_json(directory / "ready.json", {
            "pid": os.getpid(), "parentPID": os.getppid(), "ttyPath": os.ttyname(fd),
            "rows": size.lines, "columns": size.columns,
            "readyMonotonicNS": time.monotonic_ns()})
        deadline = time.monotonic() + 60
        while running and time.monotonic() < deadline:
            if not select.select([fd], [], [], 0.05)[0]:
                continue
            data = os.read(fd, 4096)
            if not data:
                break
            received.extend(data)
            chunks.append({"hex": data.hex(), "receivedMonotonicNS": time.monotonic_ns()})
            atomic_json(directory / "received.json", {"hex": received.hex(), "chunks": chunks})
            if len(received) > 4096:
                raise ValueError("raw input exceeded the bounded smoke payload")
        outcome["ok"] = not running
    except Exception as error:
        outcome["error"] = str(error)
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSANOW, original)
            outcome["termiosRestored"] = True
        except (OSError, termios.error) as error:
            outcome["error"] = "termios restore: " + str(error)
        os.close(fd)
        atomic_json(directory / "cleanup.json", dict(outcome, hex=received.hex()))
    return 0 if outcome["ok"] and outcome["termiosRestored"] else 1


def key_command(helper: Path, *arguments: object) -> dict:
    result = subprocess.run([str(helper), *map(str, arguments)],
                            capture_output=True, text=True, timeout=8)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"physical-key helper returned invalid evidence: {result.stderr}") from error
    if result.returncode or not value.get("ok"):
        raise RuntimeError(value.get("error", "physical-key helper failed"))
    return value


def expect_bytes(path: Path, expected: bytes, quiet: float = 0.3) -> dict:
    deadline = time.monotonic() + 2
    matched_since = None
    while time.monotonic() < deadline:
        value = json.loads(path.read_text())
        actual = bytes.fromhex(value["hex"])
        if not expected.startswith(actual):
            raise AssertionError(f"received {actual.hex()}, expected exactly {expected.hex()}")
        if actual == expected:
            if matched_since is None:
                matched_since = time.monotonic()
            if time.monotonic() - matched_since >= quiet:
                return value
        time.sleep(0.015)
    raise AssertionError(f"did not receive exactly {expected.hex()} within two seconds")


def run_case(args, meta: bool, preflight: dict) -> dict:
    directory = args.output / ("meta-on" if meta else "meta-off")
    recorder = directory / "recorder"
    binary = args.app / "Contents/MacOS/cmdy"
    options = BenchOptions(cmdy_bin=binary, ghostty_bin=binary, timeout=15)
    session = TerminalSession(
        options, args.window_helper, "cmdy", directory,
        fixture_command=[sys.executable, str(Path(__file__).resolve()), "--record", str(recorder)],
        ready_path=recorder / "ready.json")
    with session.config_path.open("a") as config:
        config.write(f"option-as-meta = {'true' if meta else 'false'}\n")
    evidence = {"optionAsMeta": meta, "checks": [], "ok": False}
    try:
        session.launch()
        window = session.window(activate=True)
        window_id = window["windows"][0]["windowID"]
        evidence.update(appPID=session.app_pid, windowID=window_id)
        initial = expect_bytes(recorder / "received.json", b"")
        evidence["checks"].append({"phase": "ready", "expectedHex": "", "received": initial})
        steps = [("meta-e", b"\x1be")] if meta else [
            ("dead-key", b""), ("plain-e", "é".encode()),
            ("ascii-control", "é".encode() + b"a\x03")]
        for phase, expected in steps:
            session.window()
            posted = key_command(args.key_helper, session.app_pid, window_id, phase)
            if (posted["inputSource"] != preflight["inputSource"]
                    or posted["sequence"] != preflight["sequence"]):
                raise RuntimeError("input source or derived physical sequence changed between smoke cases")
            actual = expect_bytes(recorder / "received.json", expected,
                                  quiet=0.5 if phase == "dead-key" else 0.3)
            session.window()
            evidence["checks"].append({"phase": phase, "expectedHex": expected.hex(),
                                       "posted": posted, "received": actual})
            atomic_json(directory / "result.json", evidence)
        evidence["ok"] = True
    except Exception as error:
        evidence["error"] = str(error)
    finally:
        session.close()
        cleanup_path = recorder / "cleanup.json"
        if cleanup_path.exists():
            evidence["recorderCleanup"] = json.loads(cleanup_path.read_text())
        if not evidence.get("recorderCleanup", {}).get("termiosRestored"):
            evidence.update(ok=False, cleanupError="raw recorder did not confirm restored termios")
        atomic_json(directory / "result.json", evidence)
    return evidence


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--record":
        return record(Path(sys.argv[2]))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--window-helper", type=Path, required=True)
    parser.add_argument("--key-helper", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for name in ("app", "window_helper", "key_helper", "output"):
        setattr(args, name, getattr(args, name).resolve())
    binary = args.app / "Contents/MacOS/cmdy"
    for executable in (binary, args.window_helper, args.key_helper):
        if not os.access(executable, os.X_OK):
            parser.error(f"missing executable: {executable}; prebuild helpers before GUI work")
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    evidence = {"ok": False, "app": str(args.app),
                "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "cases": []}
    try:
        probe = key_command(args.key_helper, "inspect")
        evidence["preflight"] = probe
        if not probe["postEventAuthorized"]:
            raise RuntimeError("requires existing event-posting access; no permission prompt was opened")
        if (probe["sequence"]["expectedUTF8Hex"] != "c3a9"
                or probe["sequence"]["deadKeyOutputUTF8Hex"] != ""
                or probe["sequence"]["metaExpectedUTF8Hex"] != "1b65"):
            raise RuntimeError("current-layout proof does not match the required byte assertions")
        for meta in (False, True):
            result = run_case(args, meta, probe)
            evidence["cases"].append(result)
            if not result["ok"]:
                raise RuntimeError("native input case failed; see case result.json")
        evidence["ok"] = True
    except Exception as error:
        evidence["error"] = str(error)
    atomic_json(args.output / "result.json", evidence)
    print(json.dumps({"ok": evidence["ok"], "evidence": str(args.output / "result.json")}))
    return 0 if evidence["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
