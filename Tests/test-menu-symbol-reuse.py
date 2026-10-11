#!/usr/bin/env python3
"""Headless pixel/ownership regression for the real AppKit menu image factory."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New directory for retained evidence")
    args = parser.parse_args()
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix="cmdy-menu-symbols-"))
    sources = [ROOT / "App/MenuUtilities.swift", ROOT / "Tests/MenuSymbolReuse.swift", Path(__file__).resolve()]
    inputs = {str(path.relative_to(ROOT)): sha(path) for path in sources}
    production = sources[0].read_text()
    # Exercise every rule's symbol, both default branches, and an unknown name.
    symbols = sorted(set(re.findall(r'\("[^"]+", "([^"]+)"\)', production))
                     | set(re.findall(r'return "([^"]+)"', production))
                     | {"list.bullet", "command", "does.not.exist.cmdy.symbol"})
    (output / "symbols.json").write_text(json.dumps(symbols) + "\n")
    combined = output / "fixture.swift"
    combined.write_text(production + "\n" + sources[1].read_text())
    binary = output / "fixture"
    commands = [
        ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-framework", "AppKit",
         str(combined), "-o", str(binary)],
        [str(binary), str(output / "symbols.json")],
    ]
    executions = []
    for label, argv in zip(("compile", "fixture"), commands):
        started = time.time_ns()
        with (output / f"{label}.stdout").open("wb") as stdout, (output / f"{label}.stderr").open("wb") as stderr:
            process = subprocess.Popen(argv, cwd=ROOT, stdout=stdout, stderr=stderr)
            try:
                code = process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                process.kill()
                code = process.wait()
        executions.append(dict(label=label, argv=argv, pid=process.pid, exitCode=code,
                               reaped=True, startedUnixNS=started, finishedUnixNS=time.time_ns()))
        (output / "execution.json").write_text(json.dumps(executions, indent=2) + "\n")
        if code:
            raise SystemExit(f"{label} failed ({code}); see {output / (label + '.stderr')}")
    expected = f"MENU_SYMBOL_REUSE_PASS symbols={len(symbols)} exactPixelComparisons={len(symbols) * 5 + 1} independentMetadata={len(symbols)} fallbackRequests=200"
    assert (output / "fixture.stdout").read_text().strip() == expected
    assert inputs == {str(path.relative_to(ROOT)): sha(path) for path in sources}, "source changed during test"
    result = dict(status="pass", symbols=len(symbols), exactPixelComparisons=len(symbols) * 5 + 1,
                  independentMetadata=len(symbols), fallbackRequests=200, cacheBound=128,
                  sources=inputs, nativeWindows=0, systemInputPosted=False, performanceAdmission=False,
                  artifacts={path.name: sha(path) for path in sorted(output.iterdir()) if path.is_file()})
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(expected)
    print(f"Evidence: {output}")


if __name__ == "__main__":
    main()
