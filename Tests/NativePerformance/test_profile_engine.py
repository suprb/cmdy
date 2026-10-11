"""Pure probe evidence/mode checks; no processes, PTYs, sampling or clocks run."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from profile_engine import validate_sample, verify_inputs

def fixture(snapshots=True):
    payload=b"generated ASCII only";footer=b"\x1b[2;2H\x1b[6n";reply=b"\x1b[2;2R".hex()
    grid=dict(columns=120,rows=36)
    record=dict(footerHex=footer.hex(),expectedResponseHex=reply,responseHex=reply,elapsedNS=100,
        startedMonotonicNS=10,finishedMonotonicNS=110,gridBefore=grid,gridAfter=grid,payloadBytes=len(payload))
    stats=dict(bytesReceived=len(payload+footer),chunkSizes=[len(payload+footer)],contentChanges=1,
        responseHexes=[reply],columns=120,rows=36,terminationCount=0,cursorRow=1,cursorColumn=1,
        diagnosticsEnabled=False,snapshotMode=snapshots,snapshotCaptures=int(snapshots),
        receivedSHA256=hashlib.sha256(payload+footer).hexdigest())
    return record,stats,dict(grid=grid),payload

class ProbeEvidenceTests(unittest.TestCase):
    def test_default_on_and_explicit_off_accept_complete_generated_stream(self):
        validate_sample(*fixture(),0)
        validate_sample(*fixture(False),0,False)

    def test_wrong_hello_mode_cannot_be_hidden_in_drain_stats(self):
        for enabled in (False,True):
            with self.subTest(enabled=enabled),self.assertRaisesRegex(ValueError,"probe mode"):
                validate_sample(*fixture(enabled),0,not enabled)

    def test_off_mode_requires_zero_real_snapshot_captures(self):
        record,stats,ready,payload=fixture(False);stats["snapshotCaptures"]=1
        with self.assertRaisesRegex(ValueError,"snapshot accounting"):validate_sample(record,stats,ready,payload,0,False)

    def test_snapshot_count_is_bounded_and_not_boolean(self):
        for count in (True,-1,2):
            record,stats,ready,payload=fixture();stats["snapshotCaptures"]=count
            with self.subTest(count=count),self.assertRaisesRegex(ValueError,"snapshot accounting"):
                validate_sample(record,stats,ready,payload,0)

    def test_new_mode_does_not_relax_bytes_hash_dsr_or_lifecycle(self):
        for change in (dict(bytesReceived=1),dict(chunkSizes=[0]),dict(contentChanges=0),dict(receivedSHA256="0"*64),
                       dict(responseHexes=[]),dict(terminationCount=1),dict(cursorColumn=2)):
            record,stats,ready,payload=fixture(False);stats.update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):validate_sample(record,stats,ready,payload,0,False)

    def test_changed_frozen_source_and_binary_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/"generated.swift";binary=root/"generated-binary"
            source.write_bytes(b"inert source");binary.write_bytes(b"inert binary")
            sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
            record=dict(status="complete",diagnosticOnly=True,inputs={source.name:sha(source)},
                binaryPath=str(binary),binarySHA256=sha(binary))
            verify_inputs(root,record)
            source.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError,"input changed"):verify_inputs(root,record)
            record["inputs"][source.name]=sha(source);binary.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError,"binary changed"):verify_inputs(root,record)

if __name__=="__main__":unittest.main()
