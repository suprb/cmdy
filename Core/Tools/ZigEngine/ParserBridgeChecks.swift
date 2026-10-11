// Compile with the real CmdyCoreZig/VTParser.swift, CmdyNative parser archive,
// checkedNative, and an otherwise unused CmdyTerminal type for identity checks.
// These checks exercise Swift ARC across actual native callbacks.
import Foundation

private final class Log { var events: [String] = [] }
private final class Recorder: VTParserDelegate {
    let name: String
    let log: Log
    var onPrint: ((UnicodeScalar) -> Void)?
    var onCSI: (([Int]) -> Void)?
    var onOSC: ((ArraySlice<UInt8>) -> Void)?
    init(_ name: String, _ log: Log) { self.name = name; self.log = log }
    deinit { log.events.append("\(name):deinit") }
    func parserPrint(_ scalar: UnicodeScalar) {
        log.events.append("\(name):print:\(scalar.value)")
        onPrint?(scalar)
    }
    func parserExecute(_ byte: UInt8) { log.events.append("\(name):execute:\(byte)") }
    func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {
        log.events.append("\(name):csi:\(final):\(params):\(collect)")
        onCSI?(params)
    }
    func parserESC(final: UInt8, collect: [UInt8]) { log.events.append("\(name):esc:\(final)") }
    func parserOSC(code: Int, payload: ArraySlice<UInt8>) {
        log.events.append("\(name):osc:\(code):\(Array(payload))")
        onOSC?(payload)
    }
    func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) {}
    func parserDCSPut(_ bytes: ArraySlice<UInt8>) {}
    func parserDCSUnhook() {}
    func parserAPC(_ bytes: ArraySlice<UInt8>) {}
}

@main private enum Checks {
    static func weakExpiry() {
        let parser = VTParser(), log = Log()
        var first: Recorder? = Recorder("first", log)
        weak var witness = first
        first?.onPrint = { _ in
            first = nil
            precondition(witness != nil, "Active callback must retain its receiver")
        }
        parser.delegate = first
        parser.feed(Array("A\u{1b}[31mB".utf8))
        precondition(witness == nil && parser.delegate == nil)
        precondition(log.events == ["first:print:65", "first:deinit"])
        precondition(parser.state == .ground)
    }
    static func replacementAndReentry() {
        let parser = VTParser(), log = Log()
        let first = Recorder("first", log), second = Recorder("second", log)
        var retained: [[Int]] = []
        first.onCSI = { values in
            precondition(parser.state == .ground)
            retained.append(values)
            parser.delegate = second
            parser.reset()
            parser.feed(Array("\u{1b}[32;44mR\u{1b}[".utf8))
            precondition(values == [31, 1])
        }
        second.onCSI = { retained.append($0) }
        defer { first.onCSI = nil; second.onCSI = nil }
        parser.delegate = first
        let input = [UInt8](repeating: 0xff, count: 7) + Array("\u{1b}[31;1m0mZ\u{1b}[38;2;1;2;3m".utf8)
        parser.feed(input[7...])
        precondition(retained == [[31, 1], [32, 44], [0], [38, 2, 1, 2, 3]])
        precondition(log.events == [
            "first:csi:109:[31, 1]:[]", "second:csi:109:[32, 44]:[]", "second:print:82",
            "second:csi:109:[0]:[]", "second:print:90", "second:csi:109:[38, 2, 1, 2, 3]:[]"])
        precondition(parser.state == .ground)
    }
    static func unicodeReplacement() {
        for decodes in [false, true] {
            let parser = VTParser(), log = Log()
            parser.decodesContiguousUTF8 = decodes
            var first: Recorder? = Recorder("first", log)
            let second = Recorder("second", log)
            weak var witness = first
            first?.onPrint = { _ in parser.delegate = second; first = nil }
            parser.delegate = first
            parser.feed(Array("é界".utf8))
            precondition(witness == nil)
            precondition(log.events == ["first:print:233", "first:deinit", "second:print:30028"])
            withExtendedLifetime(second) {}
        }
    }
    static func oscSnapshotAcrossNestedReset() {
        let parser = VTParser(), log = Log(), recorder = Recorder("osc", Log())
        var retained: ArraySlice<UInt8> = []
        var entered = false
        recorder.onOSC = { payload in
            guard !entered else { return }
            entered = true
            precondition(parser.state == .oscString)
            retained = payload
            parser.reset()
            parser.feed(Array("\u{1b}]2;inner\u{7}\u{1b}[".utf8))
            precondition(Array(payload) == Array("outer".utf8))
            log.events.append(String(describing: parser.state))
        }
        defer { recorder.onOSC = nil }
        parser.delegate = recorder
        parser.feed(Array("\u{1b}]0;outer\u{7}Z".utf8))
        precondition(entered && Array(retained) == Array("outer".utf8))
        precondition(log.events == ["csiEntry"])
        precondition(parser.state == .ground)
    }
    static func main() {
        weakExpiry()
        replacementAndReentry()
        unicodeReplacement()
        oscSnapshotAcrossNestedReset()
        print("PASS: 4 Swift/native parser callback lifetime and reentry checks")
    }
}
