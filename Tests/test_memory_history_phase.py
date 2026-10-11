"""Invented memory counters + generated private files; never native admission."""
from copy import deepcopy
import json
import os
from pathlib import Path
import shlex
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import memory_parity_evidence as evidence
from memory_public_history import (PublicHistorySession, VISUAL_MEMORY_SCOPE,
    VISUAL_MEMORY_TRANSPORT, VISUAL_MEMORY_TOOLING)
from history_export_binding import install_binding
from history_export_evidence import validate_transfer, validate_resize_pilot
from history_export_phase import POLICY, contract, validate_phase, validate_phase_cleanup
from history_export_protocol import FILE_PROOF_SCOPE
from test_memory_public_evidence import (build_fixture, run_path, write, edit,
    transform_fields, PublicMemoryEvidenceTests)
from test_memory_bench import bench
from test_history_scope import file_window


def build_phase_fixture(root, profile="matched", blocks=2, block_start=0):
    """Upgrade only the post-sample transport; retain the original sample bytes."""
    metadata, records = build_fixture(root, profile, blocks=blocks, block_start=block_start)
    before = evidence.load_memory_evidence(root, PublicMemoryEvidenceTests.pins)
    generated = root / "generated-identities"; generated.mkdir(mode=0o700)
    paths, hashes = {}, {}
    for name in ("cmdy", "ghostty", "python3.13"):
        path = generated / name; path.write_bytes(("generated-unexecuted-" + name).encode()); path.chmod(0o600)
        paths["/owned/" + name] = str(path)
        hashes[name] = evidence.digest(path)
    def identity(key, value):
        if isinstance(value, str):
            if value in paths: return paths[value]
            if value == "a" * 64: return hashes["cmdy"]
            if value == "b" * 64: return hashes["ghostty"]
        return value
    for path in [root / "manifest.json", root / "records.json", *(root / "runs").rglob("*.json")]:
        edit(path, lambda value: transform_fields(value, identity))
    metadata = evidence.read(root / "manifest.json"); records = evidence.read(root / "records.json")
    interpreter = generated / "python3.13"
    metadata.update(schemaVersion=5, historyTransport=VISUAL_MEMORY_TRANSPORT, verificationPolicy=POLICY,
        verificationScope=VISUAL_MEMORY_SCOPE, childUmask=63,
        pythonExecutable=dict(path=str(interpreter), bytes=interpreter.stat().st_size, sha256=hashes["python3.13"]))
    metadata["arguments"]["post_sample_history"] = True
    for name in ("cmdy", "ghostty"): metadata["binaries"][name]["bytes"] = (generated/name).stat().st_size
    for name in VISUAL_MEMORY_TOOLING:
        path = root / "tooling" / name
        if not path.exists(): path.write_bytes(("synthetic schema5 source " + name).encode())
    metadata["toolingSHA256"] = {name: evidence.digest(root/"tooling"/name) for name in VISUAL_MEMORY_TOOLING}
    for record in records:
        run = run_path(root, record); fixture = run / "fixture"; audit = record["historyVerification"]
        case, terminal = record["case"], record["terminal"]
        binding = evidence.read(run/"public-history-binding.json"); launch = evidence.read(run/"launch.json")
        ready = evidence.read(fixture/"ready.json"); ready["verificationPolicy"] = POLICY
        # Old source fixture's command is exact text; write new argv explicitly.
        command = binding["worker"]; command[0] = str(interpreter); command.extend(("--verification-policy", POLICY))
        config = run / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
        config.write_text("\n".join(line for line in config.read_text().splitlines()
            if not line.startswith("keybind") and not line.startswith("scrollback-limit")) + "\n")
        shortcut = install_binding(terminal, config, case=case, policy=POLICY)
        binding.update(schemaVersion=3, transport=VISUAL_MEMORY_TRANSPORT, childUmask=63,
            verificationPolicy=POLICY, verificationScope=VISUAL_MEMORY_SCOPE,
            verificationContract=contract(case), workerExecutable=metadata["pythonExecutable"], shortcutBinding=shortcut)
        launch["arguments"][0] = metadata["binaries"][terminal]["path"]
        launch.update(childUmask=63, configSHA256=evidence.digest(config), fixtureCommand=command)
        (run/"zsh/.zshenv").write_text("unsetopt RCS\nexec " + shlex.join(command) + "\n")
        begin = audit["hostStartedMonotonicNS"]
        prepared = evidence.read(fixture/"prepared.json")
        phase = dict(schemaVersion=1, contract=contract(case), workerPID=audit["workerPID"], nonce=binding["nonce"],
            drainFinishedMonotonicNS=prepared["drain"]["finishedMonotonicNS"],
            boundary=dict(kind="all-memory-samples", finishedMonotonicNS=record["samples"][-1]["guardFinishedMonotonicNS"]),
            startedMonotonicNS=begin+60, startedTicks=begin+61, finishedTicks=begin+139, finishedMonotonicNS=begin+140,
            gridBefore=dict(columns=120,rows=36), gridAfter=dict(columns=120,rows=36),
            writtenBytes=contract(case)["payloadBytes"], responseHex=contract(case)["expectedReplyHex"])
        spec = evidence.read(run/"history-action-spec.json")
        initial = evidence.read(run/"history-inspect-spec.json")
        for value in (spec, initial): value.update(verificationPolicy=POLICY, exportCase=case, verificationScope=VISUAL_MEMORY_SCOPE)
        arm = evidence.read(fixture/"arm.json"); arm["verificationPhase"] = phase
        audit.update(schemaVersion=3, transport=VISUAL_MEMORY_TRANSPORT, verificationPolicy=POLICY,
            verificationScope=VISUAL_MEMORY_SCOPE, verificationPhase=phase)
        audit["arm"].update(arm=arm, verificationPhase=phase)
        audit["received"].update(arm=arm, verificationPhase=phase)
        audit["verificationReply"] = dict(audit["arm"], mode="verified", arm=None)
        record["drain"]["verificationPhase"] = None
        audit["action"]["intendedAction"] = contract(case)["action"]
        transfer = audit["transfer"]
        transfer.update(schemaVersion=4, nativeSpec=spec, workerReady=ready, workerArm=arm,
            workerPrepared=prepared, verificationPhase=phase, action=audit["action"])
        audit["transferValidation"] = validate_transfer(transfer, (fixture/"generated-export.bin").read_bytes())
        cleanup = evidence.read(fixture/"cleanup.json")
        cleanup["controls"].insert(1, dict(op="verify-history",ticks=begin+50))
        finish = evidence.read(run/"history-finish.json"); finish["reply"] = audit["received"]
        for relative, value in (("public-history-binding.json",binding), ("launch.json",launch),
                ("fixture/ready.json",ready), ("fixture/arm.json",arm), ("fixture/verification-phase.json",phase),
                ("history-inspect-spec.json",initial), ("history-action-spec.json",spec),
                ("history-verification.json",audit), ("fixture/cleanup.json",cleanup),
                ("history-finish.json",finish), ("history-finish-reply.json",audit["received"]), ("memory.json",record)):
            write(run/relative,value)
    write(root/"manifest.json",metadata); write(root/"records.json",records)
    return metadata, records, {name:hashes[name] for name in ("cmdy","ghostty")}, before


