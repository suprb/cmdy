import CryptoKit
import Foundation

let resizeFixtureVersion = 2
let resizeObservationScope = "complete-generated-cell-viewport-v2"

func resizeNonce(_ nonce: String) throws {
    try resizeRequire(nonce.utf8.count == 32 && nonce.allSatisfy { "0123456789abcdef".contains($0) },
                      "nonce must be 128-bit lowercase hexadecimal")
}
func resizeGrid(_ columns: Int, _ rows: Int) throws {
    try resizeRequire((columns == 120 && rows == 36) || (columns == 132 && rows == 40),
                      "grid must be 120x36 or 132x40")
}
func resizeCRC32(_ value: String) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in value.utf8 {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
    }
    return ~crc
}
func resizeWord(_ nonce: String, _ sequence: UInt32, _ columns: Int,
                _ rows: Int, _ row: Int) throws -> String {
    try resizeNonce(nonce); try resizeGrid(columns, rows)
    try resizeRequire((0..<rows).contains(row), "row outside target grid")
    let value = nonce + String(format: "%08x%04x%04x%04x", sequence, columns, rows, row)
    return value + String(format: "%08x", resizeCRC32(value))
}
func resizeNominalColors() -> [ResizeRGB] {
    (0..<16).map { ResizeRGB(red: 36 + ($0 % 4) * 48, green: 36 + ($0 / 4) * 48, blue: 212) }
        + [ResizeRGB(red: 242, green: 36, blue: 36), ResizeRGB(red: 36, green: 242, blue: 36)]
}
func resizeCellClasses(word: String, columns: Int) -> [Int] {
    let identity = word.map { Int(String($0), radix: 16)! }
    let tail = (61..<(columns - 1)).map { column in
        Int(resizeCRC32(word + String(format: "/%04x", column)) & 15)
    }
    return [16] + identity + tail + [17]
}
func resizeCellClassesDigest(_ expected: ResizeFrameExpectation) -> String {
    resizeDigest(Data(expected.words.flatMap {
        resizeCellClasses(word: $0, columns: expected.calibration.columns).map(UInt8.init)
    }))
}
func resizeExpectation(nonce: String, sequence: UInt32,
                       calibration: ResizeRasterCalibration) throws -> ResizeFrameExpectation {
    try calibration.validate()
    return ResizeFrameExpectation(nonce: nonce, sequence: sequence,
        words: try (0..<calibration.rows).map {
            try resizeWord(nonce, sequence, calibration.columns, calibration.rows, $0)
        }, calibration: calibration)
}
func resizeHistoryRows(_ nonce: String) throws -> [String] {
    try resizeNonce(nonce)
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
    return (0..<1_000).map { row in
        let prefix = "CMDY_RESIZE_" + nonce + String(format: "_ROW_%06d|", row)
        return prefix + String(decoding: (0..<(145 - prefix.utf8.count)).map {
            alphabet[(row * 17 + $0) % alphabet.count]
        }, as: UTF8.self)
    }
}
func resizeVisibleRows(_ nonce: String, _ sequence: UInt32, _ columns: Int,
                       _ rows: Int) throws -> [String] {
    try resizeNonce(nonce); try resizeGrid(columns, rows)
    return [String](repeating: String(repeating: " ", count: columns), count: rows)
}
func resizeDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
