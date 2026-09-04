import AppKit
import CryptoKit
import Darwin
import Foundation
import ProductIdentity

/// The two complete, notarized app layouts published for every release.
///
/// CEF cannot currently be loaded from an arbitrary per-user Extension folder
/// without breaking its macOS sandbox assumptions. Browser installation is
/// therefore a verified switch between a lean app and the same app with CEF
/// sealed in Contents/Frameworks. The user's activation record remains a
/// normal removable Extension.
public enum BrowserComponentVariant: String, Codable, Sendable {
    case lean
    case browser
}

public enum BrowserComponentSwitchError: LocalizedError {
    case appBundleNotFound
    case appIsNotReplaceable(String)
    case releaseUnavailable(String)
    case invalidArchive(String)
    case invalidApplication(String)
    case helperLaunchFailed(String)
    case switchAlreadyPending
    case recoveryRequired(String)

    public var errorDescription: String? {
        switch self {
        case .appBundleNotFound:
            return "Browser can be installed after cmdy.app is copied to Applications."
        case .appIsNotReplaceable(let message):
            return "cmdy.app cannot be updated in place: \(message)"
        case .releaseUnavailable(let message):
            return "The Browser download is unavailable: \(message)"
        case .invalidArchive(let message):
            return "The Browser download is invalid: \(message)"
        case .invalidApplication(let message):
            return "The downloaded cmdy.app was refused: \(message)"
        case .helperLaunchFailed(let message):
            return "Could not restart cmdy to finish the Browser change: \(message)"
        case .switchAlreadyPending:
            return "A Browser install or removal is already waiting for cmdy to restart."
        case .recoveryRequired(let message):
            return "A previous Browser change needs recovery: \(message)"
        }
    }
}

public enum BrowserComponentInstaller {
    public static let helperArgument = "--browser-component-swap-helper"
    public static let confirmationArgument = "--browser-component-switch-confirm"

    public struct PreparedSwitch: @unchecked Sendable {
        public let variant: BrowserComponentVariant
        public let version: String
        public let build: String
        public let browserVersion: String?
        public let downloadedBytes: Int
        public let requiresRelaunch: Bool

        fileprivate let destinationApp: URL
        fileprivate let stagedApp: URL?
        fileprivate let helperExecutable: URL?
        fileprivate let helperDirectory: URL?
        fileprivate let transactionURL: URL
        fileprivate let lockDirectory: URL
        fileprivate let token: String
    }

    enum ActivationChangeKind: String, Codable {
        case installed
        case removed
    }

    struct ActivationChange: Codable, Equatable {
        let kind: ActivationChangeKind
        let rootPath: String
        let destinationPath: String
        let backupPath: String?
    }

    enum TransactionState: String, Codable {
        case staged
        case awaitingConfirmation
        case confirmed
        case completed
        case failed
        case recoveryRequired
    }

    struct Transaction: Codable, Equatable {
        let schemaVersion: Int
        let token: String
        let variant: BrowserComponentVariant
        let destinationAppPath: String
        let stagedAppPath: String
        let backupAppPath: String
        let helperDirectoryPath: String
        let lockDirectoryPath: String
        let bundleIdentifier: String
        let candidateVersion: String
        let candidateBuild: String
        let waitingPIDs: [Int32]
        var originalInspection: BundleInspection? = nil
        let activation: ActivationChange?
        let browserComponentVersion: String?
        let createdAt: TimeInterval
        /// Used only by the packaged-app lifecycle smoke so the relaunched UI
        /// process does not outlive a headless CI job. Production transactions
        /// always encode false.
        let testOnlyExitAfterConfirmation: Bool?
        let testOnlySuppressConfirmation: Bool?
        let testOnlyConfirmationTimeoutSeconds: TimeInterval?
        var state: TransactionState
        var message: String?
    }

    private struct SwitchLock: Codable {
        let schemaVersion: Int
        let token: String
        let transactionPath: String
        let ownerPID: Int32
        let ownerExecutablePath: String?
        let createdAt: TimeInterval
        let activation: ActivationChange?
    }

    struct BundleInspection: Codable, Equatable {
        let identifier: String
        let executable: String
        let version: String
        let build: String
        let browserEdition: Bool
        let browserVersion: String?
        let hasBrowserRuntime: Bool
        let containsBrowserPayload: Bool
        let teamIdentifier: String?
        let developerIDSigned: Bool
        let hardenedRuntime: Bool
    }

    private final class PendingState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (
            variant: BrowserComponentVariant,
            version: String,
            transactionURL: URL,
            token: String
        )?

        func set(
            variant: BrowserComponentVariant,
            version: String,
            transactionURL: URL,
            token: String
        ) {
            lock.lock()
            value = (variant, version, transactionURL, token)
            lock.unlock()
        }

        func clear(token: String) {
            lock.lock()
            if value?.token == token { value = nil }
            lock.unlock()
        }

        var snapshot: (
            variant: BrowserComponentVariant,
            version: String,
            transactionURL: URL,
            token: String
        )? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class LaunchResult: @unchecked Sendable {
        private let lock = NSLock()
        private var application: NSRunningApplication?
        private var error: Error?

        func complete(_ application: NSRunningApplication?, _ error: Error?) {
            lock.lock()
            self.application = application
            self.error = error
            lock.unlock()
        }

        func snapshot() -> (NSRunningApplication?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (application, error)
        }
    }

    private static let pendingState = PendingState()
    private static let maximumReleaseBytes = 1_048_576
    private static let maximumArchiveBytes = 1024 * 1024 * 1024
    private static let helperWaitSeconds: TimeInterval = 60
    private static let confirmationWaitSeconds: TimeInterval = 90
    private static let staleLockSeconds: TimeInterval = 20 * 60
    private static let abandonedLockGraceSeconds: TimeInterval = 2

    public static var relaunchWasScheduled: Bool {
        refreshPendingState()
        return pendingState.snapshot != nil
    }

    public static var scheduledDescription: String? {
        refreshPendingState()
        guard let pending = pendingState.snapshot else { return nil }
        let action = pending.variant == .browser ? "install Browser" : "remove Browser"
        return "Restarting cmdy \(pending.version) to \(action)"
    }

    public static var currentBundleIsBrowserEdition: Bool {
        guard let app = currentAppBundleURL() else { return false }
        return browserEditionMarker(in: app)
    }

    public static func currentBundleNeedsBrowserSwitch(
        requiredBrowserVersion: String
    ) -> Bool {
        guard let app = currentAppBundleURL() else { return true }
        return needsSwitch(
            to: .browser,
            browserEdition: browserEditionMarker(in: app),
            browserVersion: browserVersionMarker(in: app),
            requiredBrowserVersion: requiredBrowserVersion,
            hasRuntime: hasBrowserRuntime(in: app),
            containsRuntimePayload: containsBrowserPayload(in: app))
    }

    public static var currentBundleHasBrowserRuntime: Bool {
        guard let app = currentAppBundleURL() else { return false }
        return hasBrowserRuntime(in: app)
    }

    public static var currentBundleContainsBrowserPayload: Bool {
        guard let app = currentAppBundleURL() else { return false }
        return containsBrowserPayload(in: app)
    }

    static func needsSwitch(
        to variant: BrowserComponentVariant,
        browserEdition: Bool,
        browserVersion: String? = nil,
        requiredBrowserVersion: String? = nil,
        hasRuntime: Bool,
        containsRuntimePayload: Bool
    ) -> Bool {
        switch variant {
        case .browser:
            let versionNeedsSwitch = requiredBrowserVersion.map {
                !browserVersionSatisfies(browserVersion, minimum: $0)
            } ?? false
            return !browserEdition || !hasRuntime
                || versionNeedsSwitch
        case .lean:
            return browserEdition || containsRuntimePayload
        }
    }

