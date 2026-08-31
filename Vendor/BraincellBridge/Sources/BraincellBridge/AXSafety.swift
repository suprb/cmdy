import ApplicationServices
import CoreGraphics

/// Checked bridges for the untyped Core Foundation values returned by the
/// Accessibility API. External apps can expose missing or unexpected values;
/// those should fail an action, not crash the Bridge process.
enum AXSafety {
    static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    static func value(_ ref: CFTypeRef?, type: AXValueType) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(ref, to: AXValue.self)
        return AXValueGetType(value) == type ? value : nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = value(positionRef, type: .cgPoint),
              let sizeValue = value(sizeRef, type: .cgSize) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000,
              size.width > 0, size.height > 0,
              size.width <= 1_000_000, size.height <= 1_000_000 else { return nil }
        return CGRect(origin: position, size: size)
    }
}
