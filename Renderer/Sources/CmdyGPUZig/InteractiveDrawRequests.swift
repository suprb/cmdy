import CmdyNative

/// Value facade for the native request state used by the renderer scheduler.
struct InteractiveDrawRequests {
    private var native = CmdyRenderInteractiveRequests()
    var generation: UInt64 { native.generation }
    var serviceIsQueued: Bool { native.service_is_queued }
    var isDrawing: Bool { native.is_drawing }
    var isPending: Bool { withUnsafePointer(to: native) { cmdy_render_interactive_pending($0) } }
    mutating func request() { cmdy_render_interactive_request(&native) }
    mutating func queueServiceIfNeeded(blocked: Bool) -> Bool {
        cmdy_render_interactive_queue(&native, blocked)
    }
    mutating func beginService() -> Bool { cmdy_render_interactive_begin_service(&native) }
    mutating func beginDraw() -> UInt64? {
        var value: UInt64 = 0
        return cmdy_render_interactive_begin_draw(&native, &value) ? value : nil
    }
    mutating func finishDraw(committed generation: UInt64?) {
        cmdy_render_interactive_finish_draw(&native, generation != nil, generation ?? 0)
    }
    mutating func cancel() { cmdy_render_interactive_cancel(&native) }
}
