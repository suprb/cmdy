import CmdyNative
import Foundation

/// Value-only compatibility surface. Native owns activation, timestamps,
/// bounded asynchronous output and the renderer's trace record schema.
enum RendererPerformanceTrace {
    static var enabled: Bool { cmdy_render_trace_enabled() != 0 }
    static func now() -> UInt64 { cmdy_render_trace_now() }
    static func record(event: String, started: UInt64,
                       fields: @autoclosure () -> [String: Int] = [:]) {
        guard enabled, started != 0 else { return }
        let values = fields()
        let ended = cmdy_render_trace_now()
        var names: [CChar] = []
        var offsets: [(Int, Int)] = []
        for (name, value) in values {
            offsets.append((names.count, value))
            names.append(contentsOf: name.utf8CString)
        }
        event.withCString { eventPointer in
            names.withUnsafeBufferPointer { buffer in
                let records = offsets.map { offset, value in
                    CmdyRenderTraceField(name: buffer.baseAddress!.advanced(by: offset), value: value)
                }
                records.withUnsafeBufferPointer {
                    cmdy_render_trace_record_ended(eventPointer, started, ended, $0.baseAddress, $0.count)
                }
            }
        }
    }
}
