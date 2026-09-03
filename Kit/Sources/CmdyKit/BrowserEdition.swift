import AppKit
import ProductIdentity

/// How an app-owned host component is distributed in the running build.
/// Browser uses this to stay discoverable without pretending that its signed
/// Chromium payload is a normal Marketplace Extension archive.
public enum HostComponentDistribution: Equatable, Sendable {
    case unavailable
    case external
    case bundled
}

public enum BrowserEdition {
    public static let hostComponentIdentifier = "embedded-chromium"

    public static func downloadURL(
        for identity: ProductIdentity = .current
    ) -> URL {
        URL(string:
            "https://github.com/\(identity.githubRepository)/releases/latest/download/"
                + "\(identity.releaseAssetPrefix)-browser-macOS-arm64.dmg")!
    }

    public static var guide: CmdyProductGuide {
        let product = ProductIdentity.current.titleName
        return CmdyProductGuide(
            whatItDoes: [
                "Adds a Chromium browser directly beside your terminal panes.",
                "Keeps Browser navigation, screenshots, and developer tools inside the signed \(product) app.",
            ],
            safety: [
                "Chromium must be sealed inside the signed app bundle, so Browser is distributed as a complete Browser edition rather than a mutable Extension ZIP.",
                "Installing the Browser edition replaces only the app in Applications; your settings, sessions, and Extensions stay in your user configuration directory.",
            ],
            setup: [
                "Download the Browser edition DMG, replace your existing \(product) app, and reopen it.",
            ])
    }

    enum RowState: Equatable {
        case notInstalled
        case included
    }

    static func rowState(
        distribution: HostComponentDistribution,
        hasExternalInstall: Bool
    ) -> RowState? {
        if distribution == .bundled { return .included }
        if hasExternalInstall { return nil }
        return .notInstalled
    }
}

/// Shared recovery prompt used by both the Extensions picker and the toolbar.
@MainActor
public enum BrowserEditionInstaller {
    private static var activeAlert: NSAlert?

    public static func presentDownloadPrompt(relativeTo window: NSWindow?) {
        guard activeAlert == nil else { return }
        let product = ProductIdentity.current.titleName
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Browser isn't installed"
        alert.informativeText =
            "Browser is included in a separately signed \(product) Browser edition. "
            + "Download it, replace the current app in Applications, and reopen \(product). "
            + "Your settings, sessions, and Extensions stay in place."
        alert.addButton(withTitle: "Download Browser Edition")
        alert.addButton(withTitle: "Cancel")
        activeAlert = alert

        let download = {
            _ = NSWorkspace.shared.open(BrowserEdition.downloadURL())
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                activeAlert = nil
                if response == .alertFirstButtonReturn { download() }
            }
        } else {
            let response = alert.runModal()
            activeAlert = nil
            if response == .alertFirstButtonReturn { download() }
        }
    }

    /// Read-only seams for the assembled lean-app smoke test. They exercise
    /// the same NSAlert and buttons a person sees without opening a browser or
    /// changing any installation state.
    public static func promptDiagnosticForTesting() -> (
        message: String, information: String, buttons: [String],
        downloadURL: String
    )? {
        guard let activeAlert else { return nil }
        return (
            activeAlert.messageText,
            activeAlert.informativeText,
            activeAlert.buttons.map(\.title),
            BrowserEdition.downloadURL().absoluteString)
    }

    @discardableResult
    public static func pressPromptButtonForTesting(at index: Int) -> Bool {
        guard let activeAlert, activeAlert.buttons.indices.contains(index) else {
            return false
        }
        activeAlert.buttons[index].performClick(nil)
        return true
    }
}
