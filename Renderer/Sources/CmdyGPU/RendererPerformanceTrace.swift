import Darwin
import Foundation

/// Temporary, opt-in phase evidence. Never records terminal contents.
/// Disabled instrumentation does not evaluate fields, read the clock or enqueue writer work.
enum RendererPerformanceTrace {
    static let enabled = ProcessInfo.processInfo.environment["CMDY_FRAME_TRACE"] == "1"

    static func now() -> UInt64 {
        enabled ? mach_absolute_time() : 0
    }

    static func record(
        event: String, started: UInt64, fields: @autoclosure () -> [String: Int] = [:]
    ) {
        guard enabled, started != 0 else { return }
        // Field construction remains inside the recorded phase when enabled.
        let resolvedFields = fields()
        let ended = mach_absolute_time()
        writer.record(event: event, started: started, ended: ended, fields: resolvedFields)
    }

    private static let writer = Writer()

    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(
            label: "com.cmdy.trace.renderer", qos: .utility)
        private var reservedRecords = 0
        private let limit = 4_096

        init() {
            queue.async {
                var timebase = mach_timebase_info_data_t()
                mach_timebase_info(&timebase)
                let timestamp = mach_absolute_time()
                Self.write(event: "clock", started: timestamp, ended: timestamp,
                           fields: ["numer": Int(timebase.numer),
                                    "denom": Int(timebase.denom),
                                    "maxRecords": 4_096])
            }
        }

        func record(event: String, started: UInt64, ended: UInt64,
                    fields: [String: Int]) {
            lock.lock()
            guard reservedRecords <= limit else {
                lock.unlock()
                return
            }
            let reachedLimit = reservedRecords == limit
            reservedRecords += 1
            lock.unlock()
            // The fixed reservation limit also bounds queued allocations if
            // stderr is slow. Encoding and I/O stay off the model/UI queues.
            queue.async {
                Self.write(event: reachedLimit ? "limit" : event,
                           started: started, ended: ended,
                           fields: reachedLimit ? ["maxRecords": 4_096] : fields)
            }
        }

        private static func write(event: String, started: UInt64,
                                  ended: UInt64, fields: [String: Int]) {
            let record: [String: Any] = [
                "component": "renderer", "event": event,
                "started": started, "ended": ended,
                "durationTicks": ended >= started ? ended - started : 0,
                "fields": fields
            ]
            guard let encoded = try? JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys]) else { return }
            var line = Data("CMDY_FRAME_TRACE ".utf8)
            line.append(encoded)
            line.append(0x0A)
            FileHandle.standardError.write(line)
        }
    }
}
