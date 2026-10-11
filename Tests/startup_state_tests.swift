// Synthetic clocks/identities only; never query a display or process.
import Foundation
import Darwin
import CoreGraphics

func startupStateTests(proof: StartupGridProof, alternate: StartupGridProof, checks: inout Int) throws {
    func fresh(_ pid: Int32, query: Int = 0, pidStatus: Int = 0, timeout: Int = 0,
               trusted: Bool = true) -> StartupAccessibilityFront {
        StartupAccessibilityFront(startedTicks: 10, finishedTicks: 10, queryStatus: query,
            pidStatus: pidStatus, timeoutStatus: timeout, trusted: trusted, pid: pid)
    }
    let good = fresh(123)
    try resizeRequire(StartupForegroundDiagnostic(before: good, cocoaPID: 999, cocoaTicks: 10,
        after: good, queriedTicks: 10).observedPID() == 123, "stale Cocoa overrode fresh keyboard-focus PID")
    checks += 1
    for bad in [fresh(999), fresh(-1), fresh(123, query: -25204), fresh(123, pidStatus: -25200),
                fresh(123, timeout: -25200), fresh(123, trusted: false)] {
        try resizeRequire(StartupForegroundDiagnostic(before: good, cocoaPID: 123, cocoaTicks: 10,
            after: bad, queriedTicks: 10).observedPID() == -1, "failed/mismatched AX bracket admitted foreground")
        checks += 1
    }
    try resizeRequire(StartupForegroundDiagnostic(before: good, cocoaPID: 123, cocoaTicks: 9,
        after: good, queriedTicks: 10).observedPID() == -1, "reversed query clocks admitted foreground")
    checks += 1
    let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
    let server = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
    try resizeRequire(scrollIsCaptureExcludedCursor(layer: cursorLevel, ownerExecutable: server)
        && !scrollIsCaptureExcludedCursor(layer: cursorLevel, ownerExecutable: "/generated/overlay")
        && !scrollIsCaptureExcludedCursor(layer: cursorLevel, ownerExecutable: nil)
        && !scrollIsCaptureExcludedCursor(layer: cursorLevel - 1, ownerExecutable: server),
        "only the kernel-resolved WindowServer cursor at its documented level may be excluded")
    checks += 4
    func expectFailure(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { print("PASS " + name); return }
        throw ResizeFailure("unexpected startup admission: " + name)
    }
    let app = ResizeProcessIdentity(pid: 123, parentPID: 100, uid: 501,
        startSeconds: 1, startMicroseconds: 2, executable: "/generated/app")
    let rect = ResizeBounds(x: 0, y: 0, width: 1400, height: 1000)
    func owner(_ tick: UInt64, id: UInt32 = 456) -> ResizeWindowProof {
        ResizeWindowProof(identity: app, windowID: id, displayID: 1, bounds: rect,
            foregroundPID: app.pid, occluded: false, queriedTicks: tick)
    }
    func frame(_ display: UInt64, callback: UInt64? = nil, proof: StartupGridProof? = nil,
               stage: String = "complete-generated", id: UInt32 = 456) throws -> StartupFrame {
        let callback = callback ?? display+1
        return StartupFrame(displayTicks: display, callbackTicks: callback, checkedTicks: callback+3,
            stage: stage, before: stage == "prelaunch" ? nil : owner(callback+1,id:id),
            after: stage == "prelaunch" ? nil : owner(callback+2,id:id),
            proofSHA256: try proof.map { gridHash(try gridCanonical($0)) })
    }
    func append(_ value: StartupFrame, _ state: inout StartupObservation, proof: StartupGridProof? = nil) throws {
        try state.status(StartupStatus(status: 0, displayTicks: value.displayTicks, callbackTicks: value.callbackTicks))
        try state.receive(value,proof:proof)
    }
    func armed(columns: Int = 98, rows: Int = 29) throws -> StartupObservation {
        var state = StartupObservation(displayBounds: rect, targetColumns: columns, targetRows: rows)
        try append(frame(90,stage:"prelaunch"),&state)
        try state.launch(before:1000,after:2100,identity:app)
        return state
    }
    var prearm = StartupObservation(displayBounds: rect)
    try resizeRequire(!prearm.prelaunchReady(at: 1000), "empty capture armed for launch")
    try append(frame(90, stage: "prelaunch"), &prearm)
    try resizeRequire(prearm.prelaunchReady(at: 1000), "past complete frame did not arm capture")
    try append(frame(1200, callback: 900, stage: "prelaunch"), &prearm)
    try resizeRequire(!prearm.prelaunchReady(at: 1000) && !prearm.prelaunchReady(at: 1200)
        && prearm.prelaunchReady(at: 1201), "replacement prelaunch frame bypassed its future display clock")
    checks += 3
    var base = try armed()
    let first = try frame(2000,proof:proof)
    let absent: StartupFrame? = nil
    let absentJSON = try startupJSONValue(absent)
    try resizeRequire(absentJSON is NSNull, "absent optional frame must remain JSON null")
    let missing = try JSONSerialization.jsonObject(with: JSONSerialization.data(
        withJSONObject: ["firstFrame": absentJSON, "prelaunchFrame": absentJSON])) as! [String: Any]
    try resizeRequire(missing["firstFrame"] is NSNull && missing["prelaunchFrame"] is NSNull,
                      "missing frames disappeared from failure evidence")
    checks += 1
    let present: StartupFrame? = first
    let presentData = try JSONSerialization.data(withJSONObject: startupJSONValue(present))
    let decoded = try JSONDecoder().decode(StartupFrame.self, from: presentData)
    try resizeRequire(decoded.displayTicks == first.displayTicks && decoded.proofSHA256 == first.proofSHA256,
                      "present optional frame changed during JSON conversion")
    checks += 1
    try append(first,&base,proof:proof)
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let finished = 3000 + UInt64(1_100_000_000) * UInt64(tb.denom) / UInt64(tb.numer)
    let metrics = try base.result(at:finished,final:owner(finished))
    try resizeRequire(metrics["frameMinusLaunchReturnNS"]! < 0 && base.first?.displayTicks == 2000,
                      "frame before native return was not retained")
    checks += 1
    var futureIdle = base
    try futureIdle.status(StartupStatus(status: 1, displayTicks: finished + 10, callbackTicks: finished - 1))
    try resizeRequire(!futureIdle.captureClocksReady(at: finished)
        && futureIdle.captureClocksReady(at: finished + 10), "future idle display did not defer final validation")
    checks += 1
    try expectFailure("final validation still rejects a future idle display") {
        _ = try futureIdle.result(at: finished, final: owner(finished))
    }; checks += 1
    try resizeRequire(try futureIdle.result(at: finished + 10, final: owner(finished + 10)) == metrics,
                      "waiting for the retained display clock changed first-frame timing")
    checks += 1
    var later = base
    try append(frame(2200,proof:proof),&later,proof:proof)
    try resizeRequire(later.first?.displayTicks == first.displayTicks,"later startup frame replaced first")
    checks += 1
    try expectFailure("capture must be armed before launch") {
        var missing = StartupObservation(displayBounds: rect); try missing.launch(before:1000,after:1100,identity:app)
    }; checks += 1
    try expectFailure("complete prelaunch display must precede launch") {
        var future = StartupObservation(displayBounds: rect); try append(frame(1200,callback:90,stage:"prelaunch"),&future)
        try future.launch(before:1000,after:1100,identity:app)
    }; checks += 1
    try expectFailure("first wrong grid cannot be skipped") {
        var wrong = try armed(); try append(frame(2000,proof:alternate),&wrong,proof:alternate)
    }; checks += 1
    var declared = try armed(columns: alternate.witness.columns, rows: alternate.witness.rows)
    try append(frame(2000, proof: alternate), &declared, proof: alternate)
    _ = try declared.result(at: finished, final: owner(finished))
    try resizeRequire(declared.first?.proofSHA256 == gridHash(gridCanonical(alternate)),
                      "predeclared nondefault grid did not retain its first complete viewport")
    checks += 1
    var moving = try armed()
    let changedBounds = ResizeWindowProof(identity: app, windowID: 456, displayID: 1,
        bounds: ResizeBounds(x: 1, y: 0, width: 1399, height: 1000),
        foregroundPID: app.pid, occluded: false, queriedTicks: 2003)
    let movingFrame = StartupFrame(displayTicks: 2000, callbackTicks: 2001, checkedTicks: 2004,
        stage: "complete-generated", before: owner(2002), after: changedBounds,
        proofSHA256: try gridHash(gridCanonical(proof)))
    try append(movingFrame, &moving, proof: proof)
    try resizeRequire(moving.first?.displayTicks == 2000 && moving.settledSince == nil
        && moving.frames.last?.proofSHA256 == movingFrame.proofSHA256
        && moving.proofs[movingFrame.proofSHA256!] == proof,
        "first complete moving frame was replaced or its generated pixels discarded")
    try expectFailure("unsettled opening cannot produce a completed timing") {
        _ = try moving.result(at: finished, final: owner(finished))
    }; checks += 2
    try append(frame(2200, proof: proof), &moving, proof: proof)
    let movingMetrics = try moving.result(at: finished, final: owner(finished))
    try resizeRequire(movingMetrics == metrics && moving.first?.displayTicks == 2000,
                      "settling replaced the moving first frame")
    checks += 1
    var recent = base
    let recentFrame = try frame(finished - UInt64(100_000_000) * UInt64(tb.denom) / UInt64(tb.numer), proof: proof)
    let changed = ResizeWindowProof(identity: app, windowID: 456, displayID: 1,
        bounds: changedBounds.bounds, foregroundPID: app.pid, occluded: false,
        queriedTicks: recentFrame.after!.queriedTicks)
    let unsettled = StartupFrame(displayTicks: recentFrame.displayTicks, callbackTicks: recentFrame.callbackTicks,
        checkedTicks: recentFrame.checkedTicks, stage: recentFrame.stage, before: recentFrame.before,
        after: changed, proofSHA256: recentFrame.proofSHA256)
    try append(unsettled, &recent, proof: proof)
    try append(frame(recentFrame.checkedTicks + 1, proof: proof), &recent, proof: proof)
    try expectFailure("a late geometry change resets the 200ms settled guard") {
        _ = try recent.result(at: finished, final: owner(finished))
    }; checks += 1
    let clipped = ResizeWindowProof(identity: app, windowID: 456, displayID: 1,
        bounds: ResizeBounds(x: Double(proof.raster.xEdges[0]), y: 0, width: 1000, height: 1000),
        foregroundPID: app.pid, occluded: false, queriedTicks: 2003)
    var outside = try armed()
    let clippedFrame = StartupFrame(displayTicks: 2000, callbackTicks: 2001, checkedTicks: 2004,
        stage: "complete-generated", before: owner(2002), after: clipped, proofSHA256: movingFrame.proofSHA256)
    try expectFailure("perimeter must fit the after crop too") {
        try append(clippedFrame, &outside, proof: proof)
    }
    try resizeRequire(outside.first == nil && outside.proofs[movingFrame.proofSHA256!] == proof,
                      "failed containment discarded generated proof or admitted first")
    checks += 2
    try expectFailure("producer success flag cannot replace pixels") {
        var wrong = try armed(); try append(frame(2000),&wrong)
    }; checks += 1
    try expectFailure("later incomplete frame invalidates first") {
        var wrong = base; try append(frame(2200,stage:"fixture-incomplete"),&wrong)
    }; checks += 1
    try expectFailure("later window identity cannot replace first") {
        var wrong = base; try append(frame(2200,proof:proof,id:999),&wrong,proof:proof)
    }; checks += 1
    try expectFailure("complete statuses cannot be missing") {
        var wrong = try armed(); try wrong.receive(first,proof:proof); try wrong.validateStatuses()
    }; checks += 1
    try expectFailure("duplicate complete frames are rejected") {
        var wrong = base; try append(first,&wrong,proof:proof); try wrong.validateStatuses()
    }; checks += 1
    for status in [2,3,4,5] {
        try expectFailure("post-first status \(status) rejected") {
            var wrong = base; try wrong.status(StartupStatus(status:status,displayTicks:2200,callbackTicks:2201))
        }; checks += 1
    }
    try expectFailure("blank future display cannot hide before first callback") {
        var wrong = try armed()
        try wrong.status(StartupStatus(status:2,displayTicks:2001,callbackTicks:1900))
        try append(first,&wrong,proof:proof); try wrong.validateStatuses()
    }; checks += 1
    var future = try armed()
    try append(frame(2500,callback:2000,proof:proof),&future,proof:proof)
    let futureMetrics = try future.result(at:finished,final:owner(finished))
    try resizeRequire(futureMetrics["captureCallbackLagNS"]! < 0,"future display was clamped to callback")
    checks += 1
    try expectFailure("stability cannot end before display clock") {
        _ = try future.result(at:2501,final:owner(2501))
    }; checks += 1
    try expectFailure("overflowing raster edges are rejected before subtraction") {
        var edges = proof.raster.xEdges; edges[3] = Int.min
        try StartupGridRaster(width:1400,height:1000,xEdges:edges,yEdges:proof.raster.yEdges,
            sampleInsetPixels:2,edgeRoundingPixels:1).validate(columns:98,rows:29)
    }; checks += 1
}

