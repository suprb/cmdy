"""Public file-export transport for the memory recorder's sole raw-PTY reader."""
from __future__ import annotations

import json
from pathlib import Path
import socket
import tempfile
import time
import uuid

from competitive_bench import TerminalSession, atomic_json, process_identity, sha256
from history_export_build import PUBLIC_TOOLING
from history_export_binding import install_binding
from history_export_evidence import validate_transfer, VISUAL_MEMORY_SCOPE, VISUAL_MEMORY_TRANSPORT
from history_export_files import read_retained_generated
from history_export_protocol import ACTION, FILE_PROOF_SCOPE, SHORTCUT, expectation, validate_export_bytes
from history_export_phase import POLICY, contract, selected_action, validate_phase, validate_phase_cleanup

TRANSPORT = "public-scrollback-file-paste-path"
VERIFICATION_TRANSPORT = "public-case-file-paste-path-post-sample-v1"
MEMORY_TOOLING = tuple(dict.fromkeys(("competitive_bench.py", "TerminalBenchWindow.swift",
    "memory_bench.py", "TerminalMemorySnapshot.c", "memory_parity_evidence.py",
    "memory_public_history.py") + PUBLIC_TOOLING))
VISUAL_MEMORY_TOOLING = MEMORY_TOOLING + ("history_executable_identity.py",)


def require(value, message):
    if not value:
        raise RuntimeError(message)


