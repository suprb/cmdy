// Synthetic generated BGRA and timestamp tests. No GUI, capture or event APIs.
import Darwin
import Foundation

@main
enum PasteNativeTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("pass generated protocol-vectors.json") }
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let token = vectors["token"] as! String
        let fixture = try PasteFixture(token: token)
        let width = 920, height = 430, left = 31, top = 52, cell = 7, rowHeight = 9
        var count = 0
        func check(_ value: Bool, _ text: String) {
            guard value else { fatalError("FAIL \(text)") }
            count += 1; print("PASS \(text)")
        }
        for row in [0, 900, 958, 964] {
            check(fixture.viewports[row].canonicalRowsSHA256 == (vectors["viewportSHA256"] as! [String: String])[String(row)],
                  "Swift/Python canonical generated viewport \(row) agrees")
        }
        func pixels(first: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<36 {
                for column in 0..<120 {
                    let color = fixture.viewports[first].colors[row][column]
                    for y in (top + row * rowHeight)..<(top + (row + 1) * rowHeight) {
                        for x in (left + column * cell)..<(left + (column + 1) * cell) {
                            let offset = (y * width + x) * 4
                            bytes[offset] = UInt8(color.blue); bytes[offset + 1] = UInt8(color.green)
                            bytes[offset + 2] = UInt8(color.red); bytes[offset + 3] = 255
                        }
                    }
                }
            }
            return bytes
        }
        func calibrate(_ bytes: [UInt8]) throws -> PasteRasterGeometry? {
            try bytes.withUnsafeBufferPointer { try PasteRaster.calibrate(bytes: $0.baseAddress!,
                bytesPerRow: width * 4, width: width, height: height, fixture: fixture) }
        }
        let original = pixels(first: 964)
        guard let geometry = try calibrate(original) else { fatalError("automatic calibration did not find generated content") }
        check(geometry.rowBands.first?.lower == top && geometry.rowBands.last?.upper == top + 36 * rowHeight,
              "automatic raster discovers all 36 exact vertical bands")
        check(geometry.columnSamples[0] == [33, 34, 35] && geometry.columnSamples[119] == [866, 867, 868],
              "sentinel pitch discovers 120 coded columns without a supplied crop")
        check(geometry.discovery == PasteRasterDiscovery(firstRow: 964, redLower: left, redUpper: left + cell,
            greenLower: left + 119 * cell, greenUpper: left + 120 * cell, top: top, rowHeight: rowHeight),
              "native sentinel spans and full-row discovery preimage retained")
        func decode(_ bytes: [UInt8]) -> (Int, Int)? {
            bytes.withUnsafeBufferPointer { PasteRaster.decode(bytes: $0.baseAddress!,
                bytesPerRow: width * 4, geometry: geometry, fixture: fixture) }
        }
        check(decode(original)?.0 == 964 && decode(original)?.1 == 36 * 9 * 120 * 3,
              "all rows decoded and full-band pixel count retained")
        check(decode(pixels(first: 958))?.0 == 958, "frozen raster decodes a new exact generated viewport")
        let observed = original.withUnsafeBufferPointer {
            PasteRaster.observedCellClasses(bytes: $0.baseAddress!, bytesPerRow: width * 4, geometry: geometry)
        }
        var expectedClasses: [UInt8] = []
        for colors in fixture.viewports[964].colors {
            for color in colors {
                if color.green == 40 { expectedClasses.append(16) }
                else if color.green == 238 { expectedClasses.append(17) }
                else { expectedClasses.append(UInt8((color.red - 48) / 12)) }
            }
        }
        check(Array(observed) == expectedClasses && observed.count == 4320,
              "observed cell stream is derived from all sampled pixels before expected-row comparison")
        var shifted = original
        shifted.replaceSubrange(width * 4..<shifted.count, with: original[0..<(original.count - width * 4)])
        check(decode(shifted) == nil, "one-pixel vertical translation cannot acknowledge complete rows")
        var clippedTop = original
        for x in left..<(left + 120 * cell) { clippedTop[(top * width + x) * 4 + 3] = 0 }
        check(try calibrate(clippedTop) == nil, "partially clipped first row cannot become calibration")
        var clippedBottom = original
        for x in left..<(left + 120 * cell) { clippedBottom[((top + 36 * rowHeight - 1) * width + x) * 4 + 3] = 0 }
        check(try calibrate(clippedBottom) == nil, "partially clipped final row cannot become calibration")
        var wrongNonce = original
        for y in top..<(top + 36 * rowHeight) {
            for x in (left + cell)..<(left + cell * 2) {
                wrongNonce[(y * width + x) * 4 + 2] = 255
            }
        }
        check(try decode(wrongNonce) == nil && calibrate(wrongNonce) == nil,
              "correct row ordinal without exact nonce cannot acknowledge")
        for column in 0..<120 {
            var changed = original
            let y = top + (column % 36) * rowHeight
            let x = geometry.columnSamples[column][1]
            changed[(y * width + x) * 4 + 3] = 0
            check(decode(changed) == nil, "partial cell in full-width column \(column) is rejected")
            let actual = changed.withUnsafeBufferPointer {
                PasteRaster.observedCellClasses(bytes: $0.baseAddress!, bytesPerRow: width * 4, geometry: geometry)
            }
            check(actual[(column % 36) * 120 + column] == 254,
                  "mixed sampled pixels retained as invalid class in column \(column)")
        }
        let window = ScrollWindowProof(appPID: 100, windowID: 2, frontmostPID: 100,
            x: 120, y: 120, width: 1000, height: 750, processStartSeconds: 1,
            processStartMicroseconds: 2, displayID: 1)
        let state = PasteRasterState()
        _ = try state.arm()
        let oldEpoch = state.callbackEpoch()
        let decoderEntered = DispatchSemaphore(value: 0), releaseDecoder = DispatchSemaphore(value: 0)
        let decoderFinished = DispatchSemaphore(value: 0), armed = DispatchSemaphore(value: 0)
        @Sendable func epochFrame(_ tick: UInt64) -> PasteRasterFrame {
            PasteRasterFrame(displayTicks: tick, callbackTicks: tick + 1,
                windowQueryFinishedTicks: tick + 2, window: window, firstRow: 964,
                checkedPixels: 36 * 9 * 120 * 3,
                canonicalRowsSHA256: fixture.viewports[964].canonicalRowsSHA256, observedCellClasses: nil)
        }
        // Hold an in-flight decoder on the real state object's serial queue.
        // The old queue.sync arm would wait until this decoder was released.
        state.sampleQueue.async {
            decoderEntered.signal(); releaseDecoder.wait()
            state.append(epochFrame(mach_absolute_time()), epoch: oldEpoch.generation, calibrated: geometry)
            decoderFinished.signal()
        }
        check(decoderEntered.wait(timeout: .now() + 2) == .success, "in-flight synthetic decoder entered")
        DispatchQueue.global().async {
            do { _ = try state.arm(); armed.signal() }
            catch { fatalError("unexpected epoch arm failure: \(error)") }
        }
        let armedWithoutDrain = armed.wait(timeout: .now() + 2) == .success
        releaseDecoder.signal()
        check(decoderFinished.wait(timeout: .now() + 2) == .success, "synthetic decoder released and completed")
        check(armedWithoutDrain, "arming progresses while capture queue is occupied")
        check(try state.state().1.isEmpty && state.state().0 == nil,
              "previous-generation decoder cannot append a frame or replace calibration after rearm")
        let currentEpoch = state.callbackEpoch()
        check(currentEpoch.generation == oldEpoch.generation + 1 && currentEpoch.after > oldEpoch.after,
              "generation and dispatch cutoff advance atomically")
        check(!state.append(epochFrame(currentEpoch.after), epoch: currentEpoch.generation, calibrated: geometry),
              "current-generation frame at the dispatch boundary is rejected")
        let currentFrame = epochFrame(currentEpoch.after + 1)
        check(state.append(currentFrame, epoch: currentEpoch.generation, calibrated: geometry),
              "fresh current-generation frame remains admissible")
        let drained = try state.finishedState()
        check(drained.0.count == 1 && drained.0[0].displayTicks == currentFrame.displayTicks,
              "stopped-queue drain retains exactly the current generation")
        for _ in 1..<4096 { state.append(currentFrame, epoch: currentEpoch.generation, calibrated: geometry) }
        check(!state.append(currentFrame, epoch: currentEpoch.generation, calibrated: geometry),
              "unchanged 4096-frame bound fails closed")
        do { _ = try state.arm(); check(false, "capture failure must survive rearm") }
        catch { check(true, "capture failure survives rearm") }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        func ticks(_ ns: UInt64) -> UInt64 { ns * UInt64(timebase.denom) / UInt64(timebase.numer) + 1 }
        let initial: UInt64 = 1_000_000
        func frame(_ ns: UInt64, row: Int? = 958) -> PasteRasterFrame {
            let tick = initial + ticks(ns)
            return PasteRasterFrame(displayTicks: tick, callbackTicks: tick - 1,
                windowQueryFinishedTicks: tick + 1, window: window, firstRow: row,
                checkedPixels: row == nil ? 0 : 36 * 9 * 120 * 3,
                canonicalRowsSHA256: row.map { fixture.viewports[$0].canonicalRowsSHA256 }, observedCellClasses: nil)
        }
        let first = frame(10_000_000), later = frame(30_000_000), now = initial + ticks(310_000_000)
        let stable = try pasteStable([later, first], statuses: [], target: 958, after: initial, now: now)
        check(stable?.first.displayTicks == first.displayTicks && stable?.laterCorrectDistinctFrames == 1,
              "earliest display timestamp retained despite callback order and signed lead")
        check(try pasteStable([first], statuses: [], target: 958, after: initial, now: now)?.first.displayTicks == first.displayTicks,
              "quiet capture never requires fake later complete frames")
        check(try pasteStable([first], statuses: [], target: 958, after: initial,
                              now: initial + ticks(200_000_000)) == nil, "short observation guard remains pending")
        for frames in [[first, frame(40_000_000, row: nil)], [first, frame(10_000_000, row: nil)], [frame(0)]] {
            do {
                _ = try pasteStable(frames, statuses: [], target: 958, after: initial + 1, now: now)
                check(false, "transient/conflicting/pre-dispatch response rejected")
            } catch { check(true, "transient/conflicting/pre-dispatch response rejected") }
        }
        for bad in [2, 3, 4, 5] {
            let status = ScrollCaptureStatusRecord(callbackTicks: first.callbackTicks + 2,
                displayTicks: first.displayTicks + 2, statusRaw: bad, sampleIsValid: true,
                hasImageBuffer: false, generation: 1, armedAfterTicks: initial)
            do {
                _ = try pasteStable([first], statuses: [status], target: 958, after: initial, now: now)
                check(false, "bad capture status \(bad) rejected")
            } catch { check(true, "bad capture status \(bad) rejected") }
        }
        let idle = ScrollCaptureStatusRecord(callbackTicks: first.callbackTicks + 2, displayTicks: nil,
            statusRaw: 1, sampleIsValid: true, hasImageBuffer: false, generation: 1, armedAfterTicks: initial)
        check(try pasteStable([first], statuses: [idle], target: 958, after: initial, now: now)?.laterCorrectDistinctFrames == 0,
              "idle remains diagnostic without adding a complete frame")
        let payloadVectors = vectors["payloadSHA256"] as! [String: String]
        for sequence in [0, 1, 2, 42] {
            let payload = Data(pastePayload(token, sequence).utf8)
            check(scrollHash(payload) == payloadVectors[String(sequence)], "Swift/Python exact Unicode payload \(sequence)")
        }
        let event = try PasteAppleEvent.input(pid: 4321, terminalID: "pane-unique-id", text: "λ世界🙂")
        let address = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))!
        check(address.descriptorType == DescType(typeKernelProcessID)
            && address.data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } == 4321,
              "paste event targets a running PID, with no bundle launch fallback")
        check(event.eventClass == PasteAppleEvent.eventClass && event.eventID == PasteAppleEvent.eventID,
              "same published input text event codes")
        check(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == "λ世界🙂",
              "direct text argument is exact Unicode")
        let target = event.paramDescriptor(forKeyword: PasteAppleEvent.targetKey)!
        check(target.descriptorType == DescType(typeObjectSpecifier)
            && target.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == PasteAppleEvent.terminalClass
            && target.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formUniqueID)
            && target.forKeyword(AEKeyword(keyAEKeyData))?.stringValue == "pane-unique-id",
              "pane target uses a stable unique-ID object specifier")
        let query = try PasteAppleEvent.terminalIDs(pid: 4321)
        let property = query.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
        let every = property.forKeyword(AEKeyword(keyAEContainer))!
        let ordinal = every.forKeyword(AEKeyword(keyAEKeyData))!
        check(every.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formAbsolutePosition)
            && ordinal.descriptorType == DescType(typeAbsoluteOrdinal)
            && ordinal.data == NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data,
              "every terminal uses an absolute ordinal, never an enum coerced to an integer index")
        var sent = 0, prompts = 0
        let denied = PasteAppleEventClient(pid: 4321, permission: { _, _, _, ask in
            prompts += ask ? 1 : 0; return OSStatus(-1743)
        }, send: { _, _, _ in sent += 1; return NSAppleEventDescriptor.null() })
        do { try denied.preflight(); check(false, "denied permission rejected") }
        catch { check(true, "denied existing permission rejected without prompt") }
        do { _ = try denied.dispatch(event, timeout: 1); check(false, "dispatch without authorization rejected") }
        catch { check(sent == 0 && prompts == 0, "denial cannot send, prompt, or fall back") }
        let reply = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
            targetDescriptor: .null(), returnID: 0, transactionID: 0)
        let ids = NSAppleEventDescriptor.list(); ids.insert(NSAppleEventDescriptor(string: "pane-unique-id"), at: 1)
        reply.setParam(ids, forKeyword: AEKeyword(keyDirectObject))
        let allowed = PasteAppleEventClient(pid: 4321, permission: { _, _, _, ask in
            prompts += ask ? 1 : 0; return noErr
        }, send: { _, options, _ in
            sent += 1
            check(options == [.waitForReply, .neverInteract, .dontRecord], "no interaction/focus send flags")
            return reply
        })
        try allowed.preflight()
        check(try allowed.soleTerminalID() == "pane-unique-id" && prompts == 0, "sole terminal public ID query")
        ids.insert(NSAppleEventDescriptor(string: "other"), at: 2)
        reply.setParam(ids, forKeyword: AEKeyword(keyDirectObject))
        do { _ = try allowed.soleTerminalID(); check(false, "ambiguous terminal query rejected") }
        catch { check(true, "ambiguous terminal query rejected") }
        reply.setParam(NSAppleEventDescriptor(int32: -1728), forKeyword: AEKeyword(keyErrorNumber))
        do { _ = try allowed.dispatch(event, timeout: 1); check(false, "stale remote object error rejected") }
        catch { check(true, "stale remote object error rejected") }
        print("PASS \(count) synthetic paste raster/clock/descriptor checks; no native events sent or GUI created")
    }
}