@MainActor func startupFinalizationTests(checks: inout Int) async throws {
    let initial: [String: Any] = ["schemaVersion": 1, "qualifying": false, "status": "invalid",
                                  "error": "original observation failure"]
    let cleanup: [String: Any] = ["appPID": 123, "workerPID": 124, "appReaped": true,
                                  "workerGone": true, "childStatus": 0]
    var order: [String] = []
    let absent: StartupFrame? = nil
    var persisted: [String: Any] = [:]
    _ = try await startupFinalizeReport(initial, cleanup: {
        order += ["owned-worker-stop", "owned-app-wait"]
        return cleanup
    }, appendDiagnostics: { value in
        order.append("encode")
        value["firstFrame"] = try startupJSONValue(absent)
        value["prelaunchFrame"] = try startupJSONValue(absent)
    }, write: { value in
        order.append("write")
        persisted = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as! [String: Any]
    })
    try resizeRequire(order == ["owned-worker-stop", "owned-app-wait", "encode", "write"]
        && persisted["firstFrame"] is NSNull && persisted["status"] as? String == "invalid"
        && (persisted["cleanup"] as? [String: Any])?["appPID"] as? Int == 123,
        "absent-frame failure did not retain actual cleanup before output")
    checks += 1

    order = []
    let encodedFailure = try await startupFinalizeReport(initial, cleanup: {
        order += ["owned-worker-stop", "owned-app-wait"]
        return cleanup
    }, appendDiagnostics: { value in
        order.append("encode")
        value["partial"] = "must be discarded"
        value["nonfinite"] = try startupJSONValue(Double.nan)
    }, write: { value in
        order.append("write")
        _ = try JSONSerialization.data(withJSONObject: value)
    })
    try resizeRequire(order == ["owned-worker-stop", "owned-app-wait", "encode", "write"]
        && encodedFailure["status"] as? String == "invalid" && encodedFailure["partial"] == nil
        && encodedFailure["serializationError"] is String
        && encodedFailure["error"] as? String == "original observation failure"
        && (encodedFailure["cleanup"] as? [String: Any])?["workerGone"] as? Bool == true,
        "encoding failure bypassed cleanup or became a successful receipt")
    checks += 1

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-write-failure-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("already-owned.json")
    let original = Data("preserve original generated bytes".utf8)
    try original.write(to: output, options: .withoutOverwriting)
    order = []
    var rejected = false
    do {
        _ = try await startupFinalizeReport(initial, cleanup: {
            order += ["owned-worker-stop", "owned-app-wait"]
            return cleanup
        }, appendDiagnostics: { _ in order.append("encode") }, write: {
            order.append("write")
            try startupWriteReport($0, to: output)
        })
    } catch { rejected = true }
    try resizeRequire(rejected && order == ["owned-worker-stop", "owned-app-wait", "encode", "write"]
        && (try Data(contentsOf: output)) == original, "write failure bypassed cleanup or overwrote existing evidence")
    checks += 1
}