class PublicHistorySession:
    def __init__(self, options, helper, terminal, directory, case, payload, marker, python, *, child_umask=None, verification_policy=None, verification_scope=None):
        selected_action(case if verification_policy is not None else None, verification_policy)
        require(verification_scope is None or verification_scope == VISUAL_MEMORY_SCOPE
                and verification_policy == POLICY and type(child_umask) is int and child_umask == 0o077,
                "visual memory phase requires explicit policy and child umask 63")
        self.verification_policy = verification_policy
        self.verification_scope = verification_scope
        self.export_directory = tempfile.TemporaryDirectory(prefix="cmdy-memory-export-", dir="/private/tmp")
        self.control_directory = tempfile.TemporaryDirectory(prefix="cmdy-memory-control-", dir="/private/tmp")
        self.socket_path = Path(self.control_directory.name) / "control.sock"
        self.capability = uuid.uuid4().hex
        self.nonce = marker + uuid.uuid4().hex[:16]
        self.expected = expectation(case, self.nonce)
        self.directory = Path(directory)
        self.fixture = self.directory / "fixture"
        self.session = None
        self.finished = False
        try:
            command = [str(python), "-S", str(options.tooling_dir / "history_export_worker.py"),
                "--output", str(self.fixture), "--temporary-directory", self.export_directory.name,
                "--socket", str(self.socket_path), "--capability", self.capability,
                "--nonce", self.nonce, "--case", case, "--payload", str(payload), "--timeout", "600"]
            if verification_policy is not None: command.extend(("--verification-policy", verification_policy))
            self.session = TerminalSession(options, helper, terminal, self.directory, (120, 36),
                                           fixture_command=command, ready_path=self.fixture / "ready.json", child_umask=child_umask)
            self.session.environment["TMPDIR"] = self.export_directory.name + "/"
            shortcut_binding = install_binding(terminal, self.session.config_path,
                case=case if verification_policy is not None else None, policy=verification_policy)
            binding = {
                "schemaVersion": 1, "transport": TRANSPORT, "capability": self.capability,
                "nonce": self.nonce, "expectation": self.expected,
                "temporaryDirectory": self.export_directory.name, "socketPath": str(self.socket_path),
                "worker": command, "workerSHA256": sha256(options.tooling_dir / "history_export_worker.py"),
                "shortcutBinding": shortcut_binding}
            if child_umask is not None: binding["childUmask"] = child_umask
            if verification_policy is not None:
                binding.update(schemaVersion=2, transport=VERIFICATION_TRANSPORT,
                    verificationPolicy=verification_policy, verificationContract=contract(case))
            if verification_scope is not None:
                binding.update(schemaVersion=3, transport=VISUAL_MEMORY_TRANSPORT,
                    verificationScope=verification_scope, workerExecutable={"path": str(python),
                        "sha256": sha256(python), "bytes": Path(python).stat().st_size})
            atomic_json(self.directory / "public-history-binding.json", binding)
        except BaseException:
            self.close()
            raise

    def control(self, operation, **arguments):
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(float(arguments.get("timeout", 10)) + 5)
            peer.connect(str(self.socket_path))
            peer.sendall(json.dumps({"op": operation, "capability": self.capability, **arguments}).encode() + b"\n")
            data = bytearray()
            while not data.endswith(b"\n"):
                chunk = peer.recv(65536)
                require(chunk and len(data) + len(chunk) <= 1024 * 1024, "invalid public fixture response")
                data.extend(chunk)
        result = json.loads(data)
        require(result.get("ok") is True and result.get("capability") == self.capability
                and result.get("pid") == self.session.worker_identity[0], "public fixture identity or operation failed")
        return result

    def drain(self, sequence, timeout):
        return self.control("drain", sequence=sequence, timeout=timeout)

    def verify(self, helper, native_json, layout, timebase, *, file_transport=False, verification_boundary=None):
        phase_enabled = self.verification_policy is not None
        visual_memory = getattr(self, "verification_scope", None) == VISUAL_MEMORY_SCOPE
        require(not visual_memory or phase_enabled and not file_transport,
                "visual memory phase cannot borrow file-only ownership")
        require(not phase_enabled or file_transport or visual_memory,
                "new verification phase has no qualified memory/visual admission")
        require(phase_enabled == (verification_boundary is not None), "explicit verification boundary required")
        session = self.session
        host_start = time.perf_counter_ns()
        window = layout["windows"][0]
        binary = session.options.cmdy_bin if session.terminal == "cmdy" else session.options.ghostty_bin
        spec = {"pid": session.app_pid, "workerPID": session.worker_identity[0],
            "ttyPath": session.ready["ttyPath"], "executableSHA256": sha256(binary), "nonce": self.nonce,
            "windowID": window["windowID"], "displayID": window["displayID"]}
        # Existing memory callers retain their strict schema-1 proof. Only the
        # explicit untimed file pilot opts into the nonvisual schema-2 scope.
        if file_transport: spec["proofScope"] = FILE_PROOF_SCOPE
        if phase_enabled: spec.update(verificationPolicy=self.verification_policy, exportCase=self.expected["case"])
        if visual_memory: spec["verificationScope"] = VISUAL_MEMORY_SCOPE
        initial_spec = self.directory / "history-inspect-spec.json"
        atomic_json(initial_spec, spec)
        before = native_json([str(helper), "inspect", "--spec", str(initial_spec)])
        spec.update(expectedApp=before["owner"]["identity"], expectedWorker=before["owner"]["workerIdentity"])
        spec_path = self.directory / "history-action-spec.json"
        atomic_json(spec_path, spec)
        phase_reply = None
        if phase_enabled:
            phase_reply = self.control("verify-history", boundary=verification_boundary)
            phase = json.loads((self.fixture / "verification-phase.json").read_text())
            require(phase_reply["verificationPhase"] == phase, "retained verification phase differs from worker")
            validate_phase(phase, self.expected, session.worker_identity[0], phase_reply["prepared"],
                boundary=verification_boundary, timebase=timebase)
        arm = self.control("arm")
        action = native_json([str(helper), "post-key", "--spec", str(spec_path)])
        deadline = time.monotonic() + 5
        while True:
            received = self.control("status")
            if received["mode"] == "received":
                break
            require(time.monotonic() < deadline, "public exported path was not received in the fixed window")
            time.sleep(0.05)
        after = native_json([str(helper), "inspect", "--spec", str(spec_path)])
        proof = json.loads((self.fixture / "export.json").read_text())
        require(received["proof"] == proof, "retained export differs from the sole reader's receipt")
        raw = read_retained_generated(self.fixture / "generated-export.bin", self.expected)
        validated = validate_export_bytes(raw, self.expected)
        require(validated == proof["validation"], "raw exported history differs from the generated expectation")
        transfer = {"schemaVersion": 4 if visual_memory else 3 if phase_enabled else 2 if file_transport else 1, "terminal": session.terminal, "expectation": self.expected,
            "nativeSpec": spec, "workerReady": session.ready, "workerArm": arm["arm"],
            "action": action, "export": proof, "beforeOwner": before["owner"], "afterOwner": after["owner"]}
        if phase_enabled: transfer.update(workerPrepared=phase_reply["prepared"], verificationPhase=phase)
        transfer_validation = validate_transfer(transfer, raw)
        numer, denom = timebase
        require(type(numer) is int and type(denom) is int and numer > 0 and denom > 0, "invalid native clock conversion")
        result = {"schemaVersion": 1, "transport": TRANSPORT, "ok": True,
            "ownedPID": session.app_pid, "workerPID": session.worker_identity[0],
            "expectation": self.expected, "before": before, "after": after, "arm": arm,
            "action": action, "received": received, "proof": proof,
            "transfer": transfer, "transferValidation": transfer_validation,
            "timebase": {"numer": numer, "denom": denom},
            "hostStartedMonotonicNS": host_start,
            "nativeStartedMonotonicNS": action["beforeTicks"] * numer // denom,
            "nativeFinishedMonotonicNS": proof["receiveCompletedTicks"] * numer // denom,
            "hostFinishedMonotonicNS": time.perf_counter_ns(),
            "expectedRows": self.expected["logicalRows"], "retainedRows": validated["logicalRows"],
            "normalizedSHA256": validated["normalizedSHA256"], "retainedRawFile": "fixture/generated-export.bin"}
        if phase_enabled:
            result.update(schemaVersion=2, transport=VERIFICATION_TRANSPORT,
                verificationPolicy=self.verification_policy, verificationPhase=phase, verificationReply=phase_reply)
        if visual_memory:
            result.update(schemaVersion=3, transport=VISUAL_MEMORY_TRANSPORT, verificationScope=VISUAL_MEMORY_SCOPE)
        atomic_json(self.directory / "history-verification.json", result)
        return result

    def finish(self):
        reply = self.control("finish")
        atomic_json(self.directory / "history-finish-reply.json", reply)
        pid, original = self.session.worker_identity
        started = time.perf_counter_ns()
        deadline = time.monotonic() + 5
        while process_identity(pid) == original and time.monotonic() < deadline:
            time.sleep(0.05)
        require(process_identity(pid) != original, "public history worker did not finish")
        atomic_json(self.directory / "history-finish.json", {"reply": reply, "workerExit": {
            "pid": pid, "startIdentity": original, "exited": True,
            "startedMonotonicNS": started, "finishedMonotonicNS": time.perf_counter_ns()}})
        cleanup = json.loads((self.fixture / "cleanup.json").read_text())
        require(cleanup.get("status") == "pass" and cleanup.get("pid") == pid
                and cleanup.get("nonce") == self.nonce and cleanup.get("reason") == "controller-finish"
                and cleanup.get("unexpectedInputBytes") == 0
                and all(cleanup.get(key) is True for key in ("termiosRestored", "fileFlagsRestored", "terminalRestoreWritten", "controlSocketRemoved")),
                "public history worker cleanup failed")
        if self.verification_policy is not None:
            validate_phase_cleanup(cleanup,
                json.loads((self.fixture / "verification-phase.json").read_text()),
                json.loads((self.fixture / "arm.json").read_text()))
        self.finished = True

    def close(self):
        try:
            if self.session is not None:
                self.session.close()
        finally:
            self.export_directory.cleanup()
            self.control_directory.cleanup()
