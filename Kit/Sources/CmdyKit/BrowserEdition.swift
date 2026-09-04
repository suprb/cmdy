import AppKit
import ProductIdentity

public enum BrowserEdition {
    public static let hostComponentIdentifier = "embedded-chromium"
    public static let marketplaceID = "dev.termite.chromium"

    public static func authorizesHostComponent(
        _ identifier: String,
        manifest: ExtensionManifest
    ) -> Bool {
        identifier == hostComponentIdentifier && manifest.id == marketplaceID
    }

    public static var bundledRuntimeVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CMDYBrowserVersion") as? String
    }

    public static var isBundledEnabledByDefault: Bool {
        Bundle.main.object(
            forInfoDictionaryKey: "CMDYBrowserEnabledByDefault") as? Bool == true
    }

    /// The stable v1 ID is retained so old Browser installs upgrade in place.
    public static var isActivationInstalled: Bool {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: PluginManager.pluginsDirectory,
            includingPropertiesForKeys: nil)) ?? []
        return directories.contains { directory in
            (try? ExtensionManifest.load(from: directory).id) == marketplaceID
        }
    }

    /// Browser-edition users from before the unified app automatically receive
    /// the same removable activation record as a fresh Marketplace install.
    /// The CEF payload remains sealed in cmdy.app; deleting this directory is
    /// therefore a real uninstall of the capability without mutating the app.
    @discardableResult
    public static func ensureBundledActivationInstalled(force: Bool = false) -> Bool {
        guard force || isBundledEnabledByDefault,
              let version = bundledRuntimeVersion,
              !isActivationInstalled else { return false }
        let root = PluginManager.extensionsDirectory
        let destination = root.appendingPathComponent("chromium", isDirectory: true)
        let staging = root.appendingPathComponent(
            ".chromium-migration-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let executable = staging.appendingPathComponent("browser-component")
            try "#!/bin/sh\nexit 0\n".write(
                to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
            guard let bundledMCP = Bundle.main.resourceURL?
                    .appendingPathComponent("BrowserMCP", isDirectory: true),
                  FileManager.default.fileExists(
                    atPath: bundledMCP.appendingPathComponent("index.js").path)
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            try FileManager.default.copyItem(
                at: bundledMCP,
                to: staging.appendingPathComponent("mcp", isDirectory: true))
            let manifest = try ExtensionManifest(
                id: marketplaceID,
                name: "Browser",
                version: version,
                entrypoint: executable.lastPathComponent,
                capabilities: [],
                hostComponent: hostComponentIdentifier,
                description: "Chromium browsing in a real cmdy window split",
                guide: guide,
                homepage: "https://github.com/suprb/cmdy/tree/main/Plugins/chromium")
            try manifest.encoded().write(
                to: staging.appendingPathComponent("manifest.json"))
            try FileManager.default.moveItem(at: staging, to: destination)
            return true
        } catch {
            NSLog("Browser activation migration failed: %@", error.localizedDescription)
            return false
        }
    }

    public static var guide: CmdyProductGuide {
        let product = ProductIdentity.current.titleName
        return CmdyProductGuide(
            whatItDoes: [
                "Adds a Chromium browser as a real split inside each \(product) window.",
                "Lets you and local agents navigate, inspect, annotate, and capture the visible page.",
            ],
            safety: [
                "The visible browser is built into \(product); only Chromium's sandbox workers run as signed helper processes.",
                "Disable or remove Browser from Extensions to close its splits and delete its activation record.",
            ],
            setup: [
                "Choose Install. \(product) downloads, verifies, and turns on the integrated Browser for you.",
            ])
    }

}

/// Shared one-click install prompt used by Browser toolbar actions.
@MainActor
public enum BrowserEditionInstaller {
    private static var activeAlert: NSAlert?

    public static func presentInstallPrompt(relativeTo window: NSWindow?) {
        guard activeAlert == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Browser isn't installed"
        alert.informativeText = BrowserEdition.guide.plainText
        alert.addButton(withTitle: "Install Browser")
        alert.addButton(withTitle: "Cancel")
        activeAlert = alert

        let install = {
            PluginsWindow.shared.installMarketplaceExtension(
                id: BrowserEdition.marketplaceID)
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                activeAlert = nil
                if response == .alertFirstButtonReturn { install() }
            }
        } else {
            let response = alert.runModal()
            activeAlert = nil
            if response == .alertFirstButtonReturn { install() }
        }
    }

    /// Read-only seams for the assembled app smoke test. They exercise
    /// the same NSAlert and buttons a person sees without opening a browser or
    /// changing any installation state.
    public static func promptDiagnosticForTesting() -> (
        message: String, information: String, buttons: [String],
        marketplaceID: String
    )? {
        guard let activeAlert else { return nil }
        return (
            activeAlert.messageText,
            activeAlert.informativeText,
            activeAlert.buttons.map(\.title),
            BrowserEdition.marketplaceID)
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
