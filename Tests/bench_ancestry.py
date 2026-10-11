"""Trusted raw checker for the shared repeated exact-PID kernel ancestry proof."""
from pathlib import Path

METHOD = "two-observations-of-exact-PID-kernel-parent-links"
# This adapter is pinned to the reviewed arm64 Darwin SDK/native diagnostic.
# A different ABI must be reviewed, not silently admitted by its own receipt.
KINFO_PROC_BYTES = 648
ENDPOINT_FIELDS = ("pid", "parentPID", "uid", "startSeconds", "startMicroseconds", "executable")
LINK_FIELDS = ("pid", "parentPID", "uid", "realUID", "startSeconds", "startMicroseconds")


def require(value, message):
    if not value: raise ValueError("ancestry: " + message)


def number(value, name, minimum=0, maximum=(1 << 63) - 1):
    require(type(value) is int and minimum <= value <= maximum, "invalid " + name)
    return value


def endpoint(value):
    result = {key: value[key] for key in ENDPOINT_FIELDS}
    number(result["pid"], "endpoint PID", 2, (1 << 31) - 1)
    number(result["parentPID"], "endpoint parent", 1, (1 << 31) - 1)
    number(result["uid"], "endpoint UID", maximum=(1 << 32) - 1)
    number(result["startSeconds"], "endpoint start", 1)
    number(result["startMicroseconds"], "endpoint microseconds", maximum=999_999)
    path = result["executable"]
    require(isinstance(path, str) and path.startswith("/") and "\0" not in path
            and ".." not in Path(path).parts, "missing exact endpoint executable")
    return result


def validate_kernel_ancestry(value, app, worker):
    """Reconstruct both walks and full endpoint bindings, never trust proven alone."""
    app, worker = endpoint(app), endpoint(worker)
    require(app["pid"] != worker["pid"] and app["uid"] == worker["uid"], "endpoints are not distinct and same-user")
    require(value["schemaVersion"] == 1 and value["method"] == METHOD
        and value["proven"] is True and value["atomicSnapshot"] is False
        and value["cleanupAuthority"] is False and not value.get("rejection"), "proof method or result differs")
    require(value["expectedAppPID"] == app["pid"] and value["expectedWorkerPID"] == worker["pid"], "wrong expected endpoints")
    for name in ("pinnedApp", "fullAppBefore", "fullAppAfter"):
        require(value[name] == app, "full pinned app changed")
    for name in ("pinnedWorker", "fullWorkerBefore", "fullWorkerAfter"):
        require(value[name] == worker, "full pinned worker changed")
    require(all(value[key] is True for key in ("fullEndpointsBeforeExact", "fullEndpointsAfterExact",
                "everyParentAndLifetimeRepeatedExactly")), "incomplete endpoint/repetition result")
    start = number(value["startedTicks"], "proof start", 1)
    end = number(value["finishedTicks"], "proof finish", start)
    walk = value["firstWalk"]
    require(walk["limit"] == 32 and walk["reachedApp"] is True
        and walk["stoppingReason"] == "pinned-app-reached", "first walk did not reach pinned app")
    first, second = walk["observations"], value["secondWalkReverse"]
    require(2 <= len(first) <= 32 and len(second) == len(first), "incomplete or unbounded walk")
    previous = start

    def decode(record):
        nonlocal previous
        before = number(record["startedTicks"], "syscall start", previous)
        previous = number(record["finishedTicks"], "syscall finish", before, end)
        require(record["api"] == "sysctl(KERN_PROC_PID)" and record["result"] == 0 and record["errno"] == 0
            and record["returnedBytes"] == record["expectedBytes"] == KINFO_PROC_BYTES
            and record["typedRecordComplete"] is True and not record.get("rejection"), "syscall/typed record incomplete")
        require(record["state"] in (2, 3) and type(record["state"]) is int and record["traced"] is False
            and type(record["flags"]) is int and (record["flags"] & 0x800) == 0,
            "unavailable, stopped, zombie or traced process")
        link = record["link"]
        require(set(link) == set(LINK_FIELDS), "missing link fields")
        number(link["pid"], "link PID", 2, (1 << 31) - 1)
        number(link["parentPID"], "link parent", 1, (1 << 31) - 1)
        for key in ("uid", "realUID"): number(link[key], key, maximum=(1 << 32) - 1)
        number(link["startSeconds"], "link start", 1)
        number(link["startMicroseconds"], "link microseconds", maximum=999_999)
        require(record["requestedPID"] == record["observedPID"] == link["pid"], "wrong returned/requested PID")
        require(all(record[key] == link[key] for key in LINK_FIELDS if key != "pid"), "decoded numeric link differs")
        return link

    links = [decode(record) for record in first]
    require(links[0]["pid"] == worker["pid"] and links[-1]["pid"] == app["pid"]
        and len({link["pid"] for link in links}) == len(links), "wrong endpoints or parent cycle")
    require(all(current["parentPID"] == parent["pid"] for current, parent in zip(links, links[1:])), "broken parent chain")
    for link, pinned in ((links[0], worker), (links[-1], app)):
        require(all(link[key] == pinned[key] for key in LINK_FIELDS if key != "realUID"), "kernel endpoint does not match full identity")
    require([decode(record) for record in second] == list(reversed(links)), "reverse reread changed parent/UID/lifetime/order")
    return links
