// Creates local CGEvents only: no event posting, capture, or app activation.
import CoreGraphics
import Darwin

@main
enum ScrollNativeEventClockTests {
    static func main() {
        guard let source = CGEventSource(stateID: .privateState) else {
            fatalError("cannot create private event source")
        }
        for delta: Int32 in [1, -1, 2, -2] {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                      wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
                fatalError("cannot create local wheel event")
            }
            event.timestamp = 0
            let before = scrollNS(mach_absolute_time())
            scrollStampCreatedEvent(event)
            let after = scrollNS(mach_absolute_time())
            precondition(event.timestamp > 0 && before <= event.timestamp && event.timestamp <= after)
            precondition(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == Int64(delta))
            precondition(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
        }
        print("PASS native wheel timestamps use the current nanosecond clock; no events posted")
    }
}