def reseal(root, records, record):
    """Preserve joins so the independent invariant, not a stale duplicate, fails."""
    run=run_path(root,record);audit=record["historyVerification"];transfer=audit["transfer"]
    transfer.update(action=audit["action"],beforeOwner=audit["before"]["owner"],afterOwner=audit["after"]["owner"])
    for relative,value in (("history-verification.json",audit),("memory.json",record),
            ("history-action-spec.json",transfer["nativeSpec"]), ("fixture/arm.json",transfer["workerArm"]),
            ("fixture/ready.json",transfer["workerReady"]), ("fixture/verification-phase.json",audit["verificationPhase"])):
        write(run/relative,value)
    write(root/"records.json",records)


class MemoryHistoryPhaseTests(unittest.TestCase):
    def test_complete_schema5_both_profiles_preserves_every_raw_metric(self):
        for profile in ("matched","cmdy-defaults"):
            with self.subTest(profile=profile),tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);metadata,records,pins,before=build_phase_fixture(root,profile)
                result=evidence.load_memory_evidence(root,pins)
                # Raw output includes pinned binaries; only those generated pins changed.
                old=json.dumps(before,sort_keys=True).replace("a"*64,pins["cmdy"]).replace("b"*64,pins["ghostty"])
                self.assertEqual(json.dumps(result,sort_keys=True),old);self.assertEqual(len(result),9)
                self.assertEqual({r["case"] for r in records},{"primary-1000","primary-5000","alternate-continuous"})

    def test_explicit_manifest_binding_and_child_umask_required(self):
        edits=[lambda m:m.update(schemaVersion=4),lambda m:m.update(historyTransport="public-case-file-paste-path-post-sample-v1"),
            lambda m:m.update(verificationScope="generated-file-transport-v2"),lambda m:m.update(childUmask=True),
            lambda m:m["arguments"].update(post_sample_history=False)]
        for change in edits:
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);m,r,p,_=build_phase_fixture(root);change(m);write(root/"manifest.json",m)
                with self.assertRaises(ValueError):evidence.load_memory_evidence(root,p)
        for value in (None,0,True,0o022):
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);m,r,p,_=build_phase_fixture(root);run=run_path(root,r[0])
                edit(run/"launch.json",lambda launch:launch.update(childUmask=value))
                with self.assertRaisesRegex(ValueError,"child umask"):evidence.load_memory_evidence(root,p)

    def test_file_only_schemas_cannot_borrow_visual_memory_manifest(self):
        for version in (2,3,4):
            with self.subTest(version=version),tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);m,records,p,_=build_phase_fixture(root);record=records[0];audit=record["historyVerification"]
                document=audit["transfer"];document["schemaVersion"]=version;document["nativeSpec"]["proofScope"]=FILE_PROOF_SCOPE
                for owner in (audit["before"]["owner"],audit["after"]["owner"],audit["action"]["beforeOwner"],audit["action"]["afterOwner"]):
                    owner["window"]=file_window(owner["window"])
                    owner["window"]["occluded"]=False # forged visibility never makes this visual proof
                reseal(root,records,record)
                with self.assertRaises(ValueError):evidence.load_memory_evidence(root,p)

    def test_occlusion_lifetime_grid_and_window_guards_remain_strict(self):
        changes=[lambda o:o["window"].update(occluded=True),lambda o:o["window"].update(foregroundPID=99999),
                 lambda o:o["grid"].update(rows=35),lambda o:o["identity"].update(startMicroseconds=12)]
        for change in changes:
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);m,records,p,_=build_phase_fixture(root);record=records[0];change(record["historyVerification"]["before"]["owner"])
                reseal(root,records,record)
                with self.assertRaises(ValueError):evidence.load_memory_evidence(root,p)

    def test_phase_overlap_forged_boundary_bytes_reply_and_missing_sample_reject(self):
        changes=[lambda r,v:v["boundary"].update(finishedMonotonicNS=r["samples"][-2]["guardFinishedMonotonicNS"]),
                 lambda r,v:v.update(startedMonotonicNS=r["samples"][-1]["guardStartedMonotonicNS"]),
                 lambda r,v:v.update(writtenBytes=80),lambda r,v:v.update(responseHex="1b5b33353b3152"),
                 lambda r,v:v["contract"].update(blankLines=34),lambda r,v:r["samples"].pop()]
        for change in changes:
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);m,records,p,_=build_phase_fixture(root);record=records[0]
                change(record,record["historyVerification"]["verificationPhase"]);reseal(root,records,record)
                with self.assertRaises(ValueError):evidence.load_memory_evidence(root,p)

    def test_missing_duplicate_reordered_control_or_failed_cleanup_reject(self):
        changes=[lambda c:c["controls"].pop(1),lambda c:c["controls"].insert(2,c["controls"][1]),
                 lambda c:c["controls"].reverse(),lambda c:c.update(termiosRestored=False)]
        for change in changes:
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);m,r,p,_=build_phase_fixture(root)
                edit(run_path(root,r[0])/"fixture/cleanup.json",change)
                with self.assertRaises(ValueError):evidence.load_memory_evidence(root,p)

    def test_canonical_app_and_worker_aliases_pass_but_changed_bytes_fail(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root=Path(name);m,records,p,_=build_phase_fixture(root)
            def alias(key,value):
                return value.replace("/private/tmp/","/tmp/",1) if key=="executable" and isinstance(value,str) else value
            for record in records:
                transform_fields(record["historyVerification"],alias);reseal(root,records,record)
                native=record["historyVerification"]["transfer"]["nativeSpec"]
                initial={k:v for k,v in native.items() if k not in ("expectedApp","expectedWorker")}
                write(run_path(root,record)/"history-inspect-spec.json",initial)
            self.assertEqual(len(evidence.load_memory_evidence(root,p)),9)
            executable=Path(m["pythonExecutable"]["path"]);old=executable.read_bytes();executable.write_bytes(old+b"changed")
            with self.assertRaisesRegex(ValueError,"pinned file"):evidence.load_memory_evidence(root,p)

    def test_wrong_case_action_store_or_claimed_invocation_reject(self):
        for claimed in (False,True):
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);m,records,p,_=build_phase_fixture(root);record=records[0]
                if claimed:record["historyVerification"]["action"]["actionInvocationVerified"]=True;reseal(root,records,record)
                else:
                    run=run_path(root,record);binding=evidence.read(run/"public-history-binding.json")
                    binding["shortcutBinding"]["intendedAction"]="write_screen_file:paste";write(run/"public-history-binding.json",binding)
                with self.assertRaises(ValueError):evidence.load_memory_evidence(root,p)

    def test_runner_optin_keeps_default_and_fixed_schedule(self):
        parser=bench.parser();args=["--output","/owned/out","--cmdy-bin","/owned/cmdy","--window-helper","/owned/w", "--memory-helper","/owned/m","--history-helper","/owned/h"]
        self.assertFalse(parser.parse_args(args).post_sample_history)
        self.assertTrue(parser.parse_args(args+["--post-sample-history"]).post_sample_history)
        with patch.object(bench.sys,"platform","darwin"),patch.object(Path,"mkdir",side_effect=AssertionError("must reject before output")):
            with self.assertRaises(SystemExit):bench.main(args+["--post-sample-history","--after-seconds","0","5"])

    def test_new_transfer_cannot_authorize_resize(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root=Path(name);_,records,_,_=build_phase_fixture(root);record=records[0];run=run_path(root,record)
            with self.assertRaisesRegex(ValueError,"cannot.authorize.resize"):
                validate_resize_pilot(record["historyVerification"]["transfer"],(run/"fixture/generated-export.bin").read_bytes(),{})

    def test_strict_file_proof_complete_bytes_and_sample_clock_stay_required(self):
        changes=[lambda d:d["export"].update(schemaVersion=1),
                 lambda d:d["export"]["cleanup"].update(sourceUnlinked=False),
                 lambda d:d["export"]["opened"].update(mode=0o100644),
                 lambda d:d["export"]["ancestorChain"][0]["opened"].update(mode=0o040755)]
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root=Path(name);m,records,p,_=build_phase_fixture(root);record=records[0];run=run_path(root,record)
            document=record["historyVerification"]["transfer"];raw=(run/"fixture/generated-export.bin").read_bytes()
            for change in changes:
                wrong=deepcopy(document);change(wrong)
                with self.assertRaises(ValueError):validate_transfer(wrong,raw)
            with self.assertRaises(ValueError):validate_transfer(document,raw[:len(raw)//2])
            record["samples"][-1]["app"]["timebaseNumer"]=2
            reseal(root,records,record)
            with self.assertRaises(ValueError):evidence.load_memory_evidence(root,p)

    def test_nonunit_phase_and_sample_clock_mapping_preserves_raw_results(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root=Path(name);m,records,p,_=build_phase_fixture(root);expected=evidence.load_memory_evidence(root,p)
            def convert(key,value):
                if key.endswith("Ticks") or key=="ticks":return value//2
                if key=="timebaseNumer":return 2
                if key=="timebase":return dict(numer=2,denom=1)
                if key in ("nativeStartedMonotonicNS","nativeFinishedMonotonicNS"):return value//2*2
                return value
            for path in [root/"records.json",*(root/"runs").rglob("*.json")]:
                edit(path,lambda value:transform_fields(value,convert))
            self.assertEqual(evidence.load_memory_evidence(root,p),expected)

    def test_real_session_constructor_requires_explicit_visual_policy_and_same_child_umask(self):
        from competitive_bench import BenchOptions
        import subprocess
        for terminal in ("cmdy","ghostty"):
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name, \
                    patch.object(subprocess,"Popen",side_effect=AssertionError("constructor must not launch")):
                root=Path(name);python=root/"python";python.write_bytes(b"generated-unexecuted-interpreter")
                options=BenchOptions(root/"cmdy",root/"ghostty",tooling_dir=Path(__file__).parent)
                for options_delta in ({"child_umask":None},{"verification_policy":None},{"verification_scope":"wrong"}):
                    kwargs=dict(child_umask=63,verification_policy=POLICY,verification_scope=VISUAL_MEMORY_SCOPE);kwargs.update(options_delta)
                    with self.assertRaises((RuntimeError,ValueError)):
                        PublicHistorySession(options,root/"helper",terminal,root/"never-created","primary-1000",root/"payload","0"*16,python,**kwargs)
                public=PublicHistorySession(options,root/"helper",terminal,root/"run","alternate-continuous",root/"payload","0"*16,python,
                    child_umask=63,verification_policy=POLICY,verification_scope=VISUAL_MEMORY_SCOPE)
                try:
                    binding=evidence.read(root/"run/public-history-binding.json")
                    self.assertEqual(binding["schemaVersion"],3);self.assertEqual(binding["childUmask"],63)
                    self.assertEqual(public.session.child_umask,63)
                    self.assertEqual(binding["shortcutBinding"]["intendedAction"],"write_screen_file:paste")
                    self.assertEqual(binding["workerExecutable"]["sha256"],evidence.digest(python))
                finally:public.close()

    def test_session_verify_routes_visual_phase_without_file_scope_or_native_actions(self):
        for case in ("primary-1000","alternate-continuous"):
            with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);metadata,records,_,_=build_phase_fixture(root)
                record=next(r for r in records if r["case"]==case);run=run_path(root,record);audit=record["historyVerification"]
                public=object.__new__(PublicHistorySession);public.verification_policy=POLICY;public.verification_scope=VISUAL_MEMORY_SCOPE
                public.directory=run;public.fixture=run/"fixture";public.nonce=audit["expectation"]["nonce"];public.expected=audit["expectation"]
                public.session=SimpleNamespace(app_pid=audit["ownedPID"],terminal=record["terminal"],worker_identity=(audit["workerPID"],"invented"),
                    ready=audit["transfer"]["workerReady"],options=SimpleNamespace(**{r+"_bin":Path(metadata["binaries"][r]["path"]) for r in ("cmdy","ghostty")}))
                calls=[]
                def control(op,**kwargs):
                    calls.append(op)
                    if op=="verify-history":
                        self.assertEqual(kwargs["boundary"],audit["verificationPhase"]["boundary"])
                        return audit["verificationReply"]
                    return audit["arm"] if op=="arm" else audit["received"]
                public.control=control
                def native(argv):
                    spec=evidence.read(Path(argv[-1]));calls.append(argv[1])
                    self.assertNotIn("proofScope",spec);self.assertEqual(spec["verificationScope"],VISUAL_MEMORY_SCOPE)
                    if argv[1]=="post-key":return audit["action"]
                    return audit["before"] if len(calls)==1 else audit["after"]
                with patch("memory_public_history.time.perf_counter_ns",side_effect=[audit["hostStartedMonotonicNS"],audit["hostFinishedMonotonicNS"]]):
                    result=public.verify(Path("/generated-unexecuted-helper"),native,record["window"],(1,1),
                        verification_boundary=audit["verificationPhase"]["boundary"])
                self.assertEqual(calls,["inspect","verify-history","arm","post-key","status","inspect"])
                self.assertEqual(result,audit);self.assertFalse(result["action"]["actionInvocationVerified"])
                with self.assertRaisesRegex(RuntimeError,"cannot borrow file-only"):
                    public.verify(None,None,None,None,file_transport=True,verification_boundary={})


class MemoryPhasePrivatePTYTests(unittest.TestCase):
    def test_all_three_cases_use_six_sample_boundary_and_strict_complete_file_cleanup(self):
        import time
        from test_history_export import OwnedPTYTests
        from compare_history import timebase
        clock=timebase()
        labels=["matched-grid-before-settle","settled-idle-baseline","settled-idle-cpu-end","post-output-0s","post-output-1s","post-output-5s"]
        for case in ("primary-1000","primary-5000","alternate-continuous"):
            samples=[]
            def boundary(reply):
                for index,label in enumerate(labels):
                    start=time.perf_counter_ns();end=time.perf_counter_ns()
                    samples.append(dict(label=label,guardStartedMonotonicNS=start,guardFinishedMonotonicNS=end,
                        requestedOffsetSeconds=None if index<3 else (0,1,5)[index-3]))
                return dict(kind="all-memory-samples",finishedMonotonicNS=samples[-1]["guardFinishedMonotonicNS"])
            def observe(fixture,cleanup,ready,armed,emitted):
                phase=evidence.read(fixture/"verification-phase.json");prepared=evidence.read(fixture/"prepared.json")
                evidence.validate_post_sample_history_phase(samples,phase,prepared["expectation"],ready["pid"],prepared,clock)
                validate_phase_cleanup(cleanup,phase,armed["arm"])
                proof=evidence.read(fixture/"export.json");self.assertEqual(proof["schemaVersion"],2)
                self.assertEqual(proof["validation"]["logicalRows"],prepared["expectation"]["logicalRows"])
                self.assertTrue(all(proof["cleanup"].values()))
                write(fixture/"synthetic-sample-boundary.json",dict(purpose="generated-correctness-only-no-memory-counters-or-timing",timebase=clock,samples=samples))
            OwnedPTYTests.run_worker(self,case,drain=True,verification_policy=POLICY,
                verification_boundary_factory=boundary,success_observer=observe)


if __name__ == "__main__": unittest.main()
