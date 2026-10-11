"""Generated archives only; no app launches, pointer movement or native evidence."""
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

import memory_parity_evidence as evidence
from test_memory_history_phase import build_phase_fixture
from test_memory_public_evidence import run_path, write


def pointer_fixture(root):
    metadata, records, pins, _ = build_phase_fixture(root)
    display = dict(x=0, y=0, width=2400, height=1600)
    metadata["displayFontPermissions"]["displays"][0]["bounds"] = display
    write(root/"manifest.json",metadata)
    previous = evidence.load_memory_evidence(root, pins)
    metadata["arguments"]["park_pointer_outside_window"] = True
    for record in records:
        owned = record["window"]["windows"][0]
        setup = record["setupFinishedMonotonicNS"]
        identity = record["historyVerification"]["transfer"]["beforeOwner"]["identity"]
        keys = ("pid", "uid", "startSeconds", "startMicroseconds", "executable")
        native = dict(ok=True, schemaVersion=1, kind="owned-window-pointer-setup",
            pid=identity["pid"], foregroundPID=identity["pid"], windowID=owned["windowID"],
            displayID=owned["displayID"], identity={key: identity[key] for key in keys},
            windowBounds=deepcopy(owned["bounds"]), displayBounds=deepcopy(display), clearancePoints=96,
            cursorBefore=dict(x=200,y=200), target=dict(x=2200,y=1400), cursorAfter=dict(x=2200,y=1400),
            warped=True, eventsPosted=False, windowMutated=False,
            beforeTicks=setup-80, afterTicks=setup-40, timebaseNumer=1, timebaseDenom=1)
        record["pointerSetup"] = dict(hostStartedMonotonicNS=setup-100,
            native=native,hostFinishedMonotonicNS=setup-20)
        run=run_path(root,record)
        write(run/"pointer-setup.json",record["pointerSetup"])
        write(run/"memory.json",record)
    write(root/"manifest.json",metadata);write(root/"records.json",records)
    return metadata, records, pins, previous


class PointerSetupTests(unittest.TestCase):
    def test_setup_does_not_change_any_metric(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root=Path(name);metadata,records,pins,previous=pointer_fixture(root)
            self.assertEqual(evidence.load_memory_evidence(root,pins),previous)

    def test_unplanned_or_missing_receipt_fails(self):
        for mutation in ("unplanned", "missing", "changed"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);metadata,records,pins,_=pointer_fixture(root)
                run=run_path(root,records[0])
                if mutation=="unplanned":
                    metadata["arguments"].pop("park_pointer_outside_window");write(root/"manifest.json",metadata)
                elif mutation=="missing": (run/"pointer-setup.json").unlink()
                else: write(run/"pointer-setup.json",{})
                with self.assertRaisesRegex(ValueError,"pointer setup"):
                    evidence.load_memory_evidence(root,pins)

    def test_identity_geometry_events_and_accounting_boundary_fail_closed(self):
        mutations=[lambda n:n.update(foregroundPID=999),lambda n:n.update(windowID=999),
            lambda n:n["identity"].update(startMicroseconds=99),lambda n:n.update(eventsPosted=True),
            lambda n:n.update(windowMutated=True),lambda n:n["target"].update(x=200,y=200),
            lambda n:n["target"].update(x=2399),lambda n:n["cursorAfter"].update(x=2202),
            lambda n:n.update(clearancePoints=1),lambda n:n["displayBounds"].update(width=3000),
            lambda n:n["target"].update(x=float("nan")),lambda n:n.update(timebaseDenom=2),
            lambda n:n.update(afterTicks=n["afterTicks"]+100000)]
        for index,mutation in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                root=Path(name);metadata,records,pins,_=pointer_fixture(root)
                record=records[0];mutation(record["pointerSetup"]["native"])
                run=run_path(root,record)
                write(run/"pointer-setup.json",record["pointerSetup"])
                write(run/"memory.json",record);write(root/"records.json",records)
                with self.assertRaisesRegex(ValueError,"pointer"):
                    evidence.load_memory_evidence(root,pins)


if __name__ == "__main__": unittest.main()
