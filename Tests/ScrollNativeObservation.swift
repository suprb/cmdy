// Shared strict generated-raster matcher and Codable native evidence types.
// The actual capture/owned-process/event entrypoint is ScrollObserverMain.swift.
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct ScrollProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

struct ScrollRGB: Codable, Equatable, Sendable {
    let red: Int
    let green: Int
    let blue: Int
}

struct ScrollPixelBand: Codable, Equatable, Sendable {
    let lower: Int
    let upper: Int  // Exclusive; no unobserved vertical gaps between rows.
}

struct ScrollRasterGeometry: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let columnSamples: [[Int]]  // Three calibrated interior x pixels/coded cell.
    let rowBands: [ScrollPixelBand]  // Every vertical pixel of all 36 row bands.
    let calibrationSHA256: String

    func validate() throws {
        guard (1...16_384).contains(width), (1...16_384).contains(height), columnSamples.count == 42,
              rowBands.count == 36, calibrationSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ScrollProbeError("missing full-grid raster calibration")
        }
        for points in columnSamples {
            guard points.count == 3, Set(points).count == 3,
                  points == points.sorted(), points.allSatisfy({ 0 <= $0 && $0 < width }) else {
                throw ScrollProbeError("invalid coded-cell x samples")
            }
        }
        for index in 1..<columnSamples.count {
            guard columnSamples[index - 1].last! < columnSamples[index].first! else {
                throw ScrollProbeError("coded-cell x samples overlap or change order")
            }
        }
        for index in rowBands.indices {
            let band = rowBands[index]
            guard band.lower >= 0, band.upper <= height,
                  band.upper - band.lower >= 4,
                  index == 0 || rowBands[index - 1].upper == band.lower else {
                throw ScrollProbeError("row bands have a gap, overlap, or invalid extent")
            }
        }
    }
}

struct ScrollExpectedViewport: Codable, Equatable, Sendable {
    let rows: [Int]
    let colors: [[ScrollRGB]]
    let canonicalRowsSHA256: String

    func validate() throws {
        guard rows.count == 36, colors.count == 36,
              let first = rows.first, first >= 0, first + 36 <= 1000,
              rows == Array(first..<(first + 36)),
              canonicalRowsSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              colors.allSatisfy({ $0.count == 42 && $0.allSatisfy {
                  (0...255).contains($0.red) && (0...255).contains($0.green)
                      && (0...255).contains($0.blue)
              } }) else {
            throw ScrollProbeError("expected viewport is not 36 generated consecutive rows")
        }
    }
}

enum ScrollViewportMatcher {
    // No OCR or pixel export. Every generated row's complete 42-cell code is
    // checked over its full calibrated vertical span, rather than only at row
    // centers: a partially translated/smooth-scrolling row must not pass early.
    // The horizontal interior points avoid cell-boundary raster rounding only.
    static func matches(bytes: UnsafePointer<UInt8>, bytesPerRow: Int,
                        geometry: ScrollRasterGeometry,
                        expected: ScrollExpectedViewport) -> Int? {
        guard bytesPerRow >= geometry.width * 4 else { return nil }
        var checkedPixels = 0
        for row in 0..<36 {
            let band = geometry.rowBands[row]
            for column in 0..<42 {
                let color = expected.colors[row][column]
                for y in band.lower..<band.upper {
                    for x in geometry.columnSamples[column] {
                        let offset = y * bytesPerRow + x * 4
                        guard abs(Int(bytes[offset]) - color.blue) <= 3,
                              abs(Int(bytes[offset + 1]) - color.green) <= 3,
                              abs(Int(bytes[offset + 2]) - color.red) <= 3,
                              bytes[offset + 3] >= 250 else { return nil }
                        checkedPixels += 1
                    }
                }
            }
        }
        return checkedPixels
    }
}

struct ScrollWindowProof: Codable, Equatable, Sendable {
    let appPID: Int32
    let windowID: UInt32
    let frontmostPID: Int32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let processStartSeconds: UInt64
    let processStartMicroseconds: UInt64
    let displayID: UInt32
}

struct ScrollPostedEvent: Codable {
    let rawDelta: Int32
    let units: String
    let isContinuous: Bool
    let eventBeforeTicks: UInt64
    let eventAfterTicks: UInt64
    let eventTimestamp: UInt64
    let x: Double
    let y: Double
    let sourceUserData: Int64
}

// Diagnostic capture chronology, independent from viewport acknowledgement.
// Idle/started/blank/suspended/stopped samples never become complete frames.
struct ScrollCaptureStatusRecord: Codable, Sendable {
    let callbackTicks: UInt64
    let displayTicks: UInt64?
    let statusRaw: Int?
    let sampleIsValid: Bool
    let hasImageBuffer: Bool
    let generation: UInt64
    let armedAfterTicks: UInt64
}

struct ScrollCaptureChronology {
    static let limit = 65_536
    private(set) var records: [ScrollCaptureStatusRecord] = []

    mutating func append(_ value: ScrollCaptureStatusRecord) throws {
        guard records.count < Self.limit else {
            throw ScrollProbeError("bounded capture status chronology overflow")
        }
        records.append(value)
    }
}
