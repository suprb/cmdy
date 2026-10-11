"""Two bounded public exports on the resize fixture's existing raw PTY reader.

This module never reads a PTY or posts a key. The worker supplies received bytes;
the existing descriptor-anchored intake recognizes only the generated corpus.
"""
from __future__ import annotations

import os
from pathlib import Path
import time

from history_export_files import inventory, open_directory, read_generated_export
from history_export_protocol import PATH_LIMIT, RECEIVE_SECONDS, resize_batch_expectation, require, row_split_metadata

SCOPE = "resize-same-lifetime-history-v1"


class Transfer:
    def __init__(self, directory, output, nonce, ticks, *, history_growth_guard=False):
        self.directory, self.output = Path(directory), Path(output)
        require(str(self.directory) == os.environ.get("TMPDIR", "").rstrip("/"),
                "resize-export-TMPDIR-differs")
        os.close(open_directory(self.directory))
        self.output.mkdir(mode=0o700, exist_ok=False)
        self.nonce = nonce
        require(type(history_growth_guard) is bool, "resize-growth-guard-type-differs")
        self.history_growth_guard = history_growth_guard
        self.ticks = ticks
        self.active = None
        self.completed = []
        self.received = bytearray()
        self.chunks = []
        self.failure_diagnostic = None

    def arm(self, phase, sequence):
        require(self.active is None and len(self.completed) < 2
                and phase == ("before" if not self.completed else "after"),
                "resize-export-phase-order-differs")
        require(type(sequence) is int and 0 <= sequence <= 252,
                "resize-export-sequence-outside-bound")
        before = inventory(self.directory)
        tick, now = int(self.ticks()), time.monotonic_ns()
        self.active = dict(phase=phase, sequence=sequence, armedTicks=tick,
            armedMonotonicNS=now, deadlineMonotonicNS=now + RECEIVE_SECONDS * 1_000_000_000,
            beforeInventory=before)
        self.received.clear(); self.chunks = []
        return self.active

    def receive(self, data):
        require(self.active is not None and isinstance(data, bytes) and bool(data)
                and time.monotonic_ns() < self.active["deadlineMonotonicNS"]
                and len(self.received) + len(data) <= PATH_LIMIT,
                "resize-export-unexpected-or-overlong-input")
        self.received.extend(data)
        self.chunks.append(dict(bytes=len(data), ticks=int(self.ticks()), monotonicNS=time.monotonic_ns()))

    def poll(self):
        if self.active is None or time.monotonic_ns() < self.active["deadlineMonotonicNS"]:
            return None
        arm = self.active
        expected = resize_batch_expectation(self.nonce, arm["phase"], history_growth_guard=self.history_growth_guard)
        directory = self.output / arm["phase"]
        directory.mkdir(mode=0o700, exist_ok=False)
        try:
            proof = read_generated_export(bytes(self.received), self.directory,
                arm["beforeInventory"], expected, directory / "generated-export.bin")
        except ValueError as failure:
            self.failure_diagnostic = row_split_metadata(failure)
            raise
        finally:
            self.received.clear()
        proof.update(receiveStartedTicks=arm["armedTicks"], receiveCompletedTicks=int(self.ticks()),
            receiveStartedMonotonicNS=arm["armedMonotonicNS"], receiveCompletedMonotonicNS=time.monotonic_ns(),
            receiveDeadlineMonotonicNS=arm["deadlineMonotonicNS"], receiveWindowSeconds=RECEIVE_SECONDS,
            chunks=self.chunks)
        value = dict(scope=SCOPE, phase=arm["phase"], sequence=arm["sequence"],
                     expectation=expected, arm=arm, proof=proof)
        self.completed.append(value)
        self.active = None; self.chunks = []
        return value

    def close(self):
        self.received.clear(); self.chunks = []

    def status(self):
        return dict(scope=SCOPE, active=self.active, completed=self.completed,
                    failureDiagnostic=self.failure_diagnostic)
