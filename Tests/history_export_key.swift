import CoreGraphics

// Enter is resolved by physical key code in CMDY's normal imported shortcut
// dispatcher. This avoids shifted-digit text/layout ambiguity in this pilot.
enum HistoryExportKey {
    static let code: CGKeyCode = 36
    static let flags: CGEventFlags = [.maskControl, .maskShift]
    static let shortcut = "ctrl+shift+enter"
    static let intendedAction = "write_scrollback_file:paste"
    static func action(verificationPolicy: String?, exportCase: String?) -> String? {
        if verificationPolicy == nil && exportCase == nil { return intendedAction }
        guard verificationPolicy == "post-sample-public-history-v1" else { return nil }
        switch exportCase {
        case "primary-1000", "primary-5000": return intendedAction
        case "alternate-continuous": return "write_screen_file:paste"
        default: return nil
        }
    }
}
