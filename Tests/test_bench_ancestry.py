"""Pure raw proof fixtures. No real process inspection or subprocess launches."""
from copy import deepcopy
import unittest
from bench_ancestry import validate_kernel_ancestry


def ancestry_fixture(app=None, worker=None, start=100, step=1):
    app = app or dict(pid=20, parentPID=10, uid=501, startSeconds=20, startMicroseconds=7, executable="/owned/app")
    worker = worker or dict(pid=40, parentPID=30, uid=501, startSeconds=40, startMicroseconds=7, executable="/owned/python3.13")
    def link(value):
        return {**{key: value[key] for key in ("pid", "parentPID", "uid", "startSeconds", "startMicroseconds")}, "realUID": value["uid"]}
    links = [link(worker)]
    if worker["parentPID"] != app["pid"]:
        links.append(dict(pid=worker["parentPID"], parentPID=app["pid"], uid=0, realUID=app["uid"], startSeconds=30, startMicroseconds=8))
    links.append(link(app))
    tick = start
    def observed(value):
        nonlocal tick
        before = tick; tick += step
        result = dict(api="sysctl(KERN_PROC_PID)", requestedPID=value["pid"], observedPID=value["pid"],
            result=0, errno=0, returnedBytes=648, expectedBytes=648, typedRecordComplete=True,
            startedTicks=before, finishedTicks=tick, state=2, flags=0, traced=False, link=deepcopy(value))
        result.update({key: item for key, item in value.items() if key != "pid"})
        tick += step
        return result
    first = [observed(value) for value in links]
    second = [observed(value) for value in reversed(links)]
    value = dict(schemaVersion=1, method="two-observations-of-exact-PID-kernel-parent-links", proven=True,
        atomicSnapshot=False, cleanupAuthority=False, expectedAppPID=app["pid"], expectedWorkerPID=worker["pid"],
        pinnedApp=deepcopy(app), pinnedWorker=deepcopy(worker), fullAppBefore=deepcopy(app), fullAppAfter=deepcopy(app),
        fullWorkerBefore=deepcopy(worker), fullWorkerAfter=deepcopy(worker), fullEndpointsBeforeExact=True,
        fullEndpointsAfterExact=True, everyParentAndLifetimeRepeatedExactly=True,
        startedTicks=start, finishedTicks=tick,
        firstWalk=dict(limit=32, reachedApp=True, stoppingReason="pinned-app-reached", observations=first),
        secondWalkReverse=second)
    return value, app, worker


class AncestryEvidenceTests(unittest.TestCase):
    def test_complete_root_intermediate_and_exact_non_shell_endpoint(self):
        value, app, worker = ancestry_fixture()
        self.assertEqual([row["pid"] for row in validate_kernel_ancestry(value, app, worker)], [40, 30, 20])
        self.assertEqual(worker["executable"], "/owned/python3.13")

    def test_direct_app_worker_and_sleep_run_state_change(self):
        _, app, worker = ancestry_fixture(); worker["parentPID"] = app["pid"]
        value, app, worker = ancestry_fixture(app, worker)
        for row in value["secondWalkReverse"]: row["state"] = 3
        self.assertEqual(len(validate_kernel_ancestry(value, app, worker)), 2)

    def test_proven_boolean_cannot_replace_missing_or_short_records(self):
        for mutate in (lambda v: v["firstWalk"]["observations"].pop(),
                lambda v: v["firstWalk"]["observations"][1].update(returnedBytes=647),
                lambda v: v["firstWalk"]["observations"][1].update(result=-1, errno=1),
                lambda v: v["secondWalkReverse"].pop(),
                lambda v: v["firstWalk"].update(limit=64)):
            value, app, worker = ancestry_fixture(); mutate(value)
            with self.assertRaises(ValueError): validate_kernel_ancestry(value, app, worker)

    def test_reused_pid_reparent_uid_and_wrong_reverse_order_rejected(self):
        for field in ("pid", "parentPID", "uid", "realUID", "startSeconds", "startMicroseconds"):
            value, app, worker = ancestry_fixture()
            record = value["secondWalkReverse"][1]
            record["link"][field] += 1
            if field == "pid": record["observedPID"] = record["requestedPID"] = record["link"][field]
            else: record[field] = record["link"][field]
            with self.subTest(field=field), self.assertRaises(ValueError): validate_kernel_ancestry(value, app, worker)
        value, app, worker = ancestry_fixture(); value["secondWalkReverse"].reverse()
        with self.assertRaises(ValueError): validate_kernel_ancestry(value, app, worker)

    def test_exact_full_endpoint_not_executable_prefix_or_uid_waiver(self):
        for name, field, changed in (("fullWorkerAfter", "executable", "/owned/python3.13-other"),
                ("fullWorkerBefore", "uid", 0), ("fullAppAfter", "startMicroseconds", 8),
                ("fullAppBefore", "parentPID", 11), ("pinnedWorker", "pid", 41)):
            value, app, worker = ancestry_fixture(); value[name][field] = changed
            with self.subTest(name=name, field=field), self.assertRaises(ValueError): validate_kernel_ancestry(value, app, worker)
        value, app, worker = ancestry_fixture(); worker["uid"] = 0
        with self.assertRaises(ValueError): validate_kernel_ancestry(value, app, worker)

    def test_cycle_wrong_pid_state_trace_and_uncovered_clock_fail(self):
        for changes in (dict(observedPID=999), dict(state=5), dict(state=True), dict(flags=0x800),
                        dict(traced=True), dict(finishedTicks=10_000)):
            value, app, worker = ancestry_fixture(); value["firstWalk"]["observations"][1].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError): validate_kernel_ancestry(value, app, worker)
        value, app, worker = ancestry_fixture()
        record=value["firstWalk"]["observations"][1];record["link"]["parentPID"]=40;record["parentPID"]=40
        with self.assertRaises(ValueError): validate_kernel_ancestry(value, app, worker)


if __name__ == "__main__": unittest.main()
