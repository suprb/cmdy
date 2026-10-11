"""Generated-only file, receipt and private PTY tests; no native helper execution."""
from __future__ import annotations

from copy import deepcopy
import errno
import fcntl
import json
import base64
import os
from pathlib import Path
import pty
import select
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
from unittest.mock import patch

from history_export_controller import binding_config, control
from history_export_evidence import validate_file_proof, validate_transfer, validate_resize_pilot
from history_export_files import inventory, parse_owned_path, read_generated_export, read_retained_generated
from history_export_protocol import (CASES, FILE_LIMIT, PATH_LIMIT, digest, expectation,
    expected_bytes, memory_payload, preparation_bytes, validate_export_bytes)
from test_bench_ancestry import ancestry_fixture

HERE = Path(__file__).resolve().parent
NONCE = "0123456789abcdef0123456789abcdef"


def physical_export(spec):
    lines = expected_bytes(spec).split(b"\r\n")[:-1]
    return b"\n".join(part for row in lines for part in [row[i:i+120] for i in range(0, len(row), 120)]) + b"\n" * 37


class GeneratedHistoryTests(unittest.TestCase):
    def test_independent_worker_preserves_frozen_tooling_without_python_flags(self):
        from memory_public_history import VISUAL_MEMORY_TOOLING
        with tempfile.TemporaryDirectory() as temporary:
            tooling = Path(temporary)
            for name in VISUAL_MEMORY_TOOLING:
                (tooling / name).write_bytes((HERE / name).read_bytes())
            before = {path.name for path in tooling.iterdir()}
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith("PYTHON")}
            result = subprocess.run(
                [str(Path(sys.executable).resolve()), "-S",
                 str(tooling / "history_export_worker.py"), "--help"],
                cwd=tooling, env=environment, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual({path.name for path in tooling.iterdir()}, before)

    def test_exact_original_resize_workload_and_both_export_wrap_forms(self):
        spec = expectation("resize", NONCE)
        self.assertEqual((spec["logicalRows"], spec["logicalColumns"], spec["generatedBytes"]), (1000,145,147000))
        self.assertEqual(validate_export_bytes(expected_bytes(spec), spec)["wrappedLogicalRows"], 0)
        result = validate_export_bytes(physical_export(spec), spec)
        self.assertEqual((result["wrappedLogicalRows"], result["physicalContentRows"]), (1000,2000))

    def test_memory_complete_counts_and_exact_canonical_payloads(self):
        for case, count in (("primary-1000",1000),("primary-5000",5000),("alternate-continuous",35)):
            spec = expectation(case, NONCE)
            self.assertEqual(validate_export_bytes(expected_bytes(spec), spec)["logicalRows"], count)
            self.assertEqual(spec["logicalColumns"],76)
            self.assertEqual(len(memory_payload(spec)), spec["generatedBytes"] + (3_000_015 if case == "alternate-continuous" else 0))

    def test_missing_duplicate_reordered_corrupt_and_pruned_rows_fail(self):
        spec = expectation("resize", NONCE); rows = expected_bytes(spec).split(b"\r\n")[:-1]
        examples = [rows[1:], rows[:-1], rows[:50]+rows[49:], [rows[1],rows[0]]+rows[2:],
                    rows[:500]+[rows[500][:-1]+b"!"]+rows[501:], rows[:400]+[b""]+rows[400:]]
        for changed in examples:
            with self.subTest(rows=len(changed)), self.assertRaises(ValueError):
                validate_export_bytes(b"\n".join(changed)+b"\n",spec)

    def test_unregistered_wrap_repair_nonce_control_and_padding_fail(self):
        spec = expectation("resize", NONCE); raw = expected_bytes(spec)
        bad = [raw[:80]+b"\n"+raw[80:],raw.replace(NONCE.encode(),b"f"*32),raw+b"not ours",
               raw+b"\x1b[0m",raw+b"\0",raw+b"\xff",b"\n"*100000, raw.replace(b"\r\n",b"\r")]
        for value in bad:
            with self.assertRaises(ValueError): validate_export_bytes(value,spec)

    def test_only_declared_trailing_spaces_and_outer_empty_rows_normalize(self):
        spec=expectation("primary-1000",NONCE); raw=expected_bytes(spec)
        a=validate_export_bytes(raw,spec); b=validate_export_bytes(b"\n"+raw.replace(b"\r\n",b"  \r\n")+b"\n",spec)
        self.assertEqual(a["normalizedSHA256"],b["normalizedSHA256"])
        wrong=dict(spec,logicalRows=999)
        with self.assertRaises(ValueError): validate_export_bytes(raw,wrong)

    def test_public_config_exact_binding_and_no_duplicate_override(self):
        value=binding_config("font-family = Menlo\nfont-size = 14\n")
        self.assertTrue(value.endswith("keybind = ctrl+shift+enter=write_scrollback_file:paste\n"))
        with self.assertRaises(ValueError): binding_config(value)


class ExportFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix="cmdy-history-test-",dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup);self.root=Path(self.temporary.name)
        self.exports=self.root/"exports";self.exports.mkdir(mode=0o700)
        self.spec=expectation("resize",NONCE);self.raw=physical_export(self.spec)
        self.before=inventory(self.exports);self.path=self.exports/"owned.txt"

    def create(self, data=None, mode=0o600):
        self.path.write_bytes(self.raw if data is None else data);self.path.chmod(mode)

    def read(self):
        return read_generated_export(str(self.path).encode(),self.exports,self.before,self.spec,self.root/"retained.bin")

    def test_complete_private_inode_retained_and_original_removed(self):
        self.create();proof=self.read()
        self.assertEqual(validate_file_proof(proof,(self.root/"retained.bin").read_bytes(),self.spec,self.exports)["logicalRows"],1000)
        self.assertFalse(self.path.exists());self.assertEqual(stat.S_IMODE((self.root/"retained.bin").stat().st_mode),0o600)

    def test_existing_inode_rejected_and_preserved(self):
        self.create();self.before=inventory(self.exports)
        with self.assertRaisesRegex(ValueError,"not-new"):self.read()
        self.assertEqual(self.path.read_bytes(),self.raw)

    def test_symlink_and_hardlink_rejected_without_following_or_deleting(self):
        other=self.root/"other";other.write_bytes(self.raw);other.chmod(0o600)
        self.path.symlink_to(other)
        with self.assertRaises(ValueError):self.read()
        self.assertTrue(self.path.is_symlink());self.path.unlink();os.link(other,self.path)
        with self.assertRaises(ValueError):self.read()
        self.assertTrue(other.exists());self.assertTrue(self.path.exists())

    def test_mode_size_and_unrecognized_content_never_retained(self):
        for data,mode in [(self.raw,0o644),(b"",0o600),(b"x"*(FILE_LIMIT+1),0o600),(b"unrecognized generated-window mistake",0o600)]:
            self.create(data,mode)
            with self.assertRaises(ValueError):self.read()
            self.assertFalse((self.root/"retained.bin").exists());self.path.unlink(missing_ok=True)

    def test_changed_during_read_is_rejected_and_modified_inode_preserved(self):
        self.create();original=os.read;changed=False
        def mutate(fd,count):
            nonlocal changed
            result=original(fd,count)
            if not changed:
                changed=True
                with self.path.open("ab") as stream:stream.write(b"changed")
            return result
        with patch("history_export_files.os.read",side_effect=mutate),self.assertRaisesRegex(ValueError,"changed-during-read"):
            self.read()
        self.assertTrue(self.path.exists());self.assertFalse((self.root/"retained.bin").exists())

    def test_path_bounds_quoting_newlines_empty_components_and_traversal_fail_without_echo(self):
        good=str(self.path).encode();self.assertEqual(parse_owned_path(good,self.exports),"owned.txt")
        for bad in [b"/outside/secret",good+b"\n",b"'"+good+b"'",good+b"\0",good+b"//x",
                    str(self.exports/".."/"outside").encode(),b"x"*(PATH_LIMIT+1),b"\x1b[200~"+good+b"\x1b[201~"]:
            with self.assertRaises(ValueError) as context:parse_owned_path(bad,self.exports)
            self.assertNotIn("secret",str(context.exception));self.assertNotIn(str(self.path),str(context.exception))

    def test_urlsafe_base64_export_components_accept_every_initial_character(self):
        alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        for first in alphabet:
            component = first + "A" * 21
            for relative in (component, component + "/ghostty.txt"):
                with self.subTest(relative=relative):
                    self.assertEqual(parse_owned_path(
                        str(self.exports / relative).encode(), self.exports), relative)

    def test_dash_and_underscore_nested_exports_keep_full_inode_and_content_validation(self):
        for first in ("-", "_"):
            with self.subTest(first=first):
                exports = self.root / (first + "exports"); exports.mkdir(mode=0o700)
                before = inventory(exports)
                nested = exports / (first + "A" * 21); nested.mkdir(mode=0o700)
                source = nested / "ghostty.txt"
                source.write_bytes(self.raw); source.chmod(0o600)
                retained = self.root / (first + "retained.bin")
                proof = read_generated_export(str(source).encode(), exports, before, self.spec, retained)
                validated = validate_file_proof(proof, retained.read_bytes(), self.spec, exports)
                self.assertEqual(validated["logicalRows"], 1000)
                self.assertEqual(proof["pathTraversal"], "descriptor-relative-nofollow")
                self.assertFalse(source.exists())

    def test_unrecognized_input_does_not_claim_a_path_or_open_any_directory(self):
        for raw in (b"@", b"2", b"\x00", b"\r", b"/outside/generated"):
            with self.subTest(raw=raw), patch("history_export_files.open_directory") as opened:
                with self.assertRaisesRegex(ValueError, "^input-does-not-match-owned-export-path$"):
                    read_generated_export(raw, self.exports, self.before, self.spec, self.root / "retained.bin")
                opened.assert_not_called()
                self.assertFalse((self.root / "retained.bin").exists())

    def test_directory_replacement_permissions_and_symlink_fail(self):
        self.create();self.exports.rename(self.root/"old");self.exports.mkdir(mode=0o700);self.create()
        with self.assertRaisesRegex(ValueError,"directory-identity-changed"):self.read()
        link=self.root/"link";link.symlink_to(self.exports)
        with self.assertRaises(OSError):inventory(link)
        self.exports.chmod(0o755)
        with self.assertRaisesRegex(ValueError,"not-private"):inventory(self.exports)

    def test_independent_file_validator_rejects_counts_modes_hashes_and_newness_forgery(self):
        self.create();proof=self.read()
        edits=[lambda x:x["validation"].update(logicalRows=999),lambda x:x["validation"].update(rawSHA256="0"*64),
               lambda x:x["opened"].update(mode=0o100644),lambda x:x["beforeInventory"]["identities"].append([x["opened"]["dev"],x["opened"]["ino"]]),
               lambda x:x["cleanup"].update(sourceUnlinked=False)]
        for edit in edits:
            value=deepcopy(proof);edit(value)
            with self.assertRaises(ValueError):validate_file_proof(value,self.raw,self.spec,self.exports)

    def test_retained_replay_is_private_generated_and_nofollow(self):
        path=self.root/"generated-export.bin";path.write_bytes(self.raw);path.chmod(0o600)
        self.assertEqual(read_retained_generated(path,self.spec),self.raw)
        path.chmod(0o644)
        with self.assertRaises(ValueError):read_retained_generated(path,self.spec)
        path.unlink();other=self.root/"original";other.write_bytes(self.raw);other.chmod(0o600);path.symlink_to(other)
        with self.assertRaises(OSError):read_retained_generated(path,self.spec)
        self.assertEqual(other.read_bytes(),self.raw)


