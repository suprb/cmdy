import AppKit
import Carbon.HIToolbox

/// One Carbon event handler for every global hotkey in the app (multiple
/// InstallEventHandler registrations would race each other). Plugins and
/// core features register through here.
final class HotKeyCenter {
    nonisolated(unsafe) static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextId: UInt32 = 1
    private var installed = false

    /// Register a system-wide hotkey. The returned id is an ownership handle
    /// that must be unregistered when its plugin stops.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32,
                  _ handler: @escaping () -> Void) -> UInt32? {
        installIfNeeded()
        let id = nextId
        nextId += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers,
                                         EventHotKeyID(signature: OSType(0x5436_344B), id: id),  // 'T64K'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            handlers[id] = nil
            NSLog("cmdy: hotkey (code %d) registration failed: %d", keyCode, status)
            return nil
        }
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        handlers[id] = nil
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async { HotKeyCenter.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
