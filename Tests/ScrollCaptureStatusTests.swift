import Foundation

@main
enum ScrollCaptureStatusTests {
    static func main() throws {
        var chronology = ScrollCaptureChronology()
        // Synthetic metadata only: no stream, window, process, pixels or event.
        for status in 0...5 {
            try chronology.append(ScrollCaptureStatusRecord(callbackTicks: UInt64(status + 2),
                displayTicks: status == 0 ? 3 : nil, statusRaw: status,
                sampleIsValid: true, hasImageBuffer: status == 0, generation: 1, armedAfterTicks: 1))
        }
        precondition(chronology.records.map(\.statusRaw) == (0...5).map(Optional.some))
        try chronology.append(ScrollCaptureStatusRecord(callbackTicks: 8, displayTicks: nil,
            statusRaw: nil, sampleIsValid: false, hasImageBuffer: false, generation: 1, armedAfterTicks: 1))
        let data = try JSONEncoder().encode(chronology.records)
        let decoded = try JSONDecoder().decode([ScrollCaptureStatusRecord].self, from: data)
        precondition(decoded.count == 7 && decoded.last?.sampleIsValid == false)
        precondition(decoded[1].statusRaw == 1 && decoded[1].displayTicks == nil && !decoded[1].hasImageBuffer)
        while chronology.records.count < ScrollCaptureChronology.limit {
            try chronology.append(decoded[1])
        }
        do {
            try chronology.append(decoded[0])
            fatalError("overflow was silently admitted")
        } catch {
            precondition(String(describing: error) == "bounded capture status chronology overflow")
            precondition(chronology.records.count == 65536)
        }
        print("PASS capture statuses 0...5 and invalid metadata retained; Codable round trip; idle stays non-frame; exact bounded overflow")
    }
}