class TransferEvidenceTests(unittest.TestCase):
    setUp = ExportFileTests.setUp
    create = ExportFileTests.create
    read = ExportFileTests.read
    def document(self):
        self.create();proof=self.read();ancestry,app,worker=ancestry_fixture()
        window=dict(identity=app,windowID=10,displayID=1,foregroundPID=app["pid"],occluded=False,
                    queriedTicks=200,bounds=dict(x=1,y=2,width=1000,height=600))
        owner=dict(identity=app,workerIdentity=worker,ancestry=ancestry,window=window,grid=dict(columns=120,rows=36),
                   ttyPath="/dev/ttys123",ttyDevice=7,workerTTYDevice=7,workerProcessGroup=40,workerForegroundGroup=40)
        native=dict(pid=app["pid"],workerPID=worker["pid"],ttyPath=owner["ttyPath"],nonce=NONCE,windowID=10,displayID=1)
        arm=dict(armedTicks=300,armedMonotonicNS=100,deadlineMonotonicNS=3000000100,beforeInventory=proof["beforeInventory"])
        proof.update(receiveStartedTicks=300,receiveCompletedTicks=1000,receiveStartedMonotonicNS=100,
                     receiveCompletedMonotonicNS=3000000200,receiveDeadlineMonotonicNS=3000000100,receiveWindowSeconds=3,
                     chunks=[dict(bytes=proof["pathBytes"],ticks=450,monotonicNS=200)])
        action=dict(ok=True,op="post-key",intendedAction="write_scrollback_file:paste",
                    actionInvocationVerified=False,shortcut="ctrl+shift+enter",keyCode=36,
                    modifierFlags=0x60000,eventTypes=["keyDown","keyUp"],autorepeat=0,
                    eventCount=2,targetPID=app["pid"],foregroundActivated=False,beforeTicks=400,betweenTicks=401,afterTicks=402,
                    beforeOwner=deepcopy(owner),afterOwner=deepcopy(owner))
        action["afterOwner"]["ancestry"]=ancestry_fixture(app,worker,start=403)[0]
        action["afterOwner"]["window"]["queriedTicks"]=450
        after=deepcopy(owner);after["ancestry"]=ancestry_fixture(app,worker,start=1001)[0];after["window"]["queriedTicks"]=1050
        return dict(schemaVersion=1,terminal="cmdy",expectation=self.spec,nativeSpec=native,
                    workerReady=dict(pid=worker["pid"],ttyPath=owner["ttyPath"],nonce=NONCE,temporaryDirectory=str(self.exports)),
                    workerArm=arm,action=action,export=proof,beforeOwner=deepcopy(owner),afterOwner=after)

    def test_joined_owning_processes_public_action_full_file_and_chunks(self):
        value=self.document();self.assertEqual(validate_transfer(value,self.raw)["status"],"valid-generated-file-transfer")

    def test_join_rejects_wrong_app_key_ancestry_window_tty_and_late_or_truncated_path(self):
        value=self.document()
        edits=[lambda x:x["action"].update(targetPID=999),lambda x:x["action"].update(keyCode=9),
               lambda x:x["action"].update(actionInvocationVerified=True),
               lambda x:x["action"].update(action="write_scrollback_file:paste"),
               lambda x:x["action"].update(modifierFlags=0),
               lambda x:x["action"].update(eventTypes=["keyUp","keyDown"]),
               lambda x:x["action"].update(beforeTicks=1),lambda x:x["workerArm"].update(deadlineMonotonicNS=999),
               lambda x:x["afterOwner"].update(workerTTYDevice=999),lambda x:x["afterOwner"]["window"].update(occluded=True),
               lambda x:x["afterOwner"]["ancestry"]["secondWalkReverse"].pop(),
               lambda x:x["export"]["chunks"][0].update(bytes=1),lambda x:x["export"]["chunks"][0].update(monotonicNS=4000000000)]
        for edit in edits:
            altered=deepcopy(value);edit(altered)
            with self.assertRaises(ValueError):validate_transfer(altered,self.raw)


