import AppKit
import Carbon

/// Registers a single global hotkey via Carbon RegisterEventHotKey.
///
/// Carbon's hotkey API is the only reliable way to receive key events from anywhere
/// in macOS without Accessibility permission. We install one event handler for the
/// `kEventHotKeyPressed` event and route the callback back to the main actor.
///
/// Multiple `HotkeyManager` instances coexist — each installs its own
/// `InstallEventHandler` and filters incoming events by its own
/// `EventHotKeyID.id`. Without that filter, every manager would fire on every
/// registered hotkey across the whole app, since Carbon broadcasts every
/// `kEventHotKeyPressed` to every installed handler regardless of which
/// hotkey matched.
@MainActor
final class HotkeyManager {
    private var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    /// Unique id within the `BRDG` signature for THIS manager's hotkey, so the
    /// shared event-handler signal can be filtered down to "is this me?".
    private var hotKeyIDValue: UInt32 = 0

    /// Auto-incremented id assigner. Each `register()` call gets a fresh id,
    /// so two managers never collide on the same `EventHotKeyID`.
    private static var nextHotKeyIDValue: UInt32 = 1

    /// Register a global hotkey. Modifiers use NSEvent.ModifierFlags.
    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        // Tear down any previous registration first so callers can re-register safely.
        unregister()
        self.handler = handler

        // Translate NSEvent modifier flags into Carbon's modifier mask.
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command)  { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.shift)    { carbonMods |= UInt32(shiftKey) }
        if modifiers.contains(.option)   { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control)  { carbonMods |= UInt32(controlKey) }

        // Install one event handler for hot-key-pressed events.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                // Read the EventHotKeyID off the incoming event so we can
                // filter out hotkey events that belong to a sibling
                // HotkeyManager instance. Carbon broadcasts every
                // kEventHotKeyPressed to every installed handler regardless
                // of which hotkey matched.
                var firedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                if status != noErr { return noErr }

                let myID = mgr.hotKeyIDValue
                if firedID.signature != fourCharCode("BRDG") || firedID.id != myID {
                    return noErr
                }

                // Hop back onto the main actor before calling user code.
                Task { @MainActor in
                    mgr.fire()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        if installStatus != noErr {
            NSLog("[Bridge] InstallEventHandler failed (status=%d)", installStatus)
            return
        }

        // Use a stable EventHotKeyID. Signature is the four-char-code 'BRDG'.
        // Bump the per-instance id so concurrent managers don't collide.
        let signature: OSType = fourCharCode("BRDG")
        let id = HotkeyManager.nextHotKeyIDValue
        HotkeyManager.nextHotKeyIDValue &+= 1
        hotKeyIDValue = id
        let hotKeyID = EventHotKeyID(signature: signature, id: id)

        var hkRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hkRef
        )

        if regStatus != noErr {
            NSLog("[Bridge] RegisterEventHotKey failed (status=%d, keyCode=%u, mods=0x%x)", regStatus, keyCode, carbonMods)
            // Roll back the event handler so we don't leak it.
            if let handlerRef = eventHandlerRef {
                RemoveEventHandler(handlerRef)
                eventHandlerRef = nil
            }
            return
        }

        hotKeyRef = hkRef
        NSLog("[Bridge] Hotkey registered (keyCode=%u, mods=0x%x, id=%u)", keyCode, carbonMods, id)
    }

    func unregister() {
        if let hkRef = hotKeyRef {
            UnregisterEventHotKey(hkRef)
            hotKeyRef = nil
        }
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
        handler = nil
        hotKeyIDValue = 0
    }

    fileprivate func fire() {
        handler?()
    }
}

/// Build a Carbon four-char-code from an ASCII string. Pads / truncates to 4 bytes.
private func fourCharCode(_ s: String) -> OSType {
    let bytes = Array(s.utf8.prefix(4))
    var code: OSType = 0
    for b in bytes {
        code = (code << 8) | OSType(b)
    }
    // If shorter than 4 chars, left-shift remaining bytes as zeros (already done by loop).
    if bytes.count < 4 {
        code <<= UInt32(8 * (4 - bytes.count))
    }
    return code
}
