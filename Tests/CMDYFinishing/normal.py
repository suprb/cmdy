"""Qualify an owned normal CMDY app; never reads the general clipboard."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TESTS))
from competitive_bench import launch_environment, power_snapshot
from history_export_binding import cmdy_store_bytes
from CMDYFinishing.owned_worker_ready import wait_owned_worker

def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
def until(check, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result: return result
        time.sleep(0.025)
    raise TimeoutError("condition did not complete")
def native(helper, *args):
    result = subprocess.run([str(helper), *map(str, args)], capture_output=True, text=True, timeout=15)
    if result.returncode: raise RuntimeError(result.stdout + result.stderr)
    value = json.loads(result.stdout)
    assert value.get("ok"), value
    return value

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "output", "window", "input", "actions", "memory"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--cycles", type=int, default=24)
    parser.add_argument("--profile-memory", action="store_true", help="diagnostic only; excludes timings from comparisons")
    parser.add_argument("--menu", type=Path, help="existing owned native menu observer")
    parser.add_argument("--menu-captures", action="store_true", help="capture actual owned menu windows for visual correctness; requires --menu")
    parser.add_argument("--toolbar", type=Path, help="owned normal toolbar visual and interaction observer")
    parser.add_argument("--find", type=Path, help="owned normal Find interaction and visual observer")
    parser.add_argument("--tab-focus", action="store_true", help="verify native new-tab and close keyboard routing")
    parser.add_argument("--background-holder", type=Path, help="owned short-lived foreground helper")
    args = parser.parse_args()
    if args.menu_captures and not args.menu:
        parser.error("--menu-captures requires --menu")
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.app.resolve() / "Contents/MacOS/cmdy"
    receipt = dict(status="running", binary=str(binary), executableSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                   power=power_snapshot(), conditions=native(args.window, "conditions"),
                   checks=[], cycles=[], idle={}, clipboardAccessed=False,
                   diagnosticProfiling=args.profile_memory,
                   tools={str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in (args.window, args.input, args.actions, args.memory, args.menu, args.toolbar, args.find, args.background_holder)
                          if path is not None})
    root = Path(tempfile.mkdtemp(prefix="cmdy-finish-native-", dir="/private/tmp"))
    receipt["runtime"] = str(root)
    for name in ("cwd", "tmp", "cmdy-config", "zsh", "xdg-config", "xdg-cache", "xdg-data", "xdg-state"):
        (root / name).mkdir(mode=0o700)
    config = """restore-session = false
