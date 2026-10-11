"""Run native package diagnostics with isolated preferences and retained receipts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid
from package_window_focus import activate_owned_window
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from competitive_bench import launch_environment

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--window-helper", type=Path,
                    help="activate the exact owned diagnostic window once after it appears")
args = parser.parse_args()
output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
root = Path(tempfile.mkdtemp(prefix="cmdy-finish-check-", dir="/private/tmp"))
for name in ("cwd", "cmdy-config", "zsh", "xdg-config", "xdg-cache", "xdg-data", "xdg-state"):
    (root / name).mkdir(mode=0o700)
(root / "cmdy-config/config").write_text("restore-session = false\nmarketplace-update-checks = false\n")
domain = "com.cmdy.finishing." + uuid.uuid4().hex
environment = launch_environment(os.environ, root, root / "cwd", domain)
binary = args.app.resolve() / "Contents/MacOS/cmdy"
receipt = dict(status="running", executableSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), checks=[])
try:
    # The finishing plan excludes the app selftest and general clipboard access.
    checks = [("window", ["--renderer-window-test", str(output / "window.json")])]
    checks += [(name, [f"--{name}-test"]) for name in ("scroll", "wheel", "reflow", "graphics", "shader")]
    checks += [("style", ["--renderer-style-test", str(output / "style.json")]),
               ("capture", ["--renderer-capture-profile", str(output / "capture.json")])]
    for label, arguments in checks:
        check_environment = dict(environment)
        if label in ("style", "capture"): check_environment["CMDY_FRAME_TRACE"] = "1"
        with (output / (label + ".log")).open("x") as log:
            process = subprocess.Popen([str(binary), *arguments], env=check_environment, cwd=root, stdout=log, stderr=subprocess.STDOUT)
            try:
                if label == "window" and args.window_helper is not None:
                    activate_owned_window(process, args.window_helper.resolve(), binary,
                                          output / "window-focus.json")
                code = process.wait(timeout=180)
            finally:
                if process.poll() is None: process.kill(); process.wait()
        receipt["checks"].append(dict(name=label, exitCode=code, reaped=True))
        if code: raise RuntimeError(label + " failed")
    receipt["status"] = "pass"
except BaseException as error: receipt.update(status="fail", error=repr(error)); raise
finally:
    (output / "result.json").write_text(json.dumps(receipt, indent=2))
    subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