    /// Download, hash, extract, inspect, and stage the requested complete app.
    /// The installed app and Extension activation are untouched until the
    /// caller has completed its own operation and schedules the helper.
    public static func prepareSwitch(
        to variant: BrowserComponentVariant,
        requiredBrowserVersion: String? = nil,
        progress: (String) -> Void = { _ in }
    ) throws -> PreparedSwitch {
        refreshPendingState()
        guard pendingState.snapshot == nil else {
            throw BrowserComponentSwitchError.switchAlreadyPending
        }
        guard let currentApp = currentAppBundleURL() else {
            throw BrowserComponentSwitchError.appBundleNotFound
        }
        let current = try inspectBundle(at: currentApp)
        if variant == .browser {
            guard let requiredBrowserVersion,
                  requiredBrowserVersion.split(separator: ".").count == 3,
                  AppUpdateMonitor.isNumericVersion(requiredBrowserVersion) else {
                throw BrowserComponentSwitchError.releaseUnavailable(
                    "the Browser component version is missing or invalid")
            }
        }

        // Reserve the single cross-process switch slot before deciding this is
        // a no-op. Another cmdy CLI or GUI process may already be changing the
        // opposite variant while the on-disk app still looks unchanged.
        let transactionDirectory = ConfigFile.directory
        try FileManager.default.createDirectory(
            at: transactionDirectory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let transactionURL = transactionDirectory.appendingPathComponent(
            "browser-component-switch-\(token).json")
        // Browser app swaps and activation changes share one per-user lease.
        // It deliberately follows neither CMDY_CONFIG_DIR nor the app copy:
        // processes with different configs can target one app, while different
        // app copies normally still share the user's activation directory.
        let lockDirectory = switchLockDirectory()
        try FileManager.default.createDirectory(
            at: lockDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try acquireSwitchLock(
            at: lockDirectory,
            token: token,
            transactionURL: transactionURL)
        var preparedOwnsLock = false
        defer {
            if !preparedOwnsLock {
                releaseSwitchLock(at: lockDirectory, token: token)
            }
        }

        let requiresRelaunch = needsSwitch(
            to: variant,
            browserEdition: current.browserEdition,
            browserVersion: current.browserVersion,
            requiredBrowserVersion: requiredBrowserVersion,
            hasRuntime: current.hasBrowserRuntime,
            containsRuntimePayload: current.containsBrowserPayload
        )
        if !requiresRelaunch {
            let prepared = PreparedSwitch(
                variant: variant,
                version: current.version,
                build: current.build,
                browserVersion: variant == .browser ? current.browserVersion : nil,
                downloadedBytes: 0,
                requiresRelaunch: false,
                destinationApp: currentApp,
                stagedApp: nil,
                helperExecutable: nil,
                helperDirectory: nil,
                transactionURL: transactionURL,
                lockDirectory: lockDirectory,
                token: token)
            preparedOwnsLock = true
            return prepared
        }

        let parent = currentApp.deletingLastPathComponent()
        let appValues = try currentApp.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard appValues.isDirectory == true, appValues.isSymbolicLink != true else {
            throw BrowserComponentSwitchError.appIsNotReplaceable(
                "the running app is not a real local application bundle")
        }
        guard parent.path != "/", FileManager.default.isWritableFile(atPath: parent.path) else {
            throw BrowserComponentSwitchError.appIsNotReplaceable(
                "move cmdy.app to Applications or another folder you can write to")
        }
        progress("finding the signed \(variant == .browser ? "Browser" : "lean") build…")
        let releaseData = try Marketplace.fetchData(
            ProductIdentity.current.latestReleaseAPIURL,
            maxBytes: maximumReleaseBytes,
            timeout: 30)
        guard let release = try AppUpdateMonitor.decodeRelease(
            releaseData,
            prefersBrowserEdition: variant == .browser,
            requiredBrowserComponentVersion: requiredBrowserVersion),
              let assetURL = release.assetURL,
              let assetName = release.assetName,
              let checksumURL = release.checksumURL,
              release.canDownloadAutomatically else {
            throw BrowserComponentSwitchError.releaseUnavailable(
                "the latest release does not contain the required app variant")
        }
        guard versionIsSameOrNewer(release.version, than: current.version) else {
            throw BrowserComponentSwitchError.releaseUnavailable(
                "release \(release.version) is older than installed version \(current.version)")
        }

        let checksumData = try Marketplace.fetchData(
            checksumURL, maxBytes: 8 * 1024, timeout: 30)
        guard let expectedChecksum = AppUpdateMonitor.expectedChecksum(
            from: checksumData, assetName: assetName) else {
            throw BrowserComponentSwitchError.releaseUnavailable(
                "the release checksum is missing or does not name \(assetName)")
        }

        progress(variant == .browser
            ? "downloading Chromium and the signed Browser build…"
            : "downloading the signed lean build…")
        let archive = try Marketplace.fetchData(
            assetURL, maxBytes: maximumArchiveBytes, timeout: 600)
        let actualChecksum = SHA256.hash(data: archive)
            .map { String(format: "%02x", $0) }.joined()
        guard actualChecksum == expectedChecksum else {
            throw BrowserComponentSwitchError.invalidArchive(
                "SHA-256 mismatch; no downloaded code was installed")
        }
        progress("download checksum verified ✓")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmdy-component-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archiveURL = temporary.appendingPathComponent(assetName)
        try archive.write(to: archiveURL, options: .atomic)
        try Marketplace.validateArchivePaths(archiveURL)
        let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Marketplace.run("/usr/bin/ditto", "-x", "-k", archiveURL.path, extracted.path)

        let candidates = try FileManager.default.contentsOfDirectory(
            at: extracted,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])
            .filter { $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw BrowserComponentSwitchError.invalidArchive(
                "the release ZIP must contain exactly one top-level .app")
        }
        try Marketplace.validateExtractedTree(candidate, inside: extracted)
        let candidateInspection = try validateCandidate(
            candidate,
            replacing: currentApp,
            expectedVariant: variant,
            minimumVersion: current.version,
            requiredBrowserVersion: requiredBrowserVersion)
        progress("Developer ID, Team ID, and app layout verified ✓")

        let stagedApp = parent.appendingPathComponent(
            ".cmdy-component-stage-\(UUID().uuidString).app", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: candidate, to: stagedApp)
            _ = try validateCandidate(
                stagedApp,
                replacing: currentApp,
                expectedVariant: variant,
                minimumVersion: current.version,
                requiredBrowserVersion: requiredBrowserVersion)
        } catch {
            try? FileManager.default.removeItem(at: stagedApp)
            throw error
        }

        let helperDirectory = componentCacheDirectory().appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: helperDirectory, withIntermediateDirectories: true)
            guard let runningExecutable = runningExecutableURL() else {
                throw BrowserComponentSwitchError.appBundleNotFound
            }
            let helper = helperDirectory.appendingPathComponent("cmdy-component-helper")
            try FileManager.default.copyItem(at: runningExecutable, to: helper)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: helper.path)
            guard try AppUpdateMonitor.sha256(of: runningExecutable)
                    == AppUpdateMonitor.sha256(of: helper) else {
                throw BrowserComponentSwitchError.helperLaunchFailed(
                    "the restart helper copy did not match the running executable")
            }
            progress("ready to restart and \(variant == .browser ? "install" : "remove") Browser ✓")
            let prepared = PreparedSwitch(
                variant: variant,
                version: release.version,
                build: candidateInspection.build,
                browserVersion: variant == .browser
                    ? candidateInspection.browserVersion : nil,
                downloadedBytes: archive.count,
                requiresRelaunch: true,
                destinationApp: currentApp,
                stagedApp: stagedApp,
                helperExecutable: helper,
                helperDirectory: helperDirectory,
                transactionURL: transactionURL,
                lockDirectory: lockDirectory,
                token: token)
            preparedOwnsLock = true
            return prepared
        } catch {
            try? FileManager.default.removeItem(at: stagedApp)
            try? FileManager.default.removeItem(at: helperDirectory)
            throw error
        }
    }

    static func discard(_ prepared: PreparedSwitch) {
        if let stagedApp = prepared.stagedApp {
            try? FileManager.default.removeItem(at: stagedApp)
        }
        if let helperDirectory = prepared.helperDirectory {
            try? FileManager.default.removeItem(at: helperDirectory)
        }
        releaseSwitchLock(at: prepared.lockDirectory, token: prepared.token)
    }

    static func beginInstalledActivation(
        _ prepared: PreparedSwitch,
        destination: URL,
        previousBackup: URL?
    ) throws -> ActivationChange {
        let change = ActivationChange(
            kind: .installed,
            rootPath: PluginManager.pluginsDirectory.path,
            destinationPath: destination.path,
            backupPath: previousBackup?.path)
        try recordActivationIntent(change, for: prepared)
        return change
    }

    static func completeWithoutRelaunch(
        _ prepared: PreparedSwitch,
        activation: ActivationChange
    ) throws {
        guard !prepared.requiresRelaunch,
              switchLockIsOwned(
                at: prepared.lockDirectory, token: prepared.token),
              activationChangeIsApplied(activation) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the Browser activation did not reach its verified commit state")
        }
        let inspection = try inspectBundle(at: prepared.destinationApp)
        let parent = prepared.destinationApp.deletingLastPathComponent()
        var transaction = Transaction(
            schemaVersion: 1,
            token: prepared.token,
            variant: prepared.variant,
            destinationAppPath: prepared.destinationApp.path,
            stagedAppPath: parent.appendingPathComponent(
                ".cmdy-component-stage-\(UUID().uuidString).app").path,
            backupAppPath: parent.appendingPathComponent(
                ".cmdy-component-backup-\(UUID().uuidString).app").path,
            helperDirectoryPath: componentCacheDirectory()
                .appendingPathComponent(UUID().uuidString).path,
            lockDirectoryPath: prepared.lockDirectory.path,
            bundleIdentifier: inspection.identifier,
            candidateVersion: inspection.version,
            candidateBuild: inspection.build,
            waitingPIDs: [],
            originalInspection: inspection,
            activation: activation,
            browserComponentVersion: prepared.variant == .browser
                ? inspection.browserVersion : nil,
            createdAt: Date().timeIntervalSince1970,
            testOnlyExitAfterConfirmation: false,
            testOnlySuppressConfirmation: false,
            testOnlyConfirmationTimeoutSeconds: nil,
            state: .confirmed,
            message: "Browser activation committed without an app swap")
        try write(transaction, to: prepared.transactionURL)
        do {
            try finalizeActivation(activation)
            transaction.state = .completed
            transaction.message = "Browser activation cleanup completed"
            try write(transaction, to: prepared.transactionURL)
            releaseSwitchLock(at: prepared.lockDirectory, token: prepared.token)
        } catch {
            transaction.state = .recoveryRequired
            transaction.message = "Browser activation committed, but cleanup is still pending: \(error.localizedDescription)"
            try? write(transaction, to: prepared.transactionURL)
            throw error
        }
    }

    /// Attach an Extension install to the already staged app switch. A previous
    /// activation backup remains beside the new activation until the relaunched
    /// app confirms that it started successfully.
    static func scheduleInstalledActivation(
        _ prepared: PreparedSwitch,
        activation: ActivationChange
    ) throws {
        try schedule(prepared, activation: activation)
    }

    /// Remove Browser's activation and, when needed, stage the lean app so the
    /// CEF bytes are actually deleted after a confirmed restart.
    /// Returns true when the caller must quit to let the helper finish.
    @discardableResult
    public static func removeBrowserActivation(
        at directory: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Bool {
        let manifest = try ExtensionManifest.load(from: directory)
        guard BrowserEdition.authorizesHostComponent(
            BrowserEdition.hostComponentIdentifier, manifest: manifest) else {
            try FileManager.default.removeItem(at: directory)
            return false
        }
        let prepared = try prepareSwitch(to: .lean, progress: progress)
        let backup = directory.deletingLastPathComponent().appendingPathComponent(
            ".browser-removal-backup-\(UUID().uuidString)", isDirectory: true)
        let change = ActivationChange(
            kind: .removed,
            rootPath: PluginManager.pluginsDirectory.path,
            destinationPath: directory.path,
            backupPath: backup.path)
        try recordActivationIntent(change, for: prepared)
        var leaseResolved = false
        defer {
            if !leaseResolved { discard(prepared) }
        }
        do {
            try FileManager.default.moveItem(at: directory, to: backup)
            if prepared.requiresRelaunch {
                try schedule(prepared, activation: change)
                leaseResolved = true
                return true
            }
            try completeWithoutRelaunch(prepared, activation: change)
            leaseResolved = true
            return false
        } catch {
            if leaseRequiresRecovery(prepared) {
                // A helper that could not be stopped still owns rollback. Keep
                // its lease and activation backup untouched so there is exactly
                // one recovery actor.
                leaseResolved = true
                throw error
            }
            do {
                try rollbackPreparedActivation(change)
            } catch let rollbackError {
                // Keep the activation intent and app-scoped lock intact. The
                // next launch can retry verified recovery without permitting a
                // conflicting install/remove.
                leaseResolved = true
                throw BrowserComponentSwitchError.helperLaunchFailed(
                    "removal failed (\(error.localizedDescription)); activation recovery also failed: \(rollbackError.localizedDescription)")
            }
            throw error
        }
    }

    private static func recordActivationIntent(
        _ activation: ActivationChange,
        for prepared: PreparedSwitch
    ) throws {
        guard validateActivationChange(activation),
              let record = try? readSwitchLock(at: prepared.lockDirectory),
              record.schemaVersion == 1,
              record.token == prepared.token,
              URL(fileURLWithPath: record.transactionPath).standardizedFileURL.path
                == prepared.transactionURL.standardizedFileURL.path else {
            throw BrowserComponentSwitchError.switchAlreadyPending
        }
        try writeSwitchLock(
            SwitchLock(
                schemaVersion: record.schemaVersion,
                token: record.token,
                transactionPath: record.transactionPath,
                ownerPID: record.ownerPID,
                ownerExecutablePath: record.ownerExecutablePath,
                createdAt: record.createdAt,
                activation: activation),
            at: prepared.lockDirectory)
    }

    private static func schedule(
        _ prepared: PreparedSwitch,
        activation: ActivationChange?
    ) throws {
        guard prepared.requiresRelaunch,
              let stagedApp = prepared.stagedApp,
              let helperExecutable = prepared.helperExecutable,
              let helperDirectory = prepared.helperDirectory else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the prepared app replacement is incomplete")
        }
        guard switchLockIsOwned(
            at: prepared.lockDirectory, token: prepared.token) else {
            throw BrowserComponentSwitchError.switchAlreadyPending
        }
        let current = try inspectBundle(at: prepared.destinationApp)
        let backup = prepared.destinationApp.deletingLastPathComponent()
            .appendingPathComponent(
                ".cmdy-component-backup-\(UUID().uuidString).app", isDirectory: true)
        let token = prepared.token
        let relatedBundleIdentifiers = [
            current.identifier,
            current.identifier + ".helper",
            current.identifier + ".helper.renderer",
            current.identifier + ".helper.gpu",
            current.identifier + ".helper.plugin",
        ]
        let relatedPIDs = relatedBundleIdentifiers.flatMap {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: $0).map(\.processIdentifier)
        }
        let runningPIDs = Set(relatedPIDs + [getpid()])
            .filter { $0 > 1 }
            .sorted()
        var transaction = Transaction(
            schemaVersion: 1,
            token: token,
            variant: prepared.variant,
            destinationAppPath: prepared.destinationApp.path,
            stagedAppPath: stagedApp.path,
            backupAppPath: backup.path,
            helperDirectoryPath: helperDirectory.path,
            lockDirectoryPath: prepared.lockDirectory.path,
            bundleIdentifier: current.identifier,
            candidateVersion: prepared.version,
            candidateBuild: prepared.build,
            waitingPIDs: runningPIDs,
            originalInspection: current,
            activation: activation,
            browserComponentVersion: prepared.browserVersion,
            createdAt: Date().timeIntervalSince1970,
            testOnlyExitAfterConfirmation: false,
            testOnlySuppressConfirmation: false,
            testOnlyConfirmationTimeoutSeconds: nil,
            state: .staged,
            message: nil)
        try FileManager.default.createDirectory(
            at: prepared.transactionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try write(transaction, to: prepared.transactionURL)

        let process = Process()
        process.executableURL = helperExecutable
        process.arguments = [helperArgument, prepared.transactionURL.path, token]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try updateSwitchLockOwner(
                at: prepared.lockDirectory,
                token: token,
                ownerPID: process.processIdentifier,
                ownerExecutableURL: helperExecutable)
        } catch {
            var helperStopped = true
            if process.isRunning {
                process.terminate()
                helperStopped = waitForProcessesToExit(
                    [process.processIdentifier], timeout: 5)
                if !helperStopped {
                    _ = kill(process.processIdentifier, SIGKILL)
                    helperStopped = waitForProcessesToExit(
                        [process.processIdentifier], timeout: 5)
                }
            }
            // The caller still owns activation rollback. Do not mark this
            // terminal or release the lease before that rollback verifies.
            transaction.state = helperStopped ? .staged : .recoveryRequired
            transaction.message = "restart helper could not launch: \(error.localizedDescription)"
            try? write(transaction, to: prepared.transactionURL)
            throw BrowserComponentSwitchError.helperLaunchFailed(
                helperStopped
                    ? error.localizedDescription
                    : "the restart helper could not be stopped; recovery state was preserved")
        }
        pendingState.set(
            variant: prepared.variant,
            version: prepared.version,
            transactionURL: prepared.transactionURL,
            token: token)
    }

    private static func refreshPendingState() {
        guard let pending = pendingState.snapshot,
              let transaction = try? readTransaction(at: pending.transactionURL),
              transaction.token == pending.token,
              transaction.state == .completed || transaction.state == .failed
        else { return }
        pendingState.clear(token: pending.token)
    }

    static func leaseRequiresRecovery(_ prepared: PreparedSwitch) -> Bool {
        guard let transaction = try? readTransaction(at: prepared.transactionURL),
              transaction.token == prepared.token else { return false }
        return transaction.state == .recoveryRequired
    }

    /// App and CLI callers use this after an operation scheduled a switch. GUI
    /// termination still follows normal AppKit document/quit policy; cancelling
    /// that quit makes the helper time out and restore the activation state.
    @MainActor
    public static func requestRelaunchIfScheduled() {
        guard relaunchWasScheduled else { return }
        NSRunningApplication.runningApplications(
            withBundleIdentifier: ProductIdentity.current.bundleIdentifier)
            .forEach { _ = $0.terminate() }
        if NSApp != nil { NSApp.terminate(nil) }
    }

    /// Called before NSApplication is created. A copied, signed cmdy executable
    /// runs this private mode after the old app has quit.
    public static func runHelperIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.count == 4, arguments[1] == helperArgument else { return nil }
        return runHelper(
            transactionURL: URL(fileURLWithPath: arguments[2]),
            token: arguments[3])
    }

    /// AppDelegate calls this only after application launch and Browser runtime
    /// activation have completed. That acknowledgement commits the transaction. The
    /// return value is true only for the isolated packaged-app smoke, whose
    /// replacement process should exit immediately after acknowledgement.
    public static func confirmRelaunchIfRequested(
        _ arguments: [String],
        browserRuntimeReady: () -> Bool
    ) -> Bool {
        guard arguments.count >= 4,
              let index = arguments.firstIndex(of: confirmationArgument),
              index + 2 < arguments.count else { return false }
        let transactionURL = URL(fileURLWithPath: arguments[index + 1])
        let token = arguments[index + 2]
        guard var transaction = try? readTransaction(at: transactionURL),
              transaction.token == token,
              transaction.state == .awaitingConfirmation,
              transaction.testOnlySuppressConfirmation != true,
              let app = currentAppBundleURL(),
              sameExistingPath(app, URL(fileURLWithPath: transaction.destinationAppPath)),
              let inspection = try? inspectBundle(
                at: app, verifyCodeSignature: false),
              inspection.identifier == transaction.bundleIdentifier,
              inspection.version == transaction.candidateVersion,
              inspection.build == transaction.candidateBuild,
              inspection.browserEdition == (transaction.variant == .browser),
              inspection.browserVersion == transaction.browserComponentVersion,
              inspection.hasBrowserRuntime == (transaction.variant == .browser),
              inspection.containsBrowserPayload == (transaction.variant == .browser),
              activationUsesCurrentProfile(transaction.activation),
              activationChangeIsApplied(transaction.activation)
        else { return false }
        if transaction.variant == .browser, !browserRuntimeReady() {
            return false
        }
        transaction.state = .confirmed
        transaction.message = transaction.variant == .browser
            ? "Browser installed"
            : "Browser removed"
        do {
            try write(transaction, to: transactionURL)
            return transaction.testOnlyExitAfterConfirmation == true
        } catch {
            return false
        }
    }

    /// Finish or safely unwind an interrupted helper after a later successful
    /// app launch. Ambiguous/failed rollback states remain locked and visible.
    @MainActor
    public static func recoverInterruptedSwitchAfterLaunch(
        browserRuntimeReady: () -> Bool
    ) -> String? {
        let lock = switchLockDirectory()
        guard let record = try? readSwitchLock(at: lock),
              !processOwnsSwitchLock(record, excludingCurrentProcess: true)
        else { return nil }
        let transactionURL = URL(fileURLWithPath: record.transactionPath)
        guard var transaction = try? readTransaction(at: transactionURL),
              transaction.token == record.token else {
            return "The saved Browser transaction is unreadable. Reinstall the current cmdy release, then retry."
        }
        guard validateTransactionPaths(
                transaction, transactionURL: transactionURL) else {
            return "The saved Browser transaction contains unsafe paths. Reinstall the current cmdy release, then retry."
        }
        if transaction.state == .completed || transaction.state == .failed {
            releaseSwitchLock(at: lock, token: record.token)
            return nil
        }
        let destination = URL(fileURLWithPath: transaction.destinationAppPath)
        let backup = URL(fileURLWithPath: transaction.backupAppPath)
        let candidateIsRunning: Bool = {
            guard let app = currentAppBundleURL(),
                  sameExistingPath(app, destination),
                  let inspection = try? inspectBundle(at: app) else { return false }
            return inspectionMatchesCandidate(inspection, transaction: transaction)
        }()

        do {
            let activationCanCommit = (transaction.state == .confirmed
                    || transaction.state == .recoveryRequired)
                ? activationChangeHasRequestedResult(transaction.activation)
                : activationChangeIsApplied(transaction.activation)
            if candidateIsRunning,
               activationUsesCurrentProfile(transaction.activation),
               activationCanCommit,
               (transaction.variant == .lean || browserRuntimeReady()) {
                try finalizeActivation(transaction.activation)
                try removeCommittedAppBackup(transaction)
                transaction.state = .completed
                transaction.message = "Recovered confirmed Browser component switch"
                try write(transaction, to: transactionURL)
                releaseSwitchLock(at: lock, token: record.token)
                removeSafeHelperDirectory(transaction)
                return nil
            }
            // With an atomic exchange, `.staged` and no backup can mean either
            // side of the exchange. Inspect the exact original before deleting
            // the staging path: after an exchange that path holds the user's
            // rollback app, not the downloaded candidate.
            if transaction.state == .staged,
               !FileManager.default.fileExists(atPath: backup.path) {
                if transaction.originalInspection != nil {
                    try restoreOriginalAcrossInterruptedExchange(transaction)
                } else if let destinationInspection = try? inspectBundle(
                    at: destination),
                    inspectionMatchesCandidate(
                        destinationInspection, transaction: transaction) {
                    // Transactions written before the original inspection was
                    // persisted cannot distinguish this post-exchange shape.
                    // Preserve both apps and the lease instead of guessing.
                    throw BrowserComponentSwitchError.helperLaunchFailed(
                        "the interrupted app exchange needs the destination app to be relaunched")
                }
                try rollbackPreparedActivation(transaction.activation)
                removeSafeStagedApp(transaction)
                transaction.state = .failed
                transaction.message = "Recovered interrupted pre-swap Browser change"
                try write(transaction, to: transactionURL)
                releaseSwitchLock(at: lock, token: record.token)
                removeSafeHelperDirectory(transaction)
                return nil
            }
            // If the user repaired/reinstalled cmdy after an interruption, the
            // successfully launched, signed destination is authoritative. Keep
            // it, unwind the pending activation, and discard the old backup.
            if let app = currentAppBundleURL(),
               sameExistingPath(app, destination),
               let inspection = try? inspectBundle(at: app),
               inspection.identifier == transaction.bundleIdentifier,
               !candidateIsRunning {
                try rollbackPreparedActivation(transaction.activation)
                removeSafeStagedApp(transaction)
                try? FileManager.default.removeItem(at: backup)
                transaction.state = .failed
                transaction.message = "Recovered after cmdy was repaired or reinstalled"
                try write(transaction, to: transactionURL)
                releaseSwitchLock(at: lock, token: record.token)
                removeSafeHelperDirectory(transaction)
                return nil
            }
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the preserved app and backup state is ambiguous")
        } catch {
            transaction.state = .recoveryRequired
            transaction.message = error.localizedDescription
            try? write(transaction, to: transactionURL)
            return "\(error.localizedDescription) Reinstall the current cmdy release, then retry."
        }
    }

    private static func runHelper(transactionURL: URL, token: String) -> Int32 {
        guard var transaction = try? readTransaction(at: transactionURL),
              transaction.schemaVersion == 1,
              transaction.token == token,
              transaction.state == .staged else { return 2 }
        guard validateTransactionPaths(
            transaction, transactionURL: transactionURL) else {
            transaction.state = .failed
            transaction.message = "unsafe component-switch paths"
            try? write(transaction, to: transactionURL)
            return 3
        }
        let lockDirectory = URL(fileURLWithPath: transaction.lockDirectoryPath)
        guard switchLockIsOwned(at: lockDirectory, token: token) else {
            transaction.state = .failed
            transaction.message = "component-switch lock is missing or belongs to another operation"
            try? write(transaction, to: transactionURL)
            return 3
        }
        // Claim the lease from inside the helper before waiting for the parent
        // or touching activation/app state. This closes the Process.run ->
        // parent lock-update race if the caller is killed during handoff.
        guard let helperExecutable = runningExecutableURL() else {
            transaction.state = .recoveryRequired
            transaction.message = "restart helper could not identify its executable"
            try? write(transaction, to: transactionURL)
            return 3
        }
        do {
            try updateSwitchLockOwner(
                at: lockDirectory,
                token: token,
                ownerPID: getpid(),
                ownerExecutableURL: helperExecutable)
        } catch {
            transaction.state = .recoveryRequired
            transaction.message = "restart helper could not claim its component-switch lease: \(error.localizedDescription)"
            try? write(transaction, to: transactionURL)
            return 3
        }

        guard waitForProcessesToExit(
            transaction.waitingPIDs, timeout: helperWaitSeconds) else {
            do {
                try rollbackActivation(transaction.activation)
                removeSafeStagedApp(transaction)
                transaction.state = .failed
                transaction.message = "cmdy did not quit; the Browser change was cancelled"
                try? write(transaction, to: transactionURL)
                releaseSwitchLock(at: lockDirectory, token: token)
                removeSafeHelperDirectory(transaction)
                return 4
            } catch {
                transaction.state = .recoveryRequired
                transaction.message = "cmdy did not quit and activation rollback failed: \(error.localizedDescription)"
                try? write(transaction, to: transactionURL)
                return 6
            }
        }
        guard stopApplicationsAndWaitForQuiescence(transaction) else {
            do {
                try rollbackActivation(transaction.activation)
                removeSafeStagedApp(transaction)
                transaction.state = .failed
                transaction.message = "cmdy reopened during restart; the Browser change was cancelled"
                try? write(transaction, to: transactionURL)
                releaseSwitchLock(at: lockDirectory, token: token)
                removeSafeHelperDirectory(transaction)
                return 4
            } catch {
                transaction.state = .recoveryRequired
                transaction.message = "cmdy reopened during restart and activation rollback failed: \(error.localizedDescription)"
                try? write(transaction, to: transactionURL)
                return 6
            }
        }

        let destination = URL(fileURLWithPath: transaction.destinationAppPath)
        let staged = URL(fileURLWithPath: transaction.stagedAppPath)
        let backup = URL(fileURLWithPath: transaction.backupAppPath)
        var originalInspection: BundleInspection?
        do {
            let current = try inspectBundle(at: destination)
            originalInspection = current
            _ = try validateCandidate(
                staged,
                replacing: destination,
                expectedVariant: transaction.variant,
                minimumVersion: current.version,
                requiredBrowserVersion: transaction.browserComponentVersion)
            // Exchange the two same-volume bundle names in one filesystem
            // operation. There is never a crash or power-loss window where
            // the public destination is absent: it names either the original
            // app or the complete replacement. The old app is then moved from
            // the hidden staging name to its durable rollback name.
            try atomicallyExchangeApplications(
                destination: destination, staged: staged)
            try FileManager.default.moveItem(at: staged, to: backup)
            _ = try validateCandidate(
                destination,
                replacing: backup,
                expectedVariant: transaction.variant,
                minimumVersion: current.version,
                requiredBrowserVersion: transaction.browserComponentVersion)
            guard stopApplicationsAndWaitForQuiescence(transaction) else {
                throw BrowserComponentSwitchError.helperLaunchFailed(
                    "cmdy reopened before the verified replacement could launch")
            }

            transaction.state = .awaitingConfirmation
            try write(transaction, to: transactionURL)
            try launchApplication(
                at: destination,
                transactionURL: transactionURL,
                token: token)
            guard waitForConfirmation(
                at: transactionURL,
                token: token,
                timeout: validatedConfirmationTimeout(transaction)) else {
                throw BrowserComponentSwitchError.helperLaunchFailed(
                    "the replacement app did not confirm startup")
            }

            // Startup confirmation is the commit point. A cleanup failure must
            // never roll the acknowledged app back, but it also must not be
            // forgotten or reported as reclaimed storage. Preserve the lease
            // so a later launch can retry the exact verified cleanup.
            do {
                try finalizeActivation(transaction.activation)
                try removeCommittedAppBackup(transaction)
            } catch {
                transaction.state = .recoveryRequired
                transaction.message = "The Browser change committed, but old app cleanup is still pending: \(error.localizedDescription)"
                try? write(transaction, to: transactionURL)
                return 8
            }
            transaction.state = .completed
            transaction.message = transaction.variant == .browser
                ? "Browser installed and cmdy restarted"
                : "Browser removed and Chromium storage reclaimed"
            try? write(transaction, to: transactionURL)
            releaseSwitchLock(at: lockDirectory, token: token)
            removeSafeHelperDirectory(transaction)
            return 0
        } catch {
            let replacementStopped = stopApplicationsAndWaitForQuiescence(transaction)
            guard replacementStopped else {
                transaction.state = .recoveryRequired
                transaction.message = "the replacement app could not be stopped; its backup was preserved and no live bundle was moved"
                try? write(transaction, to: transactionURL)
                return 6
            }
            do {
                try rollbackApplication(
                    destination: destination,
                    staged: staged,
                    backup: backup,
                    expected: originalInspection)
                try rollbackActivation(transaction.activation)
                removeSafeStagedApp(transaction)
            } catch let recoveryError {
                transaction.state = .recoveryRequired
                transaction.message = "component switch failed (\(error.localizedDescription)); verified rollback also failed: \(recoveryError.localizedDescription)"
                try? write(transaction, to: transactionURL)
                return 7
            }
            transaction.state = .failed
            transaction.message = error.localizedDescription
            try? write(transaction, to: transactionURL)
            if transaction.testOnlyExitAfterConfirmation != true {
                _ = try? launchApplication(at: destination)
            }
            releaseSwitchLock(at: lockDirectory, token: token)
            removeSafeHelperDirectory(transaction)
            return 5
        }
    }

    private static func launchApplication(
        at app: URL,
        transactionURL: URL? = nil,
        token: String? = nil
    ) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        // NSWorkspace normally inherits the caller's environment, but make the
        // contract explicit so isolated configuration roots used by the real
        // packaged-app lifecycle smoke survive the restart as well.
        configuration.environment = ProcessInfo.processInfo.environment
        if let transactionURL, let token {
            configuration.arguments = [
                confirmationArgument, transactionURL.path, token,
            ]
        }
        let completion = DispatchSemaphore(value: 0)
        let result = LaunchResult()
        NSWorkspace.shared.openApplication(
            at: app, configuration: configuration
        ) { application, error in
            result.complete(application, error)
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 15) == .success else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "macOS did not answer the relaunch request")
        }
        let (application, error) = result.snapshot()
        if let error { throw error }
        guard application != nil else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "macOS did not launch the replacement app")
        }
    }

    private static func waitForProcessesToExit(
        _ pids: [Int32], timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let live = pids.contains { pid in
                errno = 0
                return kill(pid, 0) == 0 || errno == EPERM
            }
            if !live { return true }
            usleep(100_000)
        }
        return false
    }

    private static func waitForConfirmation(
        at url: URL,
        token: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let transaction = try? readTransaction(at: url),
               transaction.token == token,
               transaction.state == .confirmed {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    private static func validatedConfirmationTimeout(
        _ transaction: Transaction
    ) -> TimeInterval {
        guard transaction.testOnlyExitAfterConfirmation == true,
              let timeout = transaction.testOnlyConfirmationTimeoutSeconds,
              timeout >= 1, timeout <= 15 else {
            return confirmationWaitSeconds
        }
        return timeout
    }

    static func switchLockDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(
            ProductIdentity.current.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("ComponentSwitch", isDirectory: true)
            .appendingPathComponent(
                ".browser-component-switch.lock", isDirectory: true)
    }

    static func acquireSwitchLock(
        at directory: URL,
        token: String,
        transactionURL: URL
    ) throws {
        let fm = FileManager.default
        for attempt in 0..<2 {
            do {
                try fm.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                let record = SwitchLock(
                    schemaVersion: 1,
                    token: token,
                    transactionPath: transactionURL.path,
                    ownerPID: getpid(),
                    ownerExecutablePath: runningExecutableURL()?.path,
                    createdAt: Date().timeIntervalSince1970,
                    activation: nil)
                do {
                    try writeSwitchLock(record, at: directory)
                    return
                } catch {
                    try? fm.removeItem(at: directory)
                    throw error
                }
            } catch {
                guard fm.fileExists(atPath: directory.path) else {
                    throw BrowserComponentSwitchError.appIsNotReplaceable(
                        "component-switch state could not be created: \(error.localizedDescription)")
                }
                if attempt == 0, recoverStaleSwitchLock(at: directory) {
                    continue
                }
                throw BrowserComponentSwitchError.switchAlreadyPending
            }
        }
        throw BrowserComponentSwitchError.switchAlreadyPending
    }

    static func recoverStaleSwitchLock(at directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        let now = Date().timeIntervalSince1970
        if let record = try? readSwitchLock(at: directory) {
            let elapsed = now - record.createdAt
            let transactionURL = URL(fileURLWithPath: record.transactionPath)
            let transactionExists = FileManager.default.fileExists(
                atPath: transactionURL.path)
            let transaction = try? readTransaction(at: transactionURL)
            if let transaction {
                // A mismatched transaction is corrupt or belongs to a different
                // operation. Never infer that it is safe to unlock.
                guard transaction.token == record.token else { return false }
                if transaction.state == .completed || transaction.state == .failed {
                    releaseSwitchLock(at: directory, token: record.token)
                    return !FileManager.default.fileExists(atPath: directory.path)
                }
                // Any nonterminal state can represent activation already moved,
                // a live app already replaced, or a failed verified rollback.
                // It needs explicit recovery; elapsed time alone cannot prove
                // that mutating the app again is safe.
                return false
            }
            // A present but unreadable transaction could describe an app move
            // already in progress. Treat corruption as unresolved, never as an
            // empty lease.
            if transactionExists { return false }
            if !processOwnsSwitchLock(record),
               elapsed >= abandonedLockGraceSeconds {
                do {
                    try rollbackPreparedActivation(record.activation)
                } catch {
                    return false
                }
                releaseSwitchLock(at: directory, token: record.token)
                return !FileManager.default.fileExists(atPath: directory.path)
            }
            return false
        }
        let modified = values.contentModificationDate?
            .timeIntervalSince1970 ?? now
        guard now - modified >= staleLockSeconds else { return false }
        try? FileManager.default.removeItem(at: directory)
        return !FileManager.default.fileExists(atPath: directory.path)
    }

    private static func switchLockIsOwned(at directory: URL, token: String) -> Bool {
        guard let record = try? readSwitchLock(at: directory) else { return false }
        return record.schemaVersion == 1 && record.token == token
    }

    private static func updateSwitchLockOwner(
        at directory: URL,
        token: String,
        ownerPID: Int32,
        ownerExecutableURL: URL
    ) throws {
        guard let record = try? readSwitchLock(at: directory),
              record.schemaVersion == 1,
              record.token == token else {
            throw BrowserComponentSwitchError.switchAlreadyPending
        }
        try writeSwitchLock(
            SwitchLock(
                schemaVersion: record.schemaVersion,
                token: record.token,
                transactionPath: record.transactionPath,
                ownerPID: ownerPID,
                ownerExecutablePath: ownerExecutableURL.standardizedFileURL.path,
                createdAt: record.createdAt,
                activation: record.activation),
            at: directory)
    }

    static func releaseSwitchLock(at directory: URL, token: String) {
        guard switchLockIsOwned(at: directory, token: token) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeSwitchLock(_ record: SwitchLock, at directory: URL) throws {
        let url = directory.appendingPathComponent("owner.json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        _ = chmod(url.path, mode_t(S_IRUSR | S_IWUSR))
    }

    private static func readSwitchLock(at directory: URL) throws -> SwitchLock {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BrowserComponentSwitchError.switchAlreadyPending
        }
        let url = directory.appendingPathComponent("owner.json")
        let fileValues = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard fileValues.isRegularFile == true,
              fileValues.isSymbolicLink != true,
              (fileValues.fileSize ?? 0) <= 64 * 1024 else {
            throw BrowserComponentSwitchError.switchAlreadyPending
        }
        return try JSONDecoder().decode(
            SwitchLock.self, from: Data(contentsOf: url))
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// A PID can be reused after a crash or reboot. Bind the lease to the
    /// actual executable image as well so an unrelated process cannot keep a
    /// dead Browser transaction locked forever.
    private static func processOwnsSwitchLock(
        _ record: SwitchLock,
        excludingCurrentProcess: Bool = false
    ) -> Bool {
        guard processIsAlive(record.ownerPID) else { return false }
        if excludingCurrentProcess, record.ownerPID == getpid() { return false }
        guard let expectedPath = record.ownerExecutablePath else {
            // Compatibility with a lock written before executable binding was
            // introduced: fail closed while that PID remains alive.
            return true
        }
        guard let actual = executableURL(forPID: record.ownerPID) else {
            return true
        }
        return actual.path == URL(fileURLWithPath: expectedPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func executableURL(forPID pid: Int32) -> URL? {
        // libproc's PROC_PIDPATHINFO_MAXSIZE macro is not imported by Swift;
        // Darwin defines it as four MAXPATHLEN buffers.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func stopApplicationsAndWaitForQuiescence(
        _ transaction: Transaction
    ) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        var quietSince: Date?
        while Date() < deadline {
            let applications = matchingApplications(for: transaction)
            if applications.isEmpty {
                if let quietSince,
                   Date().timeIntervalSince(quietSince) >= 0.75 {
                    return true
                }
                if quietSince == nil { quietSince = Date() }
            } else {
                quietSince = nil
                applications.forEach { application in
                    if deadline.timeIntervalSinceNow < 5 {
                        _ = application.forceTerminate()
                    } else {
                        _ = application.terminate()
                    }
                }
            }
            usleep(100_000)
        }
        return false
    }

    private static func matchingApplications(
        for transaction: Transaction
    ) -> [NSRunningApplication] {
        let identifiers = [
            transaction.bundleIdentifier,
            transaction.bundleIdentifier + ".helper",
            transaction.bundleIdentifier + ".helper.renderer",
            transaction.bundleIdentifier + ".helper.gpu",
            transaction.bundleIdentifier + ".helper.plugin",
        ]
        // The lease is per-user because Browser activation is per-user. Quiesce
        // every process with the product/helper identities, including another
        // app copy reopened from a different folder during the swap window.
        return identifiers.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter { $0.processIdentifier != getpid() }
    }

    private static func rollbackApplication(
        destination: URL,
        staged: URL,
        backup: URL,
        expected: BundleInspection?
    ) throws {
        guard safeAppSibling(
            destination, staged: staged, backup: backup) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "refused unsafe app rollback paths")
        }
        let fm = FileManager.default
        var failedReplacement: URL?
        if fm.fileExists(atPath: backup.path) {
            if fm.fileExists(atPath: destination.path) {
                let failed = destination.deletingLastPathComponent().appendingPathComponent(
                    ".cmdy-component-failed-\(UUID().uuidString).app", isDirectory: true)
                try fm.moveItem(at: destination, to: failed)
                failedReplacement = failed
            }
            do {
                try fm.moveItem(at: backup, to: destination)
            } catch {
                if let failedReplacement,
                   !fm.fileExists(atPath: destination.path) {
                    try? fm.moveItem(at: failedReplacement, to: destination)
                }
                throw error
            }
        } else if fm.fileExists(atPath: staged.path) {
            // If interruption happened after the atomic exchange but before
            // the old app was renamed to `backup`, the staged name now holds
            // the verified original. Exchange the names back atomically. If
            // interruption happened before the exchange, destination already
            // is the original and the staged candidate is removed below by
            // the caller.
            guard let expected else {
                throw BrowserComponentSwitchError.helperLaunchFailed(
                    "the original app identity is unavailable for rollback")
            }
            if fm.fileExists(atPath: destination.path) {
                let destinationInspection = try inspectBundle(at: destination)
                if destinationInspection != expected {
                    let stagedInspection = try inspectBundle(at: staged)
                    guard stagedInspection == expected else {
                        throw BrowserComponentSwitchError.helperLaunchFailed(
                            "neither app bundle matches the verified original")
                    }
                    try atomicallyExchangeApplications(
                        destination: destination, staged: staged)
                }
            } else {
                let stagedInspection = try inspectBundle(at: staged)
                guard stagedInspection == expected else {
                    throw BrowserComponentSwitchError.helperLaunchFailed(
                        "the remaining app bundle is not the verified original")
                }
                try fm.moveItem(at: staged, to: destination)
            }
        }
        guard fm.fileExists(atPath: destination.path) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the original app could not be restored")
        }
        let restored = try inspectBundle(at: destination)
        if let expected, restored != expected {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the restored app no longer matches the verified original")
        }
        if let failedReplacement {
            try fm.removeItem(at: failedReplacement)
        }
    }

    static func finalizeActivation(_ change: ActivationChange?) throws {
        guard let change else { return }
        guard validateActivationChange(change) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "refused unsafe activation cleanup paths")
        }
        guard let backupPath = change.backupPath else { return }
        let backup = URL(fileURLWithPath: backupPath)
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        guard !FileManager.default.fileExists(atPath: backup.path) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the old Browser activation could not be deleted")
        }
    }

    private static func removeCommittedAppBackup(
        _ transaction: Transaction
    ) throws {
        let destination = URL(fileURLWithPath: transaction.destinationAppPath)
        let staged = URL(fileURLWithPath: transaction.stagedAppPath)
        let backup = URL(fileURLWithPath: transaction.backupAppPath)
        guard safeAppSibling(
            destination, staged: staged, backup: backup) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "refused unsafe committed-app cleanup paths")
        }
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        // A helper killed immediately after the atomic exchange may leave the
        // old app at the staging name instead of the backup name. Once the new
        // app has confirmed startup, both locations are commit-time cleanup.
        if FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.removeItem(at: staged)
        }
        guard !FileManager.default.fileExists(atPath: backup.path),
              !FileManager.default.fileExists(atPath: staged.path) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the previous cmdy app could not be deleted")
        }
    }

    private static func inspectionMatchesCandidate(
        _ inspection: BundleInspection,
        transaction: Transaction
    ) -> Bool {
        inspection.identifier == transaction.bundleIdentifier
            && inspection.version == transaction.candidateVersion
            && inspection.build == transaction.candidateBuild
            && inspection.browserEdition == (transaction.variant == .browser)
            && inspection.browserVersion == transaction.browserComponentVersion
            && inspection.hasBrowserRuntime == (transaction.variant == .browser)
            && inspection.containsBrowserPayload == (transaction.variant == .browser)
    }

    /// Resolve the only two valid `.staged` layouts around `RENAME_SWAP`.
    /// Before the exchange, destination is the original; immediately after it,
    /// destination is the candidate and staging is the original. Anything else
    /// is preserved as ambiguous instead of deleting a possible rollback app.
    static func restoreOriginalAcrossInterruptedExchange(
        _ transaction: Transaction
    ) throws {
        guard let original = transaction.originalInspection else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the original app identity is unavailable for recovery")
        }
        let destination = URL(fileURLWithPath: transaction.destinationAppPath)
        let staged = URL(fileURLWithPath: transaction.stagedAppPath)
        if let destinationInspection = try? inspectBundle(at: destination),
           destinationInspection == original {
            return
        }
        guard let destinationInspection = try? inspectBundle(at: destination),
              inspectionMatchesCandidate(
                destinationInspection, transaction: transaction),
              let stagedInspection = try? inspectBundle(at: staged),
              stagedInspection == original else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the interrupted atomic app exchange is ambiguous")
        }
        try atomicallyExchangeApplications(
            destination: destination, staged: staged)
        guard (try? inspectBundle(at: destination)) == original else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "the original app was not restored after interruption")
        }
    }

    /// Atomically exchange the installed and staged bundle names. Both paths
    /// are siblings on the same volume, so `RENAME_SWAP` guarantees observers
    /// never see a missing destination, even if the helper is interrupted.
    static func atomicallyExchangeApplications(
        destination: URL,
        staged: URL
    ) throws {
        let destination = destination.standardizedFileURL
        let staged = staged.standardizedFileURL
        guard destination.deletingLastPathComponent().path
                == staged.deletingLastPathComponent().path,
              destination.deletingLastPathComponent().path != "/",
              destination.pathExtension.caseInsensitiveCompare("app")
                == .orderedSame,
              staged.lastPathComponent.hasPrefix(".cmdy-component-stage-"),
              staged.pathExtension.caseInsensitiveCompare("app")
                == .orderedSame,
              FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.fileExists(atPath: staged.path) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "refused unsafe atomic app exchange paths")
        }
        let result = destination.path.withCString { destinationPath in
            staged.path.withCString { stagedPath in
                renamex_np(
                    destinationPath, stagedPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            let code = errno
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "atomic app exchange failed: \(String(cString: strerror(code)))")
        }
        guard FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.fileExists(atPath: staged.path) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "atomic app exchange did not preserve both bundles")
        }
    }

    static func activationChangeIsApplied(_ change: ActivationChange?) -> Bool {
        guard let change else { return true }
        guard validateActivationChange(change) else { return false }
        let destinationExists = FileManager.default.fileExists(
            atPath: change.destinationPath)
        let backupExists = change.backupPath.map {
            FileManager.default.fileExists(atPath: $0)
        }
        switch change.kind {
        case .installed:
            return destinationExists && (backupExists ?? true)
        case .removed:
            return !destinationExists && backupExists == true
        }
    }

    /// Once the replacement app has written `.confirmed`, deleting an old
    /// activation backup is merely post-commit cleanup. Recovery therefore
    /// validates the requested live shape without requiring that backup to
    /// survive the tiny window before the helper writes `.completed`.
    static func activationChangeHasRequestedResult(
        _ change: ActivationChange?
    ) -> Bool {
        guard let change else { return true }
        guard validateActivationChange(change) else { return false }
        let destinationExists = FileManager.default.fileExists(
            atPath: change.destinationPath)
        switch change.kind {
        case .installed:
            return destinationExists
        case .removed:
            return !destinationExists
        }
    }

    static func activationUsesCurrentProfile(_ change: ActivationChange?) -> Bool {
        guard let change else { return true }
        return URL(fileURLWithPath: change.rootPath).standardizedFileURL.path
            == PluginManager.pluginsDirectory.standardizedFileURL.path
    }

    static func rollbackActivation(_ change: ActivationChange?) throws {
        guard let change else { return }
        guard validateActivationChange(change) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "refused unsafe activation rollback paths")
        }
        let destination = URL(fileURLWithPath: change.destinationPath)
        let backup = change.backupPath.map(URL.init(fileURLWithPath:))
        switch change.kind {
        case .installed:
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if let backup {
                guard FileManager.default.fileExists(atPath: backup.path) else {
                    throw BrowserComponentSwitchError.helperLaunchFailed(
                        "the previous Browser activation backup is missing")
                }
                try FileManager.default.moveItem(at: backup, to: destination)
            }
        case .removed:
            guard let backup,
                  FileManager.default.fileExists(atPath: backup.path),
                  !FileManager.default.fileExists(atPath: destination.path) else {
                throw BrowserComponentSwitchError.helperLaunchFailed(
                    "the removed Browser activation cannot be restored safely")
            }
            try FileManager.default.moveItem(at: backup, to: destination)
        }
        let destinationExists = FileManager.default.fileExists(
            atPath: destination.path)
        let expectedDestination = change.backupPath != nil
        let backupWasRemoved = change.backupPath.map { path in
            !FileManager.default.fileExists(atPath: path)
        } ?? true
        guard destinationExists == expectedDestination,
              backupWasRemoved else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "activation rollback verification failed")
        }
    }

    /// Recover an activation intent whose full app transaction was never
    /// persisted. This handles a process interruption on either side of the
    /// atomic rename without deleting an untouched previous installation.
    static func rollbackPreparedActivation(_ change: ActivationChange?) throws {
        guard let change else { return }
        guard validateActivationChange(change) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "refused unsafe prepared activation recovery paths")
        }
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: change.destinationPath)
        let backup = change.backupPath.map(URL.init(fileURLWithPath:))
        let destinationExists = fm.fileExists(atPath: destination.path)
        let backupExists = backup.map { fm.fileExists(atPath: $0.path) } ?? false

        switch change.kind {
        case .installed:
            if let backup {
                if backupExists {
                    if destinationExists { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: backup, to: destination)
                } else if !destinationExists {
                    throw BrowserComponentSwitchError.helperLaunchFailed(
                        "neither the previous nor replacement Browser activation remains")
                }
                // destination present + backup absent is the untouched state:
                // the first rename never committed.
            } else if destinationExists {
                try fm.removeItem(at: destination)
            }
        case .removed:
            if let backup, backupExists, !destinationExists {
                try fm.moveItem(at: backup, to: destination)
            } else if !(destinationExists && !backupExists) {
                throw BrowserComponentSwitchError.helperLaunchFailed(
                    "the Browser activation removal state is ambiguous")
            }
        }
        guard !activationChangeIsApplied(change) else {
            throw BrowserComponentSwitchError.helperLaunchFailed(
                "prepared activation recovery did not restore the previous state")
        }
    }

    static func validateActivationChange(_ change: ActivationChange) -> Bool {
        let root = URL(fileURLWithPath: change.rootPath).standardizedFileURL
        let destination = URL(fileURLWithPath: change.destinationPath).standardizedFileURL
        guard root.path != "/", root.lastPathComponent == "extensions",
              destination.deletingLastPathComponent().path == root.path,
              !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".",
              destination.lastPathComponent != ".." else { return false }
        if let backupPath = change.backupPath {
            let backup = URL(fileURLWithPath: backupPath).standardizedFileURL
            guard backup.deletingLastPathComponent().path == root.path,
                  backup.lastPathComponent.hasPrefix(".") else { return false }
        }
        return true
    }

    private static func validateTransactionPaths(
        _ transaction: Transaction,
        transactionURL: URL
    ) -> Bool {
        let destination = URL(fileURLWithPath: transaction.destinationAppPath)
            .standardizedFileURL
        let staged = URL(fileURLWithPath: transaction.stagedAppPath)
            .standardizedFileURL
        let backup = URL(fileURLWithPath: transaction.backupAppPath)
            .standardizedFileURL
        let transactionURL = transactionURL.standardizedFileURL
        let lockDirectory = URL(fileURLWithPath: transaction.lockDirectoryPath)
            .standardizedFileURL
        guard destination.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              destination.deletingLastPathComponent().path != "/",
              staged.deletingLastPathComponent().path
                == destination.deletingLastPathComponent().path,
              backup.deletingLastPathComponent().path
                == destination.deletingLastPathComponent().path,
              staged.lastPathComponent.hasPrefix(".cmdy-component-stage-"),
              backup.lastPathComponent.hasPrefix(".cmdy-component-backup-"),
              staged.pathExtension == "app", backup.pathExtension == "app",
              transactionURL.deletingLastPathComponent().path != "/",
              lockDirectory.lastPathComponent == ".browser-component-switch.lock",
              lockDirectory.deletingLastPathComponent().lastPathComponent
                == "ComponentSwitch",
              lockDirectory.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
                == transaction.bundleIdentifier
        else { return false }
        if let activation = transaction.activation,
           !validateActivationChange(activation) { return false }
        return true
    }

    private static func removeSafeStagedApp(_ transaction: Transaction) {
        let destination = URL(fileURLWithPath: transaction.destinationAppPath)
        let staged = URL(fileURLWithPath: transaction.stagedAppPath)
        let backup = URL(fileURLWithPath: transaction.backupAppPath)
        guard safeAppSibling(destination, staged: staged, backup: backup) else { return }
        try? FileManager.default.removeItem(at: staged)
    }

    private static func removeSafeHelperDirectory(_ transaction: Transaction) {
        let helper = URL(fileURLWithPath: transaction.helperDirectoryPath)
            .standardizedFileURL
        guard UUID(uuidString: helper.lastPathComponent) != nil,
              helper.deletingLastPathComponent().lastPathComponent == "ComponentSwitch"
        else { return }
        try? FileManager.default.removeItem(at: helper)
    }

    private static func safeAppSibling(
        _ destination: URL,
        staged: URL? = nil,
        backup: URL
    ) -> Bool {
        let destination = destination.standardizedFileURL
        let backup = backup.standardizedFileURL
        let parent = destination.deletingLastPathComponent().path
        guard parent != "/",
              backup.deletingLastPathComponent().path == parent,
              backup.lastPathComponent.hasPrefix(".cmdy-component-backup-"),
              backup.pathExtension == "app" else { return false }
        if let staged {
            let staged = staged.standardizedFileURL
            guard staged.deletingLastPathComponent().path == parent,
                  staged.lastPathComponent.hasPrefix(".cmdy-component-stage-"),
                  staged.pathExtension == "app" else { return false }
        }
        return true
    }

    static func inspectBundle(
        at app: URL,
        verifyCodeSignature: Bool = true
    ) throws -> BundleInspection {
        let fm = FileManager.default
        let values = try app.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BrowserComponentSwitchError.invalidApplication(
                "the app root is missing, not a directory, or is a symlink")
        }
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let infoValues = try infoURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard infoValues.isRegularFile == true,
              infoValues.isSymbolicLink != true,
              (infoValues.fileSize ?? 0) <= 1024 * 1024,
              let dictionary = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoURL), options: [], format: nil)
                as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let executable = dictionary["CFBundleExecutable"] as? String,
              let version = dictionary["CFBundleShortVersionString"] as? String,
              let build = dictionary["CFBundleVersion"] as? String,
              !identifier.isEmpty, !executable.isEmpty,
              AppUpdateMonitor.isNumericVersion(version),
              isNumericBuild(build)
        else {
            throw BrowserComponentSwitchError.invalidApplication(
                "Info.plist identity or version is missing")
        }
        let executableURL = app.appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executable)
        let executableValues = try executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true,
              fm.isExecutableFile(atPath: executableURL.path) else {
            throw BrowserComponentSwitchError.invalidApplication(
                "the declared app executable is missing or unsafe")
        }

        var team: String?
        var developerIDSigned = false
        var hardenedRuntime = false
        if verifyCodeSignature {
            let verification = try ProcessCapture.run(
                URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", app.path],
                timeout: 180,
                outputLimit: 1_048_576)
            guard verification.terminationStatus == 0,
                  !verification.outputWasTruncated else {
                throw BrowserComponentSwitchError.invalidApplication(
                    "the complete code signature is invalid")
            }
            let details = try ProcessCapture.run(
                URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["-dv", "--verbose=4", app.path],
                timeout: 60,
                outputLimit: 1_048_576)
            guard details.terminationStatus == 0,
                  !details.outputWasTruncated else {
                throw BrowserComponentSwitchError.invalidApplication(
                    "code-signing identity could not be read")
            }
            team = signingValue("TeamIdentifier", in: details.output)
                .flatMap { isTeamIdentifier($0) ? $0 : nil }
            developerIDSigned = details.output.contains(
                "Authority=Developer ID Application:")
            hardenedRuntime = details.output
                .split(whereSeparator: \Character.isNewline)
                .contains { $0.hasPrefix("flags=") && $0.contains("runtime") }
        }
        return BundleInspection(
            identifier: identifier,
            executable: executable,
            version: version,
            build: build,
            browserEdition: dictionary["CMDYBrowserEdition"] as? Bool ?? false,
            browserVersion: dictionary["CMDYBrowserVersion"] as? String,
            hasBrowserRuntime: hasBrowserRuntime(in: app),
            containsBrowserPayload: containsBrowserPayload(in: app),
            teamIdentifier: team,
            developerIDSigned: developerIDSigned,
            hardenedRuntime: hardenedRuntime)
    }

    @discardableResult
    static func validateCandidate(
        _ candidate: URL,
        replacing currentApp: URL,
        expectedVariant: BrowserComponentVariant,
        minimumVersion: String,
        requiredBrowserVersion: String? = nil
    ) throws -> BundleInspection {
        let current = try inspectBundle(at: currentApp)
        let candidateInfo = try inspectBundle(at: candidate)
        guard candidateInfo.identifier == current.identifier,
              candidateInfo.executable == current.executable else {
            throw BrowserComponentSwitchError.invalidApplication(
                "bundle identifier or executable does not match the installed app")
        }
        guard candidateInfo.version == minimumVersion
                || AppUpdateMonitor.isVersion(
                    candidateInfo.version, newerThan: minimumVersion) else {
            throw BrowserComponentSwitchError.invalidApplication(
                "version \(candidateInfo.version) would downgrade \(minimumVersion)")
        }
        if candidateInfo.version == current.version,
           candidateInfo.build != current.build,
           !isBuild(candidateInfo.build, newerThan: current.build) {
            throw BrowserComponentSwitchError.invalidApplication(
                "build \(candidateInfo.build) would downgrade \(current.build) for version \(current.version)")
        }
        let expectsBrowser = expectedVariant == .browser
        guard candidateInfo.browserEdition == expectsBrowser,
              (expectsBrowser
                ? browserVersionSatisfies(
                    candidateInfo.browserVersion,
                    minimum: requiredBrowserVersion)
                : candidateInfo.browserVersion == nil),
              candidateInfo.hasBrowserRuntime == expectsBrowser,
              candidateInfo.containsBrowserPayload == expectsBrowser else {
            throw BrowserComponentSwitchError.invalidApplication(
                expectsBrowser
                    ? "the Browser edition marker, component version, or Chromium runtime is wrong"
                    : "the lean build still contains Browser metadata or Chromium runtime")
        }

        if let expectedTeam = current.teamIdentifier {
            guard candidateInfo.teamIdentifier == expectedTeam,
                  candidateInfo.developerIDSigned,
                  candidateInfo.hardenedRuntime else {
                throw BrowserComponentSwitchError.invalidApplication(
                    "Developer ID, hardened runtime, or Apple Team ID does not match")
            }
            let assessment = try ProcessCapture.run(
                URL(fileURLWithPath: "/usr/sbin/spctl"),
                arguments: ["--assess", "--type", "execute", "--verbose=4", candidate.path],
                timeout: 180,
                outputLimit: 1_048_576)
            guard assessment.terminationStatus == 0,
                  !assessment.outputWasTruncated else {
                throw BrowserComponentSwitchError.invalidApplication(
                    "Gatekeeper did not accept the notarized app")
            }
        } else {
            guard candidateInfo.teamIdentifier == nil else {
                throw BrowserComponentSwitchError.invalidApplication(
                    "a development build cannot switch to a differently signed app")
            }
        }
        return candidateInfo
    }

    private static func hasBrowserRuntime(in app: URL) -> Bool {
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        let frameworkBinary = frameworks.appendingPathComponent(
            "Chromium Embedded Framework.framework/Chromium Embedded Framework")
        let host = frameworks.appendingPathComponent("libCmdyChromiumHost.dylib")
        let mcp = app.appendingPathComponent("Contents/Resources/BrowserMCP/index.js")
        guard isRegularFile(frameworkBinary, minimumBytes: 50 * 1024 * 1024),
              isRegularFile(host, minimumBytes: 64 * 1024),
              isRegularFile(mcp, minimumBytes: 1024) else { return false }
        let helpers = ((try? FileManager.default.contentsOfDirectory(
            at: frameworks,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])) ?? []).filter {
                $0.pathExtension == "app"
                    && $0.lastPathComponent.contains("Chromium Helper")
            }
        guard helpers.count == 4 else { return false }
        return helpers.allSatisfy { helper in
            guard let values = try? helper.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let bundle = Bundle(url: helper),
                  let executable = bundle.executableURL else { return false }
            return isRegularFile(executable, minimumBytes: 64 * 1024)
        }
    }

    private static func containsBrowserPayload(in app: URL) -> Bool {
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        let fixed = [
            frameworks.appendingPathComponent(
                "Chromium Embedded Framework.framework", isDirectory: true),
            frameworks.appendingPathComponent("libCmdyChromiumHost.dylib"),
            app.appendingPathComponent("Contents/Resources/BrowserMCP", isDirectory: true),
        ]
        if fixed.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return true
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: frameworks, includingPropertiesForKeys: nil, options: [])) ?? []
        return contents.contains {
            $0.pathExtension == "app"
                && $0.lastPathComponent.contains("Chromium Helper")
        }
    }

    private static func browserEditionMarker(in app: URL) -> Bool {
        infoDictionary(in: app)?["CMDYBrowserEdition"] as? Bool ?? false
    }

    private static func browserVersionMarker(in app: URL) -> String? {
        infoDictionary(in: app)?["CMDYBrowserVersion"] as? String
    }

    private static func infoDictionary(in app: URL) -> [String: Any]? {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any]
        else { return nil }
        return dictionary
    }

    private static func isRegularFile(_ url: URL, minimumBytes: Int) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) >= minimumBytes else { return false }
        return true
    }

    private static func currentAppBundleURL() -> URL? {
        guard let executable = runningExecutableURL() else { return nil }
        var candidate = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
               FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Contents/Info.plist").path) {
                return candidate.standardizedFileURL
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return nil
    }

    /// Resolve the image the kernel actually launched. Shells are allowed to
    /// keep a PATH-resolved command's argv[0] as just `cmdy`, so argv[0] cannot
    /// identify the surrounding application bundle or the helper source.
    static func runningExecutableURL() -> URL? {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        guard capacity > 1 else { return Bundle.main.executableURL }
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        guard _NSGetExecutablePath(&buffer, &capacity) == 0 else {
            return Bundle.main.executableURL
        }
        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func componentCacheDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("cmdy", isDirectory: true)
            .appendingPathComponent("ComponentSwitch", isDirectory: true)
    }

    private static func signingValue(_ key: String, in output: String) -> String? {
        let prefix = key + "="
        return output.split(whereSeparator: \Character.isNewline)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
        }
    }

    private static func versionIsSameOrNewer(_ candidate: String, than current: String) -> Bool {
        candidate == current || AppUpdateMonitor.isVersion(candidate, newerThan: current)
    }

    private static func isNumericBuild(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return false }
        return pieces.allSatisfy { piece in
            !piece.isEmpty && piece.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
                && Int(piece) != nil
        }
    }

    private static func isBuild(_ candidate: String, newerThan current: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            guard isNumericBuild(value) else { return nil }
            var result = value.split(separator: ".").compactMap { Int($0) }
            while result.count < 3 { result.append(0) }
            return result
        }
        guard let candidate = components(candidate),
              let current = components(current) else { return false }
        return current.lexicographicallyPrecedes(candidate)
    }

    private static func browserVersionSatisfies(
        _ candidate: String?,
        minimum: String?
    ) -> Bool {
        guard let candidate, let minimum else { return false }
        return versionIsSameOrNewer(candidate, than: minimum)
    }

    private static func sameExistingPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func path(_ candidate: URL, isInside root: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func write(_ transaction: Transaction, to url: URL) throws {
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, mode_t(S_IRUSR | S_IWUSR))
    }

    private static func readTransaction(at url: URL) throws -> Transaction {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 64 * 1024 else {
            throw BrowserComponentSwitchError.invalidArchive(
                "component-switch transaction is missing or unsafe")
        }
        return try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: url))
    }
}