def transfer_fixture(case="resize"):
    """Generated file plus synthetic native receipts, for independent reader tests."""
    fixture=TransferEvidenceTests("test_joined_owning_processes_public_action_full_file_and_chunks")
    fixture.setUp()
    try:
        fixture.spec=expectation(case,NONCE);fixture.raw=physical_export(fixture.spec)
        return fixture.document(), fixture.raw
    finally:fixture.doCleanups()


class ViewportEvidenceTests(unittest.TestCase):
    def fixture(self):
        from test_resize_calibration import discovery,rehash
        from resize_protocol import cell_classes_bytes
        document,raw=transfer_fixture()
        def view(owner,start,display,callback,after_ticks):
            found=discovery(bounds=owner["window"]["bounds"])
            evidence=json.loads(found["evidenceUTF8"])
            evidence.update(nonce=NONCE,sequence=0,displayTicks=display,window=deepcopy(owner["window"]))
            rehash(found,evidence)
            classes=cell_classes_bytes(NONCE,0,120,36)
            return dict(ok=True,op="observe",scope="complete-generated-cell-viewport-v2",streamStopped=True,
                        nonce=NONCE,sequence=0,captureStartedTicks=start,afterTicks=after_ticks,displayTicks=display,
                        callbackTicks=callback,discovery=found,cellClassesBase64=base64.b64encode(classes).decode(),
                        matchedCells=len(classes),cellClassesSHA256=digest(classes),beforeOwner=deepcopy(owner),afterOwner=deepcopy(owner),
                        statuses=[dict(status=0,displayTicks=display,callbackTicks=callback)])
        document["beforeViewport"]=view(document["beforeOwner"],210,220,230,0)
        document["afterViewport"]=view(document["afterOwner"],1060,1070,1080,1000)
        cleanup=dict(status="pass",pid=document["workerReady"]["pid"],nonce=NONCE,unexpectedInputBytes=0,
                     termiosRestored=True,fileFlagsRestored=True,terminalRestoreWritten=True,controlSocketRemoved=True)
        return document,raw,cleanup

    def test_complete_pixel_derived_stream_and_fresh_post_export_viewport(self):
        document,raw,cleanup=self.fixture()
        self.assertTrue(validate_resize_pilot(document,raw,cleanup)["viewportVerified"])

    def test_right_edge_interior_and_missing_observed_cells_fail_even_with_rehashed_stream(self):
        document,raw,cleanup=self.fixture()
        for index in (0,119,4320-1,3000):
            changed=deepcopy(document);after=changed["afterViewport"]
            cells=bytearray(base64.b64decode(after["cellClassesBase64"]));cells[index]=(cells[index]+1)%18
            after.update(cellClassesBase64=base64.b64encode(cells).decode(),cellClassesSHA256=digest(cells))
            with self.assertRaises(ValueError):validate_resize_pilot(changed,raw,cleanup)
        changed=deepcopy(document);changed["afterViewport"]["matchedCells"]-=1
        with self.assertRaises(ValueError):validate_resize_pilot(changed,raw,cleanup)

    def test_stale_frame_wrong_discovery_and_unfinished_cleanup_fail(self):
        document,raw,cleanup=self.fixture()
        for edit in [lambda x:x["afterViewport"].update(afterTicks=0),
                     lambda x:x["afterViewport"].update(displayTicks=500),
                     lambda x:x["afterViewport"]["statuses"][-1].update(status=1),
                     lambda x:x["beforeViewport"].update(callbackTicks=999)]:
            changed=deepcopy(document);edit(changed)
            with self.assertRaises(ValueError):validate_resize_pilot(changed,raw,cleanup)
        with self.assertRaises(ValueError):validate_resize_pilot(document,raw,dict(cleanup,termiosRestored=False))


