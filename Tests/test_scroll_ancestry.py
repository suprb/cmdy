"""Shared proof plus original TTY checks are both required; no native calls."""
from copy import deepcopy
import unittest
from bench_ancestry import validate_kernel_ancestry
from scroll_parity_evidence import tty
from test_bench_ancestry import ancestry_fixture


class ScrollAncestryTests(unittest.TestCase):
    def fixture(self):
        proof, app, worker = ancestry_fixture(start=101)
        spec=dict(appPID=app["pid"], workerPID=worker["pid"], ttyPath="/dev/ttys999")
        record=dict(status="valid", appPID=app["pid"], workerPID=worker["pid"], ttyPath=spec["ttyPath"],
            processIdentityValid=True, workerIsDescendant=True, columns=120, rows=36, openResult=0,
            windowSizeResult=0, fstatResult=0, openedDeviceIsCharacter=True, processInfoExpectedBytes=100,
            processInfoResult=100, workerUID=501, observerUID=501, workerProcessGroupID=40,
            workerForegroundProcessGroupID=40, workerControllingDeviceID=1, openedDeviceID=1,
            externalTCGetPGRP=-1, externalTCGetPGRPErrno=25, startedTicks=100, finishedTicks=200,
            ancestry=proof)
        return record, spec, app, worker

    def test_root_intermediate_chain_with_all_original_tty_proofs(self):
        tty(*self.fixture())

    def test_proven_ancestry_cannot_waive_grid_device_or_foreground_guards(self):
        for key, value in (("columns",119), ("rows",35), ("openedDeviceID",2),
                           ("workerForegroundProcessGroupID",41), ("processIdentityValid",False)):
            args=self.fixture();args[0][key]=value
            with self.subTest(key=key), self.assertRaises(ValueError): tty(*args)

    def test_missing_stale_or_changed_chain_fails_before_sample_admission(self):
        for kind in ("missing", "stale", "changed"):
            args=self.fixture();value=args[0]
            if kind == "missing": del value["ancestry"]
            elif kind == "stale": value["startedTicks"]=150
            else: value["ancestry"]["fullWorkerAfter"]["executable"] += "-replaced"
            with self.subTest(kind=kind), self.assertRaises((ValueError,KeyError)): tty(*args)


if __name__ == "__main__": unittest.main()
