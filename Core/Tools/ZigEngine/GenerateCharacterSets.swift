import Foundation

// Build-time only compatibility data for native host-prose wrapping.
let sets: [(String, CharacterSet)] = [
    ("whitespace", .whitespaces),
    ("trim", .whitespacesAndNewlines)
]
var output: [String: [[UInt32]]] = [:]
for (name, set) in sets {
    var ranges: [[UInt32]] = []
    var start: UInt32?
    for value: UInt32 in 0...0x110000 {
        let present = Unicode.Scalar(value).map { set.contains($0) } ?? false
        if present {
            if start == nil { start = value }
        } else if let first = start {
            ranges.append([first, value - 1])
            start = nil
        }
    }
    output[name] = ranges
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
