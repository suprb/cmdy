import CoreFoundation
import Foundation

/// Services an already admitted mailbox at run-loop entry, before framework
/// display observers, while retaining main-dispatch delivery as a fallback.
/// It creates no timer and does not wake the loop separately from that dispatch.
final class MainRunLoopDelivery: @unchecked Sendable {
    private final class Ticket: @unchecked Sendable {
        let body: @MainActor @Sendable () -> Void
        init(_ body: @escaping @MainActor @Sendable () -> Void) { self.body = body }
    }

    private let lock = NSLock()
    private var pending: Ticket?
    private var observer: CFRunLoopObserver?

    @MainActor init() {
        observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.entry.rawValue, true, CFIndex.min + 1
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.deliver() }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
    }

    /// The caller's mailbox admits exactly one outstanding delivery.
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) {
        let ticket = Ticket(body)
        lock.lock()
        precondition(pending == nil, "mailbox delivery already pending")
        pending = ticket
        lock.unlock()
        DispatchQueue.main.async { self.deliver(only: ticket) }
    }

    @MainActor private func deliver(only expected: Ticket? = nil) {
        lock.lock()
        guard let ticket = pending, expected == nil || ticket === expected else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        // Consume the ticket before callbacks can admit a followup. An older
        // dispatch fallback cannot consume that followup's different ticket.
        ticket.body()
    }
}
