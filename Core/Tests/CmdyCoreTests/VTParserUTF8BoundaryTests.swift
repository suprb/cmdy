import XCTest
@testable import CmdyCore

final class VTParserUTF8BoundaryTests: XCTestCase {
    func testValidScalarsAndNonzeroSlicesAcrossEverySmallChunkSize() {
        var values: [UInt32] = [0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF,
                                0x10000, 0x10FFFF, 0x301, 0xFE0F, 0x200D,
                                0x1F469, 0x1F3FD, 0x1F4BB]
        values += stride(from: UInt32(0x80), through: UInt32(0x10FFFF), by: 257)
            .filter { UnicodeScalar($0) != nil }
        let text = String(String.UnicodeScalarView(values.compactMap(UnicodeScalar.init)))
        let payload = Array(text.utf8)
        let storage = [UInt8](repeating: 0x1B, count: 3) + payload + [0x1B]
        for chunk in [1, 2, 3, 4, 7, 1024, payload.count] {
            let parser = VTParser()
            let probe = Probe()
            parser.delegate = probe
            for start in stride(from: 3, to: storage.count - 1, by: chunk) {
                parser.feed(storage[start..<min(storage.count - 1, start + chunk)])
            }
            XCTAssertEqual(probe.events, values.map(Event.scalar), "chunk \(chunk)")
        }
    }

    func testMalformedCompletionsKeepLatin1LeadAndConsumeExactlyTheirTail() {
        let leads: [UInt8] = [0xC2, 0xC3, 0xDF, 0xE0, 0xE1, 0xED, 0xEF, 0xF0, 0xF1, 0xF4]
        for lead in leads {
            let count = lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
            for second in UInt8(0x20)...UInt8.max {
                var bytes = [lead, second]
                bytes += [UInt8](repeating: 0x80, count: count - 2)
                // Foundation's strict UTF-8 decoding is independent of the
                // terminal's deliberate Latin-1-lead malformed fallback.
                let value = String(bytes: bytes, encoding: .utf8)?.unicodeScalars.first?.value
                    ?? UInt32(lead)
                for cut in 1...count {
                    let parser = VTParser()
                    let probe = Probe()
                    parser.delegate = probe
                    parser.feed(bytes[..<cut])
                    parser.feed(bytes[cut...])
                    parser.feed([0x7C])
                    XCTAssertEqual(probe.events, [.scalar(value), .scalar(0x7C)],
                                   "lead \(lead), second \(second), cut \(cut)")
                }
            }
        }
    }

    func testC0ControlsDoNotConsumePendingUTF8Bytes() {
        let sequences: [[UInt8]] = [[0xC2, 0xA2], [0xE2, 0x82, 0xAC], [0xF0, 0x9F, 0x9A, 0x80]]
        for bytes in sequences {
            let value = String(bytes: bytes, encoding: .utf8)!.unicodeScalars.first!.value
            for control in UInt8(0)...UInt8(0x1F) where control != 0x1B {
                for cut in 1..<bytes.count {
                    let parser = VTParser()
                    let probe = Probe()
                    parser.delegate = probe
                    parser.feed(bytes[..<cut])
                    parser.feed([control])
                    parser.feed(bytes[cut...])
                    XCTAssertEqual(probe.events, [.control(control), .scalar(value)])
                }
            }
        }
    }

    func testEscapeResetAndReentrantDelegatesSeeClearedAssembly() {
        let parser = VTParser()
        let probe = Probe()
        parser.delegate = probe
        parser.feed([0xF0, 0x9F, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x92, 0xBB, 0x58])
        XCTAssertEqual(probe.events, [.csi(0x6D, [31], []), .scalar(0xBB), .scalar(0x58)])
        probe.events = []
        parser.feed([0xED, 0xA0])
        parser.reset()
        parser.feed([0x41])
        XCTAssertEqual(probe.events, [.scalar(0x41)])

        probe.events = []
        probe.onScalar = { value in
            if value == 0x20AC { parser.feed([0xC2]) }
        }
        parser.feed([0xE2, 0x82, 0xAC, 0xA2])
        XCTAssertEqual(probe.events, [.scalar(0x20AC), .scalar(0xA2)])

        probe.events = []
        probe.onScalar = nil
        probe.onControl = { _ in parser.reset() }
        parser.feed([0xE2, 0x07, 0x82, 0xAC])
        XCTAssertEqual(probe.events, [.control(0x07), .scalar(0xAC)])
    }