marketplace-update-checks = false
automatic-error-help = false
font-family = Menlo-Regular
font-size = 14
shell-integration = false
clean-prompt = false
sounds = false
ghost-text = false
shader = None
smooth-cursor = false
smooth-scroll = true
cursor-style = block
cursor-blink = false
line-height = 1
opacity = 1
window-grid = false
workspace-navigator = false
workspace-inspector = false
option-as-meta = false
"""
    (root / "cmdy-config/config").write_text(config)
    (root / "cmdy-config/keybindings.json").write_bytes(cmdy_store_bytes())
    save(root / "cmdy-config/app-update-state.json", {"lastCheck": time.time()})
    worker = TESTS / "CMDYFinishing/worker.py"
    (root / "zsh/.zshenv").write_text("exec " + shlex.join([str(Path(sys.executable).resolve()), "-B", str(worker), str(root)]) + "\n")
    environment = launch_environment(os.environ, root, root / "cwd", "com.cmdy.finishing." + uuid.uuid4().hex)
    environment["TMPDIR"] = str(root / "tmp") + "/"
    process = None
    workers = set()
    log = (args.output / "app.log").open("x")
    def check(name, detail=None):
        receipt["checks"].append(dict(name=name, detail=detail)); print("PASS:", name, flush=True)
        save(args.output / "result.json", receipt)
    def control(pid, command="state"):
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(5); peer.connect(str(root / f"w-{pid}.sock"))
            peer.sendall(json.dumps({"command": command}).encode() + b"\n")
            data = bytearray()
            while not data.endswith(b"\n"):
                part = peer.recv(65536); assert part; data.extend(part)
        return json.loads(data)
    def worker_ready(pid):
        ready = wait_owned_worker(lambda: control(pid), pid, process.pid)
        receipt.setdefault("workerReadiness", []).append(ready)
        save(args.output / "result.json", receipt)
        return ready
    try:
        started = time.monotonic_ns()
        process = subprocess.Popen([str(binary)], cwd=root / "cwd", env=environment, stdout=log, stderr=subprocess.STDOUT)
        receipt["pid"] = process.pid
        discovery = root / "cmdy-config/extension-api.json"
        until(lambda: discovery.exists() and discovery.stat().st_size)
        credentials = json.loads(discovery.read_text())
        def api(method, path, body=None):
            request = urllib.request.Request(f"http://127.0.0.1:{credentials['port']}" + path,
                data=None if body is None else json.dumps(body).encode(), method=method,
                headers={"Authorization": "Bearer " + credentials["token"], "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=10) as response: return json.load(response)
        def panes(): return api("GET", "/v1/panes")["panes"]
        first = until(lambda: next((p for p in panes() if p["pid"] > 0), None))
        first_id, first_pid = first["id"], first["pid"]; workers.add(first_pid)
        worker_ready(first_pid)
        until(lambda: api("GET", "/v1/debug/framestats").get("frames", 0) > 0)
        receipt["startupToGPUFrameNS"] = time.monotonic_ns() - started
        window = native(args.window, "activate", process.pid)
        window_id = window["windows"][0]["windowID"]
        assert control(first_pid)["parentPID"] == process.pid
        check("normal app starts an owned PTY and produces a GPU frame", window)
        native(args.input, process.pid, window_id, "dead-key")
        time.sleep(0.3); assert control(first_pid)["inputHex"] == ""
        native(args.input, process.pid, window_id, "plain-e")
        until(lambda: control(first_pid)["inputHex"] == "c3a9")
        native(args.input, process.pid, window_id, "ascii-control")
        until(lambda: control(first_pid)["inputHex"] == "c3a96103")
        check("system dead key preedit and commit produce exact UTF-8/control bytes", native(args.input, "inspect"))
        for cycle in range(args.cycles):
            new_id = api("POST", f"/v1/panes/{first_id}/split", {"direction": "right"})["pane"]
            second = until(lambda: next((p for p in panes() if p["id"] == new_id and p["pid"] > 0), None))
            pid = second["pid"]; workers.add(pid)
            worker_ready(pid)
            control(pid, "history"); control(pid, "alternate"); control(pid, "image")
            api("POST", f"/v1/panes/{new_id}/type", {"text": "LIFETIME"})
            until(lambda: control(pid)["inputHex"] == b"LIFETIME".hex())
            if cycle == 1:
                native(args.window, "activate", process.pid)
                rect = native(args.window, "inspect", process.pid)["windows"][0]["bounds"]
                left_before, right_before = control(first_pid)["columns"], control(pid)["columns"]
                action = native(args.actions, "drag", process.pid, rect["x"] + rect["width"] / 2,
                    rect["y"] + rect["height"] * .7, 70, 0)
                until(lambda: control(first_pid)["columns"] > left_before and control(pid)["columns"] < right_before)
                check("pointer-driven split divider resizes both PTYs", action)
            if cycle % 3 == 0:
                extra_id = api("POST", f"/v1/panes/{new_id}/split", {"direction": "down"})["pane"]
                extra = until(lambda: next((p for p in panes() if p["id"] == extra_id and p["pid"] > 0), None))
                extra_pid = extra["pid"]; workers.add(extra_pid)
                worker_ready(extra_pid)
                api("POST", "/v1/windows/compose", {"panes": [new_id, extra_id]})
                until(lambda: len(native(args.window, "inspect", process.pid)["windows"]) == 2)
                control(extra_pid, "stop")
                until(lambda: (root / f"w-{extra_pid}-closed.json").exists())
            control(pid, "stop")
            until(lambda: len(panes()) == 1)
            until(lambda: (root / f"w-{pid}-closed.json").exists())
            control(first_pid, "draw")
            time.sleep(0.35)
            receipt["cycles"].append(native(args.memory, process.pid))
            save(args.output / "result.json", receipt)
            if args.profile_memory and cycle in (7, 23, 47, args.cycles - 1):
                time.sleep(3)
                for tool, extra in (("vmmap", ["-summary"]), ("leaks", ["--noContent", "--groupByType"]),
                                    ("heap", ["--sortBySize", "--noContent"])):
                    with (args.output / f"{tool}-{cycle + 1}.log").open("x") as stream:
                        result = subprocess.run(["/usr/bin/" + tool, *extra, str(process.pid)], stdout=stream, stderr=subprocess.STDOUT, timeout=45)
                    receipt.setdefault("profiles", []).append(dict(tool=tool, cycle=cycle + 1, exitCode=result.returncode))
                    if tool == "heap" and result.returncode == 0:
                        classes = {}
                        for line in (args.output / f"heap-{cycle + 1}.log").read_text().splitlines():
                            match = re.match(r"\s*(\d+)\s+\d+\s+[\d.]+\s+(NSKVONotifying_NSWindow|TerminalWindowController|TerminalModel|RendererScheduler|RenderWorkerSession|CmdyTerminalSurface|NativeSnapshotLine)\s", line)
                            if match: classes[match[2]] = int(match[1])
                        receipt.setdefault("heapCounts", []).append(dict(cycle=cycle + 1, classes=classes))
                save(args.output / "result.json", receipt)
        check("repeated panes/windows close independently after history, images and alternate screens", {"cycles": args.cycles, "workers": len(workers)})
        native(args.window, "activate", process.pid)
        native(args.actions, "key", process.pid, 17, 1048576)  # Command-T
        tab = until(lambda: next((p for p in panes() if p["pid"] > 0 and p["pid"] not in workers), None))
        workers.add(tab["pid"])
        worker_ready(tab['pid'])
        if args.tab_focus:
            first_before = control(first_pid)["inputHex"]
            tab_before = control(tab["pid"])["inputHex"]
            native(args.actions, "key", process.pid, 0, 0)  # A into the new native tab.
            until(lambda: control(tab["pid"])["inputHex"] == tab_before + "61")
            assert control(first_pid)["inputHex"] == first_before
            check("native new tab receives exact keyboard bytes while sibling stays unchanged")
        control(tab["pid"], "stop"); until(lambda: len(panes()) == 1)
        if args.tab_focus:
            native(args.actions, "key", process.pid, 0, 0)  # A after native tab close.
            until(lambda: control(first_pid)["inputHex"] == first_before + "61")
            check("native tab close restores keyboard routing to its surviving sibling")
        check("native new tab starts and exits its own PTY without closing its sibling")
        native(args.actions, "key", process.pid, 43, 1048576)  # Command-comma
        until(lambda: len(native(args.window, "inspect", process.pid)["windows"]) == 2)
        native(args.actions, "key", process.pid, 13, 1048576)  # Command-W on Settings
        until(lambda: len(native(args.window, "inspect", process.pid)["windows"]) == 1)
        check("native settings opens and closes without changing terminal lifetime")
        if args.menu:
            menu_args = [str(args.menu), str(process.pid), str(binary), receipt["executableSHA256"]]
            if args.menu_captures:
                menu_args += ["--capture-dir", str(args.output.resolve() / "menu-captures")]
            menu = subprocess.run(menu_args, capture_output=True, text=True, timeout=45 if args.menu_captures else 30)
            (args.output / "menus.log").write_text(menu.stdout + menu.stderr)
            assert menu.returncode == 0, "owned native menu check failed"
            check("File, View, Appearance and Fonts native menus open and dismiss", {"log": "menus.log"})
        if args.toolbar:
            toolbar = subprocess.run([str(args.toolbar), str(process.pid), str(binary),
                                      receipt["executableSHA256"],
                                      str(args.output.resolve() / "toolbar-captures")],
                                     capture_output=True, text=True, timeout=70)
            (args.output / "toolbar.log").write_text(toolbar.stdout + toolbar.stderr)
            assert toolbar.returncode == 0, "owned normal toolbar check failed"
            check("normal toolbar customization, compact transitions and visible controls", {"log": "toolbar.log"})
        if args.find:
            control(first_pid, "history")
            until(lambda: "HISTORY-00999" in api("GET", f"/v1/panes/{first_id}/output")["text"])
            find = subprocess.run([str(args.find), str(process.pid), str(binary),
                                   receipt["executableSHA256"],
                                   str(args.output.resolve() / "find-captures")],
                                  capture_output=True, text=True, timeout=70)
            (args.output / "find.log").write_text(find.stdout + find.stderr)
            assert find.returncode == 0, "owned normal Find check failed"
            check("normal Find opens, searches Unicode history, steps, closes and reopens", {"log": "find.log"})
        native(args.window, "activate", process.pid)
        window = native(args.window, "inspect", process.pid)["windows"][0]
        rect = window["bounds"]
        before = control(first_pid)
        drag = native(args.actions, "drag", process.pid, rect["x"] + rect["width"] - 2, rect["y"] + rect["height"] - 2, 80, 40)
        after = until(lambda: (state if (state := control(first_pid))["columns"] != before["columns"] else None))
        check("pointer-driven native window resize propagates to PTY geometry", {"before": before, "after": after, "action": drag})
        control(first_pid, "history")
        until(lambda: "HISTORY-00999" in api("GET", f"/v1/panes/{first_id}/output")["text"])
        before = api("GET", f"/v1/panes/{first_id}/scrollinfo")
        rect = native(args.window, "inspect", process.pid)["windows"][0]["bounds"]
        scroll = native(args.actions, "scroll", process.pid, rect["x"] + rect["width"] / 2, rect["y"] + rect["height"] / 2, 20)
        after = until(lambda: (value if (value := api("GET", f"/v1/panes/{first_id}/scrollinfo")) != before else None))
        check("pointer-driven precise scrolling changes the retained viewport", {"before": before, "after": after, "action": scroll})
        # Existing public file export returns a quoted path to this raw fixture.
        control(first_pid, "clear-input")
        native(args.actions, "key", process.pid, 36, 393216)
        encoded = until(lambda: control(first_pid)["inputHex"])
        path = Path(shlex.split(bytes.fromhex(encoded).decode())[0]).resolve()
        assert path.is_relative_to(root / "tmp") and path.is_file()
        text = path.read_text()
        assert all(f"HISTORY-{index:05d} é Å 中文 😀" in text for index in range(1000))
        (args.output / "history.txt").write_text(text)
        check("all 1000 Unicode history rows survive idle compaction and pointer scrolling", {"sha256": hashlib.sha256(text.encode()).hexdigest()})
        states = ["visible", "hidden", "resumed"] + (["background"] if args.background_holder else [])
        for label in states:
            native(args.actions, "hide" if label == "hidden" else "show", process.pid)
            holder = None
            try:
                if label == 'background':
                    holder = subprocess.Popen([str(args.background_holder), str(process.pid)], stdout=subprocess.PIPE, text=True)
                    ready = json.loads(holder.stdout.readline())
                    assert ready['ready'] and ready['pid'] == holder.pid and ready['targetPID'] == process.pid, ready
                    receipt['backgroundHolder'] = ready
                time.sleep(1)
                first_sample = native(args.memory, process.pid); time.sleep(5); last_sample = native(args.memory, process.pid)
                if holder: assert holder.poll() is None, 'background helper ended during observation'
            finally:
                if holder:
                    holder.wait(timeout=10)
                    assert holder.returncode == 0
            elapsed = (last_sample["startedMonotonicNS"] - first_sample["startedMonotonicNS"]) / 1e9
            assert first_sample['cpuTimeUnit'] == last_sample['cpuTimeUnit'] == 'nanoseconds'
            cpu = sum(last_sample[n] - first_sample[n] for n in ("userTimeNS", "systemTimeNS")) / 1e6 / elapsed
            receipt["idle"][label] = dict(first=first_sample, last=last_sample, cpuMillisecondsPerSecond=cpu,
                wakeupsPerSecond={name: (last_sample[name] - first_sample[name]) / elapsed
                    for name in ("interruptWakeups", "packageIdleWakeups") if name in first_sample})
        native(args.actions, 'show', process.pid)
        frames = api("GET", "/v1/debug/framestats")["frames"]
        control(first_pid, "draw")
        until(lambda: api("GET", "/v1/debug/framestats")["frames"] > frames)
        check("hidden renderer resumes output and frame production", receipt["idle"])
        control(first_pid, "stop")
        assert process.wait(timeout=10) == 0
        assert all((root / f"w-{pid}-closed.json").exists() for pid in workers)
        check("last pane exit drains the app and all owned workers")
        if args.profile_memory:
            counts = receipt["heapCounts"]
            assert all(item["classes"].get("RendererScheduler", 0) <= 2 for item in counts), "renderer objects accumulated"
            assert counts[-1]["classes"]["NSKVONotifying_NSWindow"] <= counts[0]["classes"]["NSKVONotifying_NSWindow"] + 4, "closed native windows accumulated"
            check("settled native window and renderer allocation counts remain bounded", counts)
        receipt["status"] = "pass"
    except BaseException as error:
        receipt.update(status="fail", error=repr(error)); raise
    finally:
        for pid in workers:
            if (root / f"w-{pid}.sock").exists():
                try: control(pid, "stop")
                except (OSError, ValueError): pass
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=8)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        log.close()
        receipt["exitCode"] = process.returncode if process else None
        save(args.output / "result.json", receipt)
        # Remove only this run's isolated defaults, never the user's domain.
        domain = environment.get("CMDY_DEFAULTS_DOMAIN")
        if domain and domain.startswith("com.cmdy.finishing."):
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if __name__ == "__main__": main()