class OwnedPTYTests(unittest.TestCase):
    def run_worker(self, case, *, drain=False, tooling=HERE, isolated=False, exporter=None, reject_outside=False,
                   wire_transform=None, pre_arm=None, expected_error=None, failure_observer=None, failed_export_unlinked=False,
                   verification_policy=None, run_verification=True, success_observer=None, reject_verification_reply=False,
                   phase_failure_observer=None, verification_boundary_factory=None):
        with tempfile.TemporaryDirectory(prefix="cmdy-history-pty-",dir="/private/tmp") as root_name:
            root=Path(root_name);exports=root/"exports";exports.mkdir(mode=0o700);control_dir=root/"socket";control_dir.mkdir(mode=0o700)
            fixture=root/"fixture";socket_path=control_dir/"control.sock";spec=expectation(case,NONCE)
            master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack("HHHH",36,120,0,0))
            launcher=([sys.executable,"-I","-B","-c",
                       "import sys; assert sys.flags.isolated; sys.path.insert(0,sys.argv.pop(1)); "
                       "from history_export_worker import main; raise SystemExit(main())",str(tooling)] if isolated
                      else [sys.executable,"-B",str(tooling/"history_export_worker.py")])
            args=[*launcher,"--output",str(fixture),"--temporary-directory",str(exports),
                  "--socket",str(socket_path),"--capability","f"*32,"--nonce",NONCE,"--case",case,"--timeout","20"]
            if drain:
                payload=root/"payload.bin";payload.write_bytes(memory_payload(spec));args.extend(["--payload",str(payload)])
            if verification_policy is not None: args.extend(["--verification-policy", verification_policy])
            environment=os.environ.copy();environment["TMPDIR"]=str(exports)+"/"
            if isolated:environment["PYTHONPATH"]=str(HERE) # -I must ignore the working checkout.
            process=subprocess.Popen(args,stdin=slave,stdout=slave,stderr=subprocess.PIPE,env=environment,cwd=tooling,close_fds=True)
            os.close(slave);done=threading.Event();emitted=bytearray();reader_error=[]
            def emulate():
                pending=bytearray()
                try:
                    while not done.is_set():
                        if not select.select([master],[],[],.05)[0]:continue
                        try:data=os.read(master,65536)
                        except OSError as error:
                            if error.errno==errno.EIO:return
                            raise
                        if not data:return
                        emitted.extend(data);pending.extend(data)
                        # The sole test-side PTY master emulates only the two
                        # exact generated DSR sequences offered by drain().
                        if drain:
                            import re
                            while b"\x1b[6n" in pending:
                                index=pending.index(b"\x1b[6n");prefix=bytes(pending[:index])
                                positions=list(re.finditer(rb"\x1b\[(\d+);(\d+)H",prefix))
                                answer=(b"\x1b["+positions[-1][1]+b";"+positions[-1][2]+b"R") if positions else b"\x1b[1;1R"
                                if reject_verification_reply and b"\x1b[36;1H" + b"\r\n" * 35 in prefix:
                                    answer = b"\x1b[35;1R"
                                os.write(master,answer);del pending[:index+4]
                        if len(pending)>4*1024*1024:raise RuntimeError("test-output-bound")
                except BaseException as error:reader_error.append(type(error).__name__)
            thread=threading.Thread(target=emulate,daemon=True);thread.start()
            observed_shape = None
            try:
                limit=time.monotonic()+5
                while not (fixture/"ready.json").exists() and time.monotonic()<limit:time.sleep(.01)
                ready=json.loads((fixture/"ready.json").read_text())
                self.assertFalse(ready["outputPostprocessingEnabled"])
                if drain:
                    reply=control(ready,"f"*32,"drain",sequence=3,timeout=5)
                    self.assertEqual(reply["payloadBytes"],len(memory_payload(spec)))
                    self.assertEqual(reply["responseHex"],reply["expectedResponseHex"])
                    self.assertEqual(ready["payloadSHA256"],digest(memory_payload(spec)))
                else:
                    reply=control(ready,"f"*32,"prepare")
                    self.assertEqual(reply["prepared"]["sha256"],digest(preparation_bytes(spec)))
                if verification_policy is not None and run_verification:
                    boundary=dict(kind="untimed-drain", finishedMonotonicNS=reply["finishedMonotonicNS"])
                    if verification_boundary_factory is not None: boundary=verification_boundary_factory(reply)
                    try: verified=control(ready,"f"*32,"verify-history",boundary=boundary)
                    except ValueError:
                        process.wait(timeout=5)
                        if phase_failure_observer is not None: phase_failure_observer(fixture, json.loads((fixture/'cleanup.json').read_text()))
                        raise
                    self.assertEqual(verified["mode"],"verified")
                if pre_arm is not None: pre_arm(spec, exports)
                armed=control(ready,"f"*32,"arm")
                if exporter is None:
                    path=exports/"export.txt";path.write_bytes(physical_export(spec));path.chmod(0o600)
                else:
                    path=exporter(spec, exports)
                raw=str(path).encode()
                if wire_transform is not None: raw=wire_transform(raw)
                middle=len(raw)//2
                os.write(master,raw[:middle]);time.sleep(.03);os.write(master,raw[middle:])
                if reject_outside or wire_transform is not None or expected_error is not None:
                    # A generated file in a different, also-owned directory is
                    # never authority to widen this worker's intake root.
                    self.assertEqual(process.wait(timeout=5),1,process.stderr.read().decode())
                    cleanup=json.loads((fixture/"cleanup.json").read_text())
                    self.assertEqual(cleanup["errorCode"], expected_error or
                                     ("input-does-not-match-owned-export-path" if reject_outside
                                      else "path-receipt-framing-unrecognized"))
                    self.assertEqual(cleanup["status"],"failed")
                    self.assertEqual(cleanup["inputBytesRetained"],0)
                    self.assertEqual(cleanup["unexpectedInputBytes"],0)
                    self.assertFalse((fixture/"generated-export.bin").exists())
                    self.assertFalse(socket_path.exists())
                    if failed_export_unlinked: self.assertFalse(path.exists())
                    else: self.assertEqual(path.read_bytes(),physical_export(spec))
                    if expected_error is None:
                        observed_shape=json.loads((fixture/"rejected-input-shape.json").read_text())
                        self.assertEqual(observed_shape["pid"],process.pid)
                        self.assertEqual(observed_shape["nonce"],NONCE)
                        self.assertEqual(sum(row["bytes"] for row in observed_shape["chunks"]),len(raw))
                        self.assertIs(cleanup["rejectedInputShapeRecorded"],True)
                    else:
                        self.assertFalse((fixture/"rejected-input-shape.json").exists())
                        self.assertIs(cleanup["rejectedInputShapeRecorded"],False)
                    for flag in ("termiosRestored","fileFlagsRestored","terminalRestoreWritten","controlSocketRemoved"):
                        self.assertIs(cleanup[flag], True)
                    if failure_observer is not None: failure_observer(fixture, cleanup, ready, armed)
                else:
                    limit=time.monotonic()+5
                    while time.monotonic()<limit:
                        received=control(ready,"f"*32,"status")
                        if received["mode"]=="received":break
                        time.sleep(.025)
                    self.assertEqual(received["mode"],"received")
                    self.assertEqual(received["proof"]["validation"]["logicalRows"],spec["logicalRows"])
                    validate_file_proof(received["proof"], (fixture/"generated-export.bin").read_bytes(), spec, exports)
                    self.assertEqual(sum(c["bytes"] for c in received["proof"]["chunks"]),len(raw))
                    self.assertFalse(path.exists());control(ready,"f"*32,"finish")
                    self.assertEqual(process.wait(timeout=5),0,process.stderr.read().decode())
                    cleanup=json.loads((fixture/"cleanup.json").read_text())
                    self.assertEqual(cleanup["status"],"pass");self.assertFalse(socket_path.exists())
                    self.assertEqual(cleanup["unexpectedInputBytes"],0)
                    if success_observer is not None: success_observer(fixture,cleanup,ready,armed,bytes(emitted))
            finally:
                if process.poll() is None:process.kill();process.wait()
                done.set();thread.join(timeout=2);os.close(master);process.stderr.close()
            self.assertFalse(thread.is_alive());self.assertFalse(reader_error)
            return observed_shape

    def test_resize_prepare_fragmented_raw_path_complete_read_and_exact_cleanup(self):self.run_worker("resize")
    def test_memory_drain_and_export_share_one_worker_tty_reader(self):self.run_worker("primary-1000",drain=True)

    def test_public_tooling_only_isolated_import_cli_and_both_owned_pty_paths(self):
        from history_export_build import PUBLIC_TOOLING
        with tempfile.TemporaryDirectory(prefix="cmdy-history-isolated-",dir="/private/tmp") as name:
            tooling=Path(name)
            for entry in PUBLIC_TOOLING:(tooling/entry).write_bytes((HERE/entry).read_bytes())
            probe=("import sys, pathlib, importlib; assert sys.flags.isolated; "
                   "root=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(root)); "
                   "assert sys.argv[2] not in sys.path; "
                   "names=[p.stem for p in root.glob('*.py')]; "
                   "modules=[importlib.import_module(name) for name in names]; "
                   "assert all(pathlib.Path(m.__file__).parent == root for m in modules); "
                   "import history_export_controller; raise SystemExit(history_export_controller.main([]))")
            result=subprocess.run([sys.executable,"-I","-B","-c",probe,str(tooling),str(HERE)],cwd=tooling,
                env=dict(os.environ,PYTHONPATH=str(HERE)),stdin=subprocess.DEVNULL,capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            self.assertEqual(json.loads(result.stdout)["status"],"prepared-tooling-only")
            self.assertFalse(json.loads(result.stdout)["nativePilotRun"])
            self.run_worker("resize",tooling=tooling,isolated=True)
            self.run_worker("primary-1000",drain=True,tooling=tooling,isolated=True)
            self.assertEqual(set(p.name for p in tooling.iterdir()),set(PUBLIC_TOOLING))


if __name__ == "__main__":unittest.main()
