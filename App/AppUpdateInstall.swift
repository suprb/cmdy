import AppKit
import ProductIdentity
import CmdyKit

/// Restart to update: the downloaded, checksum-verified release is checked
/// again for this app's Developer ID Team ID and Gatekeeper acceptance, staged
/// beside the app, and swapped in by the signed restart helper after cmdy
/// quits. The helper relaunches the new version and restores the old one
/// unless it confirms a clean start.
@MainActor
enum AppUpdateInstall {
    private(set) static var isInstalling = false

    static func restartToUpdate(relativeTo parent: NSWindow?) {
        guard !isInstalling,
              let release = AppUpdateMonitor.shared.availableUpdate,
              case .ready(let archive) = AppUpdateMonitor.shared.downloadState else { return }
        isInstalling = true
        NotificationCenter.default.post(name: .cmdyAppUpdateChanged, object: nil)
        let version = release.version
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try BrowserComponentInstaller.prepareAppUpdate(archive: archive, version: version)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    finish(result, archive: archive, version: version, parent: parent)
                }
            }
        }
    }

    private static func finish(
        _ result: Result<BrowserComponentInstaller.PreparedSwitch, Error>,
        archive: URL, version: String, parent: NSWindow?
    ) {
        do {
            let prepared = try result.get()
            do {
                try BrowserComponentInstaller.scheduleAppUpdate(prepared)
            } catch {
                BrowserComponentInstaller.discardAppUpdate(prepared)
                throw error
            }
            // Normal quit policy still applies; cancelling the quit lets the
            // helper time out and keep the installed version.
            BrowserComponentInstaller.requestRelaunchIfScheduled()
            isInstalling = false
        } catch {
            isInstalling = false
            NotificationCenter.default.post(name: .cmdyAppUpdateChanged, object: nil)
            let alert = NSAlert()
            alert.messageText = "Couldn’t install \(ProductIdentity.current.displayName) \(version)"
            alert.informativeText = "\(error.localizedDescription) "
                + "The downloaded update is still available to install by hand."
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([archive])
                }
            }
            if let parent, parent.isVisible {
                alert.beginSheetModal(for: parent, completionHandler: handle)
            } else {
                handle(alert.runModal())
            }
        }
    }
}
