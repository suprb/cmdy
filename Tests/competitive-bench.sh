#!/bin/bash
# Reproducible same-machine PTY/DSR drain comparison; this is not frame latency.
# Evidence is retained, including failures. See Tests/TERMINAL-BENCHMARKS.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/Tests/competitive_bench.py" "$@"
