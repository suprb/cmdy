import AppKit
import CmdyKit

/// SID-flavored feedback sounds, synthesized at launch (square waves with a
/// fast decay — no audio assets). Off by default: `sounds = true` in the config.
enum Retrobleeps {

    /// Short high blip for keypresses (C7-ish, very quiet).
    static func keyBlip() {
        play(blipData)
    }

    /// Low descending buzz when a command exits non-zero.
    static func errorBuzz() {
        play(buzzData)
    }

    private static func play(_ data: Data) {
        // A fresh NSSound per play lets rapid keypresses overlap.
        NSSound(data: data)?.play()
    }

    private static let blipData = squareWav(frequency: 2093, duration: 0.018, amplitude: 0.045)
    private static let buzzData = squareWav(frequency: 110, duration: 0.14, amplitude: 0.10, slideTo: 55)

    /// 44.1kHz mono 16-bit PCM WAV of a square wave with linear decay.
    /// `slideTo` bends the pitch downward over the note (the SID falling buzz).
    private static func squareWav(frequency: Double, duration: Double,
                                  amplitude: Double, slideTo: Double? = nil) -> Data {
        let rate = 44_100.0
        let count = Int(rate * duration)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / Double(count)
            let freq = slideTo.map { frequency + (($0 - frequency) * t) } ?? frequency
            phase += freq / rate
            let square: Double = (phase.truncatingRemainder(dividingBy: 1.0)) < 0.5 ? 1 : -1
            let envelope = 1.0 - t   // linear decay
            samples.append(Int16(max(-1, min(1, square * amplitude * envelope)) * 32767))
        }

        var data = Data()
        func put(_ s: String) { data.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        put("RIFF"); put32(36 + byteCount); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)               // PCM, mono
        put32(UInt32(rate)); put32(UInt32(rate) * 2)             // sample & byte rate
        put16(2); put16(16)                                      // block align, bits
        put("data"); put32(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
