// Compiled with the unchanged frozen production Cell.swift. String.first, not
// a reimplementation of Unicode rules, supplies every comparison result.
import Foundation
private struct Case: Decodable { var name: String; var scalars: [UInt32] }
@main private enum Reference {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        var checked = 0
        var failures = 0
        var details: [[String: Any]] = []
        func check(_ scalars: [UInt32], name: String) {
            precondition(!scalars.isEmpty)
            let extra = Array(scalars.dropFirst())
            let expected = Array(Cell(scalar: scalars[0], clusterExtras: extra).text.utf8)
            var actual = [UInt8](repeating: 0, count: scalars.count * 4 + 4)
            let count = actual.withUnsafeMutableBufferPointer { output in
                extra.withUnsafeBufferPointer { input in
                    cmdy_grapheme_probe(scalars[0], input.baseAddress, input.count, output.baseAddress!, output.count)
                }
            }
            checked += 1
            guard count >= 0, count <= actual.count, expected == Array(actual.prefix(count)) else {
                failures += 1
                if details.count < 50 {
                    details.append(["name": name, "scalars": scalars, "expected": expected,
                                    "actual_count": count, "actual": count >= 0 ? Array(actual.prefix(count)) : []])
                }
                return
            }
        }
        for request in cases { check(request.scalars, name: request.name) }
        // Every valid scalar is checked as a follower in these independent
        // contexts. They cover extension, prepend/control, pictographic ZWJ,
        // and Indic linking properties, including unassigned Unicode scalars.
        for scalar in UInt32(1)...0x10ffff where UnicodeScalar(scalar) != nil {
            check([0x41, scalar, 0x301], name: "all-follow-\(scalar)")
            check([scalar, 0x41, 0x301], name: "all-lead-\(scalar)")
            check([0x1f469, 0x200d, scalar], name: "all-zwj-\(scalar)")
            check([0x915, 0x94d, scalar], name: "all-indic-\(scalar)")
        }
        let record: [String: Any] = ["status": failures == 0 ? "pass" : "fail",
            "cases": checked, "failures": failures, "details": details]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
        if failures != 0 { exit(1) }
    }
}
