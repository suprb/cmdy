#!/usr/bin/env python3
"""Only writes bounded generated payloads; never launches a process fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets


def numbered_rows(count: int, marker: str) -> bytes:
    if not 1 <= count <= 5000 or not re.fullmatch(r"[0-9a-f]{16}", marker):
        raise ValueError("bounded row count and unique 16-hex marker required")
    rows = []
    for index in range(count):
        prefix = f"CMDY_MEMORY_{marker}_ROW_{index:06d}|"
        rows.append((prefix + "A" * (76 - len(prefix))).encode("ascii"))
    return b"\r\n".join(rows) + b"\r\n"


def create_payloads(output: Path, marker: str | None = None) -> dict:
    marker = marker or secrets.token_hex(8)
    if not re.fullmatch(r"[0-9a-f]{16}", marker):
        raise ValueError("invalid marker")
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    alternate_rows = numbered_rows(35, marker)
    files = {"primary-1000.bin": numbered_rows(1000, marker),
             "primary-5000.bin": numbered_rows(5000, marker),
             "alternate-continuous.bin": b"\x1b[?1049h" + b"A" * 3_000_000
                 + b"\x1b[2J\x1b[H" + alternate_rows,
             "alternate-expected.bin": alternate_rows}
    records = {}
    for name, data in files.items():
        (output / name).write_bytes(data)
        records[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    cases = [
        {"name": "primary-1000", "payload": "primary-1000.bin", "expected": "primary-1000.bin",
         "expectedRows": 1000, "activeScreen": "primary", "priorBurstBytes": 0},
        {"name": "primary-5000", "payload": "primary-5000.bin", "expected": "primary-5000.bin",
         "expectedRows": 5000, "activeScreen": "primary", "priorBurstBytes": 0},
        {"name": "alternate-continuous", "payload": "alternate-continuous.bin",
         "expected": "alternate-expected.bin", "expectedRows": 35,
         "activeScreen": "alternate", "priorBurstBytes": 3_000_000},
    ]
    result = {"formatVersion": 1, "generatedMarker": marker, "rowColumns": 76,
              "files": records, "cases": cases,
              "normalization": "CRLF to LF; remove trailing spaces and leading/trailing empty rows only"}
    (output / "manifest.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    create_payloads(parser.parse_args().output)


if __name__ == "__main__":
    main()
