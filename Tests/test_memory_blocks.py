"""Generated correctness evidence only; no GUI or native performance claims."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import memory_block_evidence as blocks
import memory_parity_evidence as evidence
import parity_gate
from test_memory_bench import RawMemoryEvidenceTests
from test_memory_history_phase import build_phase_fixture


class MemoryBlockTests(unittest.TestCase):
    def test_checkpoint_replay_preserves_prefix_and_rejects_raw_mutation(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve(); (root / 'checkpoints').mkdir()
            episode = root / 'episodes/episode-01'; episode.mkdir(parents=True)
            data = episode / 'memory-block-00'; data.mkdir(); (data / 'generated').write_text('invented counters')
            campaign = dict(kind=blocks.KIND, selectionRule=blocks.RULE, blocks=6, nativeLaunches=36,
                            measuredSamples=216, expectedMetrics=9, performanceSamplesInherited=False, pins={})
            blocks.write_new(root / 'campaign.json', campaign)
            case = dict(workload='memory-block-00', output=str(data), blockIndex=0)
            plan = dict(campaign=str(root), campaignSHA256=blocks.sha(root / 'campaign.json'),
                        cases=[case], outerGuardSHA256='a'*64)
            blocks.write_new(episode / 'plan.json', plan)
            plan_hash = blocks.sha(episode / 'plan.json')
            ready = dict(status='ready', sourceSHA256='a'*64, planSHA256=plan_hash,
                         allThreeAgentsConfirmedInactive=True, activeRelevantProcesses=[], finishedUnixNS=100)
            blocks.write_new(episode / 'preflight.json', ready)
            binding = dict(planSHA256=plan_hash, createdUnixNS=300)
            for key, status in (('preflight', 'ready'), ('pointerSetup', 'prelaunch-pointer-position-verified'),
                                ('visibility', 'external-visibility-change-observed')):
                path = episode / (key + '.json')
                if key != 'preflight':
                    blocks.write_new(path, dict(status=status, planSHA256=plan_hash, finishedUnixNS=200,
                        preflightSHA256=blocks.sha(episode / 'preflight.json'), ownedProcessReaped=True,
                        humanInputDetected=False))
                binding.update({key:str(path), key+'SHA256':blocks.sha(path)})
            blocks.write_new(episode / 'launch-binding.json', binding)
            initial = dict(clock='generated', idleSeconds=400, hardwareIdleSeconds=400,
                           sessionReadFinishedMonotonicNS=1_000_000_000)
            activity = dict(clock='generated', idleSeconds=401, returned=False,
                            readStartedMonotonicNS=2_000_000_000, readFinishedMonotonicNS=2_000_000_100,
                            phase='checkpoint-memory-block-00')
            (episode / 'hardware-idle.jsonl').write_text(json.dumps(activity)+'\n')
            audit = dict(files=blocks.inventory(data), measuredSamples=36, warmups=0)
            audit_path = episode / 'memory-block-00-raw-audit.json'; blocks.write_new(audit_path, audit)
            item = dict(workload='memory-block-00', status='complete', exitCode=0, controllerReaped=True,
                        measuredSamples=36, warmups=0, auditSHA256=blocks.sha(audit_path))
            execution = dict(planSHA256=plan_hash, initialActivity=initial, cases=[item])
            generated = ([], {'generated':True}, 1_100_000_000, 1_900_000_000)
            with patch.object(blocks, 'audit_block', return_value=generated):
                checksum = blocks.seal_block(episode, plan, execution, item, activity)
                item['checkpointSHA256'] = checksum
                blocks.write_new(episode / 'execution.json', execution)
                seal = root / 'checkpoints/00.json'
                self.assertEqual(blocks.validate_checkpoint(root, campaign, seal)[1], {'generated':True})
                with (episode / 'hardware-idle.jsonl').open('a') as stream:
                    stream.write(json.dumps(dict(activity, returned=True, idleSeconds=0))+'\n')
                blocks.validate_checkpoint(root, campaign, seal)
                (data / 'generated').write_text('changed counters')
                with self.assertRaisesRegex(ValueError, 'raw files changed'):
                    blocks.validate_checkpoint(root, campaign, seal)
                (data / 'generated').write_text('invented counters')
                (episode / 'hardware-idle.jsonl').write_text(json.dumps(dict(activity, idleSeconds=0))+'\n')
                with self.assertRaises(ValueError): blocks.validate_checkpoint(root, campaign, seal)

    def test_six_segments_match_one_full_counterbalanced_run(self):
        fixture = RawMemoryEvidenceTests()
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            full = root / "full"; full.mkdir()
            fixture.fixture(full, schema=3, blocks=6)
            expected = evidence.load_memory_evidence(full, fixture.pins)
            segments = []
            for index in range(6):
                part = root / str(index); part.mkdir()
                fixture.fixture(part, schema=3, blocks=1, block_start=index)
                segments.append(evidence.load_memory_evidence(part, fixture.pins))
            combined = blocks.merge_items(segments, full)
            self.assertEqual(combined, expected)
            planned = sum((evidence.expected_order(list(evidence.CASES), 1, "cmdy", i)
                           for i in range(6)), [])
            self.assertEqual(planned, evidence.expected_order(list(evidence.CASES), 6, "cmdy"))
            self.assertEqual(len(planned), 36)
            checkpoint_root = root / 'campaign'; checkpoint_root.mkdir()
            blocks.write_new(checkpoint_root / 'manifest.json', dict(benchmarkKind=blocks.KIND))
            policy = blocks.read(Path(__file__).with_name('parity-policy.json'))
            monolithic_gate = parity_gate.evaluate([full], policy, fixture.pins)
            with patch.object(blocks, 'load_memory_blocks', return_value=combined) as reader:
                self.assertEqual(parity_gate.evaluate([checkpoint_root], policy, fixture.pins), monolithic_gate)
                reader.assert_called_once_with(checkpoint_root, fixture.pins)

    def test_cross_block_binding_and_process_reuse_are_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            record = dict(block=0, position=0, case='primary-1000', terminal='cmdy',
                          samples=[dict(app=dict(pid=10, processStartTicks=100),
                                        worker=dict(pid=11, processStartTicks=101))])
            run = root / 'runs/00-00-primary-1000-cmdy'; run.mkdir(parents=True)
            binding = dict(capability='generated-capability', nonce='generated-nonce',
                           temporaryDirectory='generated-temp', socketPath='generated-socket')
            blocks.write_new(root / 'records.json', [record])
            blocks.write_new(run / 'public-history-binding.json', binding)
            seen = set(); blocks.validate_fresh_owners(root, seen)
            with self.assertRaisesRegex(ValueError, 'reused across blocks'):
                blocks.validate_fresh_owners(root, seen)
            for role in ('app', 'worker'):
                key = (role, record['samples'][0][role]['pid'], record['samples'][0][role]['processStartTicks'])
                with self.subTest(role=role), self.assertRaises(ValueError):
                    blocks.validate_fresh_owners(root, {key})

    def test_global_last_block_preserves_visual_history_and_dsr(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            metadata, records, pins, _ = build_phase_fixture(root, blocks=1, block_start=5)
            items = evidence.load_memory_evidence(root, pins)
            self.assertEqual(len(items), 9)
            self.assertTrue(all(set(item["blocks"]) == {5} for item in items))
            self.assertTrue(all(record["drain"]["sequence"] == 5 for record in records))
            for offset in (-1, True, 20, 0):
                changed = deepcopy(metadata)
                changed["arguments"]["block_start"] = offset
                (root / "manifest.json").write_text(json.dumps(changed))
                with self.subTest(offset=offset), self.assertRaises(ValueError):
                    evidence.load_memory_evidence(root, pins)
            metadata["arguments"]["payload_marker"] = "f" * 16
            (root / "manifest.json").write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, "marker"):
                evidence.load_memory_evidence(root, pins)

    @staticmethod
    def groups():
        return [[dict(case=f"memory/{case}", kind="memory", profile="matched", power="AC Power",
                     path=str(block), blocks={block: {"cmdy": [10], "ghostty": [11]}})
                 for case in range(9)] for block in range(6)]

    def test_missing_duplicate_reordered_changed_blocks_fail_closed(self):
        mutations = [lambda g: g.pop(), lambda g: g.reverse(),
                     lambda g: g[1].__setitem__(0, deepcopy(g[0][0])),
                     lambda g: g[0].pop(), lambda g: g[1][0].update(power="Battery Power"),
                     lambda g: g[1][0].update(profile="cmdy-defaults"),
                     lambda g: g[1][0].update(case="unregistered"),
                     lambda g: g[1][0].update(blocks={0: {"cmdy": [10], "ghostty": [11]}})]
        for index, mutate in enumerate(mutations):
            groups = self.groups(); mutate(groups)
            with self.subTest(index=index), self.assertRaises(ValueError):
                blocks.merge_items(groups, Path("generated"))

    def test_checkpoint_creation_is_atomic_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); path = root / "00.json"
            blocks.write_new(path, {"original": True})
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                blocks.write_new(path, {"replacement": True})
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(root.iterdir()), [path])

    def test_later_input_does_not_invalidate_sealed_quiet_prefix(self):
        initial = dict(clock="test", idleSeconds=400, hardwareIdleSeconds=400,
                       sessionReadFinishedMonotonicNS=1_000_000_000)
        first = dict(clock="test", idleSeconds=401, returned=False,
                     readStartedMonotonicNS=2_000_000_000, readFinishedMonotonicNS=2_000_000_100)
        later = dict(first, returned=True, idleSeconds=0, readStartedMonotonicNS=3_000_000_000,
                     readFinishedMonotonicNS=3_000_000_100)
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); path = root / "hardware-idle.jsonl"
            path.write_text(json.dumps(first) + "\n")
            original = blocks.activity_prefix(root, initial)
            with path.open("a") as stream: stream.write(json.dumps(later) + "\n")
            self.assertEqual(blocks.activity_prefix(root, initial, 1), original)
            with self.assertRaises(ValueError): blocks.activity_prefix(root, initial)
            for mutate in (lambda x: x.update(returned=True), lambda x: x.update(valid=False),
                           lambda x: x.update(idleSeconds=0), lambda x: x.update(idleSeconds=float("nan"))):
                changed = dict(first); mutate(changed)
                path.write_text(json.dumps(changed) + "\n")
                with self.assertRaises(ValueError): blocks.activity_prefix(root, initial, 1)

    def test_checkpoint_sequence_cannot_skip_a_block(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); (root / "checkpoints").mkdir()
            blocks.write_new(root / "checkpoints/01.json", {})
            with self.assertRaises(ValueError): blocks.checkpoint_paths(root)


if __name__ == "__main__":
    unittest.main()
