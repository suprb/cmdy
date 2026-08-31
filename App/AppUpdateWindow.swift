import AppKit
import ProductIdentity
import CmdyKit

/// A reviewed handoff for an update that cmdy may already have downloaded and
/// checksum-verified. The running app is never replaced and downloaded code is
/// never executed automatically.
@MainActor
final class AppUpdateWindow: NSObject, NSWindowDelegate {
    static let shared = AppUpdateWindow()

    private weak var parentWindow: NSWindow?
    private var panel: NSPanel?
    private var release: AppReleaseUpdate?
    private var explanationLabel: NSTextField?
    private var primaryButton: NSButton?
    private var progressIndicator: NSProgressIndicator?
    private var updateObservation: NSObjectProtocol?

    private override init() {
        super.init()
        updateObservation = NotificationCenter.default.addObserver(
            forName: .cmdyAppUpdateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStateChanged() }
        }
    }

    func show(relativeTo parent: NSWindow?) {
        guard let update = AppUpdateMonitor.shared.availableUpdate else { return }
        dismiss()
        release = update

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        let product = ProductIdentity.current.titleName
        panel.title = "\(product) Update"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]

        let title = NSTextField(
            labelWithString: "\(product) \(update.version) is ready")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let current = AppUpdateMonitor.shared.currentVersion ?? "Unknown"
        let version = NSTextField(labelWithString: "VERSION  \(current)  →  \(update.version)")
        version.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        version.textColor = .tertiaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(wrappingLabelWithString: "")
        explanation.font = .systemFont(ofSize: 12.5)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 4
        explanation.translatesAutoresizingMaskIntoConstraints = false
        explanationLabel = explanation

        let later = NSButton(title: "Later", target: self, action: #selector(closePressed))
        let notes = NSButton(title: "Release Notes", target: self, action: #selector(notesPressed))
        let download = NSButton(title: "Download Update", target: self,
                                action: #selector(downloadPressed))
        download.keyEquivalent = "\r"
        primaryButton = download
        for button in [later, notes, download] {
            button.bezelStyle = .rounded
        }
        let buttons = NSStackView(views: [later, notes, download])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator = progress

        root.addSubview(title)
        root.addSubview(version)
        root.addSubview(explanation)
        root.addSubview(progress)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            version.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            version.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            version.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            explanation.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 20),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            progress.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])

        panel.contentView = root
        self.panel = panel
        parentWindow = parent
        refreshDownloadState()
        if let parent, parent.isVisible {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        release = nil
        parentWindow = nil
        explanationLabel = nil
        primaryButton = nil
        progressIndicator = nil
    }

    @objc private func downloadPressed() {
        guard let release else { return }
        switch AppUpdateMonitor.shared.downloadState {
        case .ready(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            dismiss()
        case .failed:
            AppUpdateMonitor.shared.retryAutomaticDownload()
        case .downloading:
            break
        case .idle:
            if release.canDownloadAutomatically {
                AppUpdateMonitor.shared.retryAutomaticDownload()
            } else {
                NSWorkspace.shared.open(release.downloadURL)
                dismiss()
            }
        }
    }

    @objc private func notesPressed() {
        guard let release else { return }
        NSWorkspace.shared.open(release.releaseURL)
    }

    @objc private func closePressed() {
        dismiss()
    }

    private func dismiss() {
        guard let panel else { return }
        if let parent = panel.sheetParent ?? parentWindow {
            parent.endSheet(panel)
        }
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        release = nil
        parentWindow = nil
        explanationLabel = nil
        primaryButton = nil
        progressIndicator = nil
    }

    private func updateStateChanged() {
        guard panel != nil else { return }
        guard let update = AppUpdateMonitor.shared.availableUpdate else {
            dismiss()
            return
        }
        release = update
        refreshDownloadState()
    }

    private func refreshDownloadState() {
        guard let release, let explanationLabel, let primaryButton,
              let progressIndicator else { return }
        let product = ProductIdentity.current.displayName
        switch AppUpdateMonitor.shared.downloadState {
        case .idle:
            progressIndicator.stopAnimation(nil)
            primaryButton.isEnabled = true
            if release.canDownloadAutomatically {
                explanationLabel.stringValue =
                    "A signed macOS build is available. cmdy will download the ZIP "
                    + "and verify its published SHA-256 checksum before showing it."
                primaryButton.title = "Download Update"
            } else {
                explanationLabel.stringValue =
                    "This release does not include a matching ZIP and checksum. "
                    + "Open the official GitHub Release to download it manually."
                primaryButton.title = "Open Release"
            }
        case .downloading:
            progressIndicator.startAnimation(nil)
            explanationLabel.stringValue =
                "Downloading \(product) \(release.version) from the official GitHub "
                + "Release. The archive will be kept only if its SHA-256 checksum passes."
            primaryButton.title = "Downloading…"
            primaryButton.isEnabled = false
        case .ready:
            progressIndicator.stopAnimation(nil)
            explanationLabel.stringValue =
                "The update downloaded automatically and its SHA-256 checksum passed. "
                + "Show it in Finder when you are ready to replace the app."
            primaryButton.title = "Show in Finder"
            primaryButton.isEnabled = true
        case .failed(let message):
            progressIndicator.stopAnimation(nil)
            explanationLabel.stringValue =
                "The automatic download stopped safely: \(message)"
            primaryButton.title = "Try Again"
            primaryButton.isEnabled = true
        }
    }
}