    func testContiguousDecoderMatchesByteAssemblyForMixedMalformedInput() {
        var payload: [UInt8] = []
        for lead in UInt8(0xC2)...UInt8(0xF4) {
            for second in UInt8.min...UInt8.max {
                // C0, ESC, malformed continuations, overlongs, surrogates,
                // valid scalars and invalid leads all occur at varied cuts.
                payload += [lead, second, second &+ 31, second &+ 73,
                            0x1B, 0x5B, 0x30, 0x6D, 0x7C]
            }
        }
        payload += Array("e\u{301} 中文 Ελληνικά العربية 👩🏽\u{200D}💻 🏳️\u{200D}🌈".utf8)
        let storage = [UInt8](repeating: 0x1B, count: 7) + payload + [0x1B]
        let fallback = VTParser()
        fallback.decodesContiguousUTF8 = false
        let expected = Probe()
        fallback.delegate = expected
        fallback.feed(storage[7..<(storage.count - 1)])
        for chunk in [1, 2, 3, 4, 7, 1024, payload.count] {
            let parser = VTParser()
            let actual = Probe()
            parser.delegate = actual
            for start in stride(from: 7, to: storage.count - 1, by: chunk) {
                parser.feed(storage[start..<min(storage.count - 1, start + chunk)])
            }
            XCTAssertEqual(actual.events, expected.events, "chunk \(chunk)")
        }
    }

    func testContiguousDecoderObservesReentrantPendingInputAndStateChanges() {
        for contiguous in [false, true] {
            let parser = VTParser()
            parser.decodesContiguousUTF8 = contiguous
            let probe = Probe()
            parser.delegate = probe
            probe.onScalar = { value in
                if value == 0x20AC { parser.feed([0x1B, 0x5B, 0x33]) }
            }
            parser.feed([0xE2, 0x82, 0xAC, 0x31, 0x6D, 0x5A])
            XCTAssertEqual(probe.events, [.scalar(0x20AC), .csi(0x6D, [31], []), .scalar(0x5A)])

            probe.events = []
            probe.onScalar = { value in
                if value == 0x20AC { parser.feed([0xF0, 0x9F]) }
            }
            parser.feed([0xE2, 0x82, 0xAC, 0x9A, 0x80])
            XCTAssertEqual(probe.events, [.scalar(0x20AC), .scalar(0x1F680)])

            probe.events = []
            probe.onScalar = { value in
                if value == 0x20AC { parser.reset() }
            }
            parser.feed([0xE2, 0x82, 0xAC, 0xC2, 0xA2])
            XCTAssertEqual(probe.events, [.scalar(0x20AC), .scalar(0xA2)])
        }
    }

    private enum Event: Equatable {
        case scalar(UInt32), control(UInt8), csi(UInt8, [Int], [UInt8])
    }

    private final class Probe: VTParserDelegate {
        var events: [Event] = []
        var onScalar: ((UInt32) -> Void)?
        var onControl: ((UInt8) -> Void)?
        func parserPrint(_ scalar: UnicodeScalar) {
            events.append(.scalar(scalar.value)); onScalar?(scalar.value)
        }
        func parserExecute(_ byte: UInt8) { events.append(.control(byte)); onControl?(byte) }
        func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) { events.append(.csi(final, params, collect)) }
        func parserESC(final: UInt8, collect: [UInt8]) {}
        func parserOSC(code: Int, payload: ArraySlice<UInt8>) {}
        func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) {}
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) {}
        func parserDCSUnhook() {}
        func parserAPC(_ bytes: ArraySlice<UInt8>) {}
    }
}
