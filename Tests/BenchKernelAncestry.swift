// Shared private benchmark ownership proof, extracted from ancestry-diagnostic-01.
// No process table/argv/environment reads or signaling.
import Darwin
import Foundation

protocol PinnedAncestryEndpoint: Codable, Equatable {
    var pid: Int32 { get }
    var parentPID: UInt32 { get }
    var uid: UInt32 { get }
    var startSeconds: UInt64 { get }
    var startMicroseconds: UInt64 { get }
    var executable: String { get }
}
extension PinnedAncestryEndpoint {
    var ancestryEndpointEvidence: [String: Any] {
        ["pid": pid, "parentPID": parentPID, "uid": uid, "startSeconds": startSeconds,
         "startMicroseconds": startMicroseconds, "executable": executable]
    }
}

struct BenchKernelProcessLink: Codable, Equatable {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let realUID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    var evidence: [String: Any] {
        ["pid": pid, "parentPID": parentPID, "uid": uid, "realUID": realUID,
         "startSeconds": startSeconds, "startMicroseconds": startMicroseconds]
    }
    func matches<Endpoint: PinnedAncestryEndpoint>(_ full: Endpoint) -> Bool {
        pid == full.pid && parentPID > 0 && UInt32(parentPID) == full.parentPID
            && uid == full.uid && startSeconds == full.startSeconds
            && startMicroseconds == full.startMicroseconds
    }
}

struct BenchKernelProcessObservation {
    let link: BenchKernelProcessLink?
    let evidence: [String: Any]
}

func benchDecodeKernelObservation(_ info: kinfo_proc, requestedPID: Int32,
    result: Int32, bytes: Int, expectedBytes: Int, error: Int32,
    startedTicks: UInt64, finishedTicks: UInt64) -> BenchKernelProcessObservation {
    let exact = result == 0 && bytes == expectedBytes
    var evidence: [String: Any] = ["api": "sysctl(KERN_PROC_PID)",
        "requestedPID": requestedPID, "result": result, "returnedBytes": bytes,
        "expectedBytes": expectedBytes, "errno": error,
        "startedTicks": startedTicks, "finishedTicks": finishedTicks,
        "typedRecordComplete": exact]
    guard exact else {
        evidence["rejection"] = "syscall-failed-or-incomplete-typed-record"
        return BenchKernelProcessObservation(link: nil, evidence: evidence)
    }
    let process = info.kp_proc
    let extended = info.kp_eproc
    let start = process.p_un.__p_starttime
    evidence["observedPID"] = process.p_pid
    evidence["parentPID"] = extended.e_ppid
    evidence["uid"] = extended.e_ucred.cr_uid
    evidence["realUID"] = extended.e_pcred.p_ruid
    evidence["startSeconds"] = start.tv_sec
    evidence["startMicroseconds"] = start.tv_usec
    evidence["state"] = Int(process.p_stat)
    evidence["flags"] = process.p_flag
    evidence["traced"] = (process.p_flag & P_TRACED) != 0
    // The status may change between runnable and sleeping during the two
    // observations; neither is part of process lifetime. Reject unavailable,
    // stopped, zombie, newly-forking or traced records rather than guessing.
    guard requestedPID > 1, process.p_pid == requestedPID,
          extended.e_ppid > 0, start.tv_sec > 0,
          start.tv_usec >= 0 && start.tv_usec < 1_000_000,
          (Int(process.p_stat) == Int(SRUN) || Int(process.p_stat) == Int(SSLEEP)),
          (process.p_flag & P_TRACED) == 0 else {
        evidence["rejection"] = "invalid-pid-lifetime-or-process-state"
        return BenchKernelProcessObservation(link: nil, evidence: evidence)
    }
    let link = BenchKernelProcessLink(pid: process.p_pid, parentPID: extended.e_ppid,
        uid: extended.e_ucred.cr_uid, realUID: extended.e_pcred.p_ruid,
        startSeconds: UInt64(start.tv_sec), startMicroseconds: UInt64(start.tv_usec))
    evidence["link"] = link.evidence
    return BenchKernelProcessObservation(link: link, evidence: evidence)
}

func benchObserveKernelProcess(_ pid: Int32) -> BenchKernelProcessObservation {
    let started = mach_absolute_time()
    guard pid > 1 else {
        return BenchKernelProcessObservation(link: nil,
            evidence: ["requestedPID": pid, "rejection": "invalid-requested-pid",
                       "syscallPerformed": false])
    }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    let expected = MemoryLayout<kinfo_proc>.size
    var bytes = expected
    errno = 0
    let result = mib.withUnsafeMutableBufferPointer { name in
        withUnsafeMutablePointer(to: &info) {
            sysctl(name.baseAddress, UInt32(name.count), $0, &bytes, nil, 0)
        }
    }
    let error = result == 0 ? 0 : errno
    return benchDecodeKernelObservation(info, requestedPID: pid, result: result,
        bytes: bytes, expectedBytes: expected, error: error,
        startedTicks: started, finishedTicks: mach_absolute_time())
}

struct BenchKernelAncestryWalk {
    let links: [BenchKernelProcessLink]
    let reachedApp: Bool
    let evidence: [String: Any]
}

