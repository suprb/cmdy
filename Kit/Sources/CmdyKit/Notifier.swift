import AppKit
import UserNotifications

/// Posts "finished while you were away" alerts. Always bounces the dock; adds a
/// real notification banner when running from a bundled .app (UNUserNotification
/// requires a bundle identifier — `swift run` from the CLI has none).
public enum Notifier {
    nonisolated(unsafe) private static var authRequested = false
    // Internal interception point for package tests. Production always leaves
    // this nil, so the exact public post path continues through AppKit and
    // UserNotifications. Tests can observe delivery without prompting the
    // machine running the suite for notification permission.
    nonisolated(unsafe) static var postObserverForTesting:
        ((String, String) -> Void)?

    public static func post(title: String, body: String) {
        let filtered: (String, String)?
        if Thread.isMainThread {
            filtered = MainActor.assumeIsolated {
                applyingExtensionPolicy(title: title, body: body)
            }
        } else {
            filtered = DispatchQueue.main.sync {
                applyingExtensionPolicy(title: title, body: body)
            }
        }
        guard let (title, body) = filtered else { return }
        if let observer = postObserverForTesting {
            observer(title, body)
            return
        }

        NSApp.requestUserAttention(.informationalRequest)   // dock bounce
        guard Bundle.main.bundleIdentifier != nil else {
            NSSound(named: "Glass")?.play()
            return
        }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
        if authRequested {
            deliver()
        } else {
            authRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { deliver() }
            }
        }
    }

    @MainActor
    private static func applyingExtensionPolicy(title: String, body: String)
        -> (String, String)? {
        let decision = PluginManager.shared.decide(.notification, payload: [
            "title": title,
            "body": body,
        ])
        switch decision.action {
        case .continue: return (title, body)
        case .replace: return (title, decision.value ?? body)
        case .cancel: return nil
        }
    }
}
