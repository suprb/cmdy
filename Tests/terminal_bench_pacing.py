"""Bounded macOS producer waits; no application launch or input APIs."""
import select
import time

# Public Darwin sys/event.h: NOTE_NSECONDS and NOTE_CRITICAL. The latter
# requests minimal timer coalescing, without changing thread priority.
PACING_POLICY = {"mechanism": "kqueue-EVFILT_TIMER-one-shot", "timerFlags": 0x24,
                 "clock": "time.monotonic_ns", "catchUpBursts": False}


class CriticalTimer:
    def __init__(self):
        self.queue = select.kqueue()

    @property
    def closed(self):
        return self.queue.closed

    def close(self):
        if not self.closed:
            self.queue.close()

    def wait_until(self, deadline_ns):
        while True:
            remaining = deadline_ns - time.monotonic_ns()
            if remaining <= 0:
                return
            event = select.kevent(1, filter=select.KQ_FILTER_TIMER,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                fflags=PACING_POLICY["timerFlags"], data=remaining)
            events = self.queue.control([event], 1, None)
            if len(events) != 1 or events[0].filter != select.KQ_FILTER_TIMER or events[0].ident != 1:
                raise RuntimeError("unexpected producer timer event")
            if events[0].flags & select.KQ_EV_ERROR:
                raise OSError(events[0].data, "producer timer rejected")