func benchWalkKernelAncestry(_ child: Int32, appPID: Int32, limit: Int = 32,
    lookup: (Int32) -> BenchKernelProcessObservation) -> BenchKernelAncestryWalk {
    precondition((1...32).contains(limit))
    var candidate = child
    var seen = Set<Int32>()
    var links: [BenchKernelProcessLink] = []
    var observations: [[String: Any]] = []
    var reason = "hop-limit"
    var reached = false
    for _ in 0..<limit {
        guard candidate > 1 else { reason = "system-root-or-invalid-pid"; break }
        guard seen.insert(candidate).inserted else { reason = "parent-cycle"; break }
        let value = lookup(candidate)
        observations.append(value.evidence)
        guard let link = value.link, link.pid == candidate else {
            reason = "complete-process-link-unavailable"; break
        }
        links.append(link)
        if link.pid == appPID {
            reached = true; reason = "pinned-app-reached"; break
        }
        candidate = link.parentPID
    }
    return BenchKernelAncestryWalk(links: links, reachedApp: reached,
        evidence: ["limit": limit, "observations": observations,
                   "reachedApp": reached, "stoppingReason": reason])
}

struct BenchKernelAncestryProof<Endpoint: PinnedAncestryEndpoint> {
    let app: Endpoint
    let worker: Endpoint
    let links: [BenchKernelProcessLink]
}
struct BenchKernelAncestryObservation<Endpoint: PinnedAncestryEndpoint> {
    let proof: BenchKernelAncestryProof<Endpoint>?
    let evidence: [String: Any]
}

func observeRepeatedKernelAncestry<Endpoint: PinnedAncestryEndpoint>(
    app: Endpoint, worker: Endpoint, expectedUID: UInt32,
    fullLookup: (Int32) -> Endpoint?,
    kernelLookup: (Int32) -> BenchKernelProcessObservation = benchObserveKernelProcess
) -> BenchKernelAncestryObservation<Endpoint> {
    let started = mach_absolute_time()
    var evidence: [String: Any] = ["schemaVersion": 1, "proven": false,
        "expectedAppPID": app.pid, "expectedWorkerPID": worker.pid,
        "pinnedApp": app.ancestryEndpointEvidence, "pinnedWorker": worker.ancestryEndpointEvidence,
        "method": "two-observations-of-exact-PID-kernel-parent-links",
        "atomicSnapshot": false, "cleanupAuthority": false, "startedTicks": started]
    func observed(_ proof: BenchKernelAncestryProof<Endpoint>?) -> BenchKernelAncestryObservation<Endpoint> {
        evidence["finishedTicks"] = mach_absolute_time()
        return BenchKernelAncestryObservation(proof: proof, evidence: evidence)
    }
    func stopped(_ reason: String) -> BenchKernelAncestryObservation<Endpoint> {
        evidence["rejection"] = reason
        return observed(nil)
    }
    let appBefore = fullLookup(app.pid), workerBefore = fullLookup(worker.pid)
    evidence["fullAppBefore"] = appBefore?.ancestryEndpointEvidence ?? [:]
    evidence["fullWorkerBefore"] = workerBefore?.ancestryEndpointEvidence ?? [:]
    guard app.pid > 1, worker.pid > 1, app.pid != worker.pid,
          app.uid == expectedUID, worker.uid == expectedUID,
          app.executable.hasPrefix("/"), worker.executable.hasPrefix("/"),
          appBefore == app, workerBefore == worker else {
        return stopped("full-same-user-endpoint-identities-not-exact")
    }
    // Equality above includes the complete pinned executable, never a shell
    // literal or directory prefix. Prefix checks only require absolute paths.
    evidence["fullEndpointsBeforeExact"] = true
    let first = benchWalkKernelAncestry(worker.pid, appPID: app.pid, lookup: kernelLookup)
    evidence["firstWalk"] = first.evidence
    guard first.reachedApp, first.links.first?.matches(worker) == true,
          first.links.last?.matches(app) == true else {
        return stopped("first-walk-does-not-match-pinned-endpoints")
    }
    var second: [[String: Any]] = []
    var secondExact = true
    for original in first.links.reversed() {
        let value = kernelLookup(original.pid)
        second.append(value.evidence)
        if value.link != original { secondExact = false }
    }
    evidence["secondWalkReverse"] = second
    evidence["everyParentAndLifetimeRepeatedExactly"] = secondExact
    guard secondExact else { return stopped("kernel-parent-or-process-lifetime-changed") }
    let appAfter = fullLookup(app.pid), workerAfter = fullLookup(worker.pid)
    evidence["fullAppAfter"] = appAfter?.ancestryEndpointEvidence ?? [:]
    evidence["fullWorkerAfter"] = workerAfter?.ancestryEndpointEvidence ?? [:]
    let exact = appAfter == app && workerAfter == worker
    evidence["fullEndpointsAfterExact"] = exact
    guard exact else { return stopped("full-endpoint-identity-changed") }
    evidence["proven"] = true
    evidence["note"] = "Repeated coherent parent/lifetime evidence, not an atomic process-tree snapshot. No signaling authority is granted."
    return observed(BenchKernelAncestryProof(app: app, worker: worker, links: first.links))
}
