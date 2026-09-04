import Foundation
import XCTest
@testable import CmdyKit

private final class SlowDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var stopped = false
    static let chunkSize = 512 * 1024
    static let chunkCount = 4

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "progress.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(Self.chunkSize * Self.chunkCount),
                    "Content-Type": "application/zip",
                ]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for byte in 0..<Self.chunkCount {
                self.stateLock.lock()
                let stopped = self.stopped
                self.stateLock.unlock()
                if stopped { return }
                self.client?.urlProtocol(
                    self,
                    didLoad: Data(
                        repeating: UInt8(65 + byte), count: Self.chunkSize))
                Thread.sleep(forTimeInterval: 0.14)
            }
            self.stateLock.lock()
            let stopped = self.stopped
            self.stateLock.unlock()
            if !stopped { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

final class BrowserEditionTests: XCTestCase {
    func testFetchDataReportsRealIntermediateDownloadProgress() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var snapshots: [Marketplace.DownloadProgress] = []

        let data = try Marketplace.fetchData(
            URL(string: "https://progress.test/browser.zip")!,
            maxBytes: 4 * 1024 * 1024,
            timeout: 5,
            session: session,
            downloadProgress: { snapshots.append($0) })

        XCTAssertEqual(
            data.count,
            SlowDownloadURLProtocol.chunkSize * SlowDownloadURLProtocol.chunkCount)
        XCTAssertTrue(snapshots.contains {
            guard let percent = $0.percentComplete else { return false }
            return percent > 0 && percent < 100
        })
        XCTAssertEqual(snapshots.last?.percentComplete, 100)
        XCTAssertTrue(zip(snapshots, snapshots.dropFirst()).allSatisfy {
            $0.receivedBytes <= $1.receivedBytes
        })
    }

    func testExtensionWindowKeepsProgressVisibleAcrossReloads() async {
        let diagnostic = await MainActor.run {
            PluginsWindow.shared.performOperationProgressSmokeTest()
        }

        XCTAssertTrue(diagnostic.statusSurvivedReload)
        XCTAssertEqual(diagnostic.determinateValue, 42)
        XCTAssertTrue(diagnostic.indeterminateStageVisible)
        XCTAssertTrue(diagnostic.restartNoticeVisible)
        XCTAssertGreaterThan(diagnostic.indicatorWidth, 100)
    }

    func testBrowserDownloadProgressReportsBytesAndPercentage() {
        let progress = Marketplace.DownloadProgress(
            receivedBytes: 67_108_864,
            expectedBytes: 134_217_728)

        XCTAssertEqual(progress.percentComplete, 50)
        let description = BrowserComponentInstaller.downloadProgressDescription(
            variant: .browser,
            progress: progress)
        XCTAssertTrue(description.contains("Downloading Browser — 50%"))
        XCTAssertTrue(description.contains(" of "))

        let unknownSize = BrowserComponentInstaller.downloadProgressDescription(
            variant: .browser,
            progress: Marketplace.DownloadProgress(
                receivedBytes: 1_048_576,
                expectedBytes: nil))
        XCTAssertTrue(unknownSize.contains("Downloading Browser —"))
        XCTAssertFalse(unknownSize.contains("%"))
    }

    func testExtensionWindowExtractsDownloadPercentage() {
        XCTAssertEqual(
            PluginsWindow.percentValue(
                in: "Browser: Downloading Browser — 42% (61 MB of 146 MB)…"),
            42)
        XCTAssertEqual(PluginsWindow.percentValue(in: "Downloading — 120%"), 100)
        XCTAssertNil(PluginsWindow.percentValue(in: "Verifying download…"))
    }

    func testHardenedRuntimeDetectionMatchesRealCodesignOutput() {
        let developerIDOutput = """
        Executable=/Applications/cmdy.app/Contents/MacOS/cmdy
        Identifier=com.cmdy.app
        Format=app bundle with Mach-O thin (arm64)
        CodeDirectory v=20500 size=12345 flags=0x10000(runtime) hashes=377+7 location=embedded
        Signature size=9094
        Authority=Developer ID Application: Example (ABCDE12345)
        TeamIdentifier=ABCDE12345
        Runtime Version=26.0.0
        """
        XCTAssertTrue(
            BrowserComponentInstaller.signatureHasHardenedRuntime(developerIDOutput))

        let unsignedOutput = """
        CodeDirectory v=20400 size=12345 flags=0x2(adhoc) hashes=377+7 location=embedded
        TeamIdentifier=not set
        Runtime Version=26.0.0
        """
        XCTAssertFalse(
            BrowserComponentInstaller.signatureHasHardenedRuntime(unsignedOutput))
        XCTAssertFalse(
            BrowserComponentInstaller.signatureHasHardenedRuntime(
                "Runtime Version=26.0.0"))
    }

    func testAtomicApplicationExchangeAlwaysKeepsDestinationLaunchable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "cmdy-atomic-app-exchange-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("cmdy.app", isDirectory: true)
        let staged = root.appendingPathComponent(
            ".cmdy-component-stage-\(UUID().uuidString).app", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try "original".write(
            to: destination.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8)
        try "replacement".write(
            to: staged.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8)

        try BrowserComponentInstaller.atomicallyExchangeApplications(
            destination: destination, staged: staged)

        XCTAssertTrue(fm.fileExists(atPath: destination.path))
        XCTAssertTrue(fm.fileExists(atPath: staged.path))
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("marker"),
                encoding: .utf8),
            "replacement")
        XCTAssertEqual(
            try String(
                contentsOf: staged.appendingPathComponent("marker"),
                encoding: .utf8),
            "original")
    }

    func testComponentSwitchMatrixRequiresTheCompleteRequestedLayout() {
        XCTAssertFalse(BrowserComponentInstaller.needsSwitch(
            to: .browser,
            browserEdition: true,
            browserVersion: "2.2.0",
            requiredBrowserVersion: "2.2.0",
            hasRuntime: true,
            containsRuntimePayload: true))
        XCTAssertTrue(BrowserComponentInstaller.needsSwitch(
            to: .browser,
            browserEdition: true,
            browserVersion: "2.1.0",
            requiredBrowserVersion: "2.2.0",
            hasRuntime: true,
            containsRuntimePayload: true))
        XCTAssertFalse(BrowserComponentInstaller.needsSwitch(
            to: .browser,
            browserEdition: true,
            browserVersion: "2.3.0",
            requiredBrowserVersion: "2.2.0",
            hasRuntime: true,
            containsRuntimePayload: true))
        XCTAssertTrue(BrowserComponentInstaller.needsSwitch(
            to: .browser,
            browserEdition: true,
            hasRuntime: false,
            containsRuntimePayload: true))
        XCTAssertTrue(BrowserComponentInstaller.needsSwitch(
            to: .browser,
            browserEdition: false,
            hasRuntime: true,
            containsRuntimePayload: true))

        XCTAssertFalse(BrowserComponentInstaller.needsSwitch(
            to: .lean,
            browserEdition: false,
            hasRuntime: false,
            containsRuntimePayload: false))
        XCTAssertTrue(BrowserComponentInstaller.needsSwitch(
            to: .lean,
            browserEdition: false,
            hasRuntime: false,
            containsRuntimePayload: true))
        XCTAssertTrue(BrowserComponentInstaller.needsSwitch(
            to: .lean,
            browserEdition: true,
            hasRuntime: true,
            containsRuntimePayload: true))
    }

    func testCandidateValidationAcceptsSignedLeanUpgradeAndRejectsPayloadLeak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmdy-component-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let current = try makeSignedTestApp(
            at: root.appendingPathComponent("Current.app"), version: "1.0.3")
        let candidate = try makeSignedTestApp(
            at: root.appendingPathComponent("Candidate.app"), version: "1.0.4")
        let inspection = try BrowserComponentInstaller.validateCandidate(
            candidate,
            replacing: current,
            expectedVariant: .lean,
            minimumVersion: "1.0.3")
        XCTAssertEqual(inspection.version, "1.0.4")
        XCTAssertFalse(inspection.browserEdition)
        XCTAssertFalse(inspection.containsBrowserPayload)

        let leaked = try makeSignedTestApp(
            at: root.appendingPathComponent("Leaked.app"),
            version: "1.0.4",
            partialBrowserPayload: true)
        XCTAssertThrowsError(try BrowserComponentInstaller.validateCandidate(
            leaked,
            replacing: current,
            expectedVariant: .lean,
            minimumVersion: "1.0.3"))

        let newerBuild = try makeSignedTestApp(
            at: root.appendingPathComponent("NewerBuild.app"),
            version: "1.0.4",
            build: "2")
        let olderBuild = try makeSignedTestApp(
            at: root.appendingPathComponent("OlderBuild.app"),
            version: "1.0.4",
            build: "1")
        XCTAssertThrowsError(try BrowserComponentInstaller.validateCandidate(
            olderBuild,
            replacing: newerBuild,
            expectedVariant: .lean,
            minimumVersion: "1.0.4"))
    }

    func testInterruptedPostExchangeRecoveryRestoresOriginalBeforeCleanup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "cmdy-post-exchange-recovery-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = try makeSignedTestApp(
            at: root.appendingPathComponent("cmdy.app"), version: "1.0.3")
        let staged = try makeSignedTestApp(
            at: root.appendingPathComponent(
                ".cmdy-component-stage-\(UUID().uuidString).app"),
            version: "1.0.4")
        let original = try BrowserComponentInstaller.inspectBundle(at: destination)
        let transaction = BrowserComponentInstaller.Transaction(
            schemaVersion: 1,
            token: UUID().uuidString,
            variant: .lean,
            destinationAppPath: destination.path,
            stagedAppPath: staged.path,
            backupAppPath: root.appendingPathComponent(
                ".cmdy-component-backup-\(UUID().uuidString).app").path,
            helperDirectoryPath: root.appendingPathComponent(UUID().uuidString).path,
            lockDirectoryPath: root.appendingPathComponent(
                ".browser-component-switch.lock").path,
            bundleIdentifier: original.identifier,
            candidateVersion: "1.0.4",
            candidateBuild: "1",
            waitingPIDs: [],
            originalInspection: original,
            activation: nil,
            browserComponentVersion: nil,
            createdAt: Date().timeIntervalSince1970,
            testOnlyExitAfterConfirmation: true,
            testOnlySuppressConfirmation: false,
            testOnlyConfirmationTimeoutSeconds: nil,
            state: .staged,
            message: nil)

        // Simulate interruption directly after RENAME_SWAP and before the old
        // app at `staged` is renamed to the backup path.
        try BrowserComponentInstaller.atomicallyExchangeApplications(
            destination: destination, staged: staged)
        XCTAssertEqual(
            try BrowserComponentInstaller.inspectBundle(at: destination).version,
            "1.0.4")

        try BrowserComponentInstaller.restoreOriginalAcrossInterruptedExchange(
            transaction)

        XCTAssertEqual(
            try BrowserComponentInstaller.inspectBundle(at: destination), original)
        XCTAssertEqual(
            try BrowserComponentInstaller.inspectBundle(at: staged).version,
            "1.0.4")
    }

    func testActivationRollbackIsBoundedAndRestoresPreviousInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmdy-activation-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("chromium", isDirectory: true)
        let backup = root.appendingPathComponent(
            ".chromium-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "new".write(
            to: destination.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try "old".write(
            to: backup.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8)

        let change = BrowserComponentInstaller.ActivationChange(
            kind: .installed,
            rootPath: root.path,
            destinationPath: destination.path,
            backupPath: backup.path)
        XCTAssertTrue(BrowserComponentInstaller.validateActivationChange(change))
        XCTAssertTrue(BrowserComponentInstaller.activationChangeIsApplied(change))
        try BrowserComponentInstaller.rollbackActivation(change)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("marker"),
                encoding: .utf8),
            "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(BrowserComponentInstaller.activationChangeIsApplied(change))

        try FileManager.default.moveItem(at: destination, to: backup)
        let removal = BrowserComponentInstaller.ActivationChange(
            kind: .removed,
            rootPath: root.path,
            destinationPath: destination.path,
            backupPath: backup.path)
        XCTAssertTrue(BrowserComponentInstaller.validateActivationChange(removal))
        XCTAssertTrue(BrowserComponentInstaller.activationChangeIsApplied(removal))
        try BrowserComponentInstaller.rollbackActivation(removal)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("marker"),
                encoding: .utf8),
            "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(BrowserComponentInstaller.activationChangeIsApplied(removal))

        let unsafe = BrowserComponentInstaller.ActivationChange(
            kind: .removed,
            rootPath: "/",
            destinationPath: "/Applications",
            backupPath: "/.backup")
        XCTAssertFalse(BrowserComponentInstaller.validateActivationChange(unsafe))
    }

    func testFreshActivationMustExistBeforeConfirmation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmdy-fresh-activation-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("chromium", isDirectory: true)
        let change = BrowserComponentInstaller.ActivationChange(
            kind: .installed,
            rootPath: root.path,
            destinationPath: destination.path,
            backupPath: nil)

        XCTAssertFalse(BrowserComponentInstaller.activationChangeIsApplied(change))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertTrue(BrowserComponentInstaller.activationChangeIsApplied(change))
        try BrowserComponentInstaller.rollbackActivation(change)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(BrowserComponentInstaller.activationChangeIsApplied(change))
    }

    func testConfirmedActivationRemainsRecoverableAfterBackupCleanup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(
                "cmdy-confirmed-activation-\(UUID().uuidString)",
                isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("chromium", isDirectory: true)
        let backup = root.appendingPathComponent(
            ".chromium-backup-\(UUID().uuidString)", isDirectory: true)

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let installed = BrowserComponentInstaller.ActivationChange(
            kind: .installed,
            rootPath: root.path,
            destinationPath: destination.path,
            backupPath: backup.path)
        XCTAssertTrue(BrowserComponentInstaller.activationChangeIsApplied(installed))
        try BrowserComponentInstaller.finalizeActivation(installed)
        XCTAssertFalse(BrowserComponentInstaller.activationChangeIsApplied(installed))
        XCTAssertTrue(
            BrowserComponentInstaller.activationChangeHasRequestedResult(installed))

        try fm.moveItem(at: destination, to: backup)
        let removed = BrowserComponentInstaller.ActivationChange(
            kind: .removed,
            rootPath: root.path,
            destinationPath: destination.path,
            backupPath: backup.path)
        XCTAssertTrue(BrowserComponentInstaller.activationChangeIsApplied(removed))
        try BrowserComponentInstaller.finalizeActivation(removed)
        XCTAssertFalse(BrowserComponentInstaller.activationChangeIsApplied(removed))
        XCTAssertTrue(
            BrowserComponentInstaller.activationChangeHasRequestedResult(removed))
    }

    func testNonterminalSwitchLocksNeverExpireAutomatically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmdy-recovery-lock-\(UUID().uuidString)", isDirectory: true)
        let lock = root.appendingPathComponent(
            ".browser-component-switch.lock", isDirectory: true)
        let transactionURL = root.appendingPathComponent("transaction.json")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let token = UUID().uuidString
        let lockJSON: [String: Any] = [
            "schemaVersion": 1,
            "token": token,
            "transactionPath": transactionURL.path,
            "ownerPID": Int(Int32.max),
            "createdAt": 0,
        ]
        let lockData = try JSONSerialization.data(withJSONObject: lockJSON)
        try lockData.write(to: lock.appendingPathComponent("owner.json"), options: .atomic)

        for state in [
            BrowserComponentInstaller.TransactionState.staged,
            .awaitingConfirmation,
            .confirmed,
            .recoveryRequired,
        ] {
            let transaction = BrowserComponentInstaller.Transaction(
                schemaVersion: 1,
                token: token,
                variant: .browser,
                destinationAppPath: root.appendingPathComponent("cmdy.app").path,
                stagedAppPath: root.appendingPathComponent("staged.app").path,
                backupAppPath: root.appendingPathComponent("backup.app").path,
                helperDirectoryPath: root.appendingPathComponent("helper").path,
                lockDirectoryPath: lock.path,
                bundleIdentifier: "com.cmdy.app",
                candidateVersion: "1.0.4",
                candidateBuild: "1",
                waitingPIDs: [],
                activation: nil,
                browserComponentVersion: "2.2.0",
                createdAt: 0,
                testOnlyExitAfterConfirmation: true,
                testOnlySuppressConfirmation: false,
                testOnlyConfirmationTimeoutSeconds: nil,
                state: state,
                message: "manual recovery required")
            try JSONEncoder().encode(transaction).write(
                to: transactionURL, options: .atomic)
            XCTAssertFalse(BrowserComponentInstaller.recoverStaleSwitchLock(at: lock))
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        }
    }

    func testOnePerUserLeaseSerializesDifferentConfigRoots() throws {
        let originalConfig = getenv("CMDY_CONFIG_DIR").map { String(cString: $0) }
        defer {
            if let originalConfig { setenv("CMDY_CONFIG_DIR", originalConfig, 1) }
            else { unsetenv("CMDY_CONFIG_DIR") }
        }
        let firstConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-config-a-\(UUID().uuidString)")
        let secondConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-config-b-\(UUID().uuidString)")
        setenv("CMDY_CONFIG_DIR", firstConfig.path, 1)
        let firstCanonicalLock = BrowserComponentInstaller.switchLockDirectory()
        setenv("CMDY_CONFIG_DIR", secondConfig.path, 1)
        XCTAssertEqual(
            BrowserComponentInstaller.switchLockDirectory().path,
            firstCanonicalLock.path)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmdy-lock-contention-\(UUID().uuidString)", isDirectory: true)
        let lock = root.appendingPathComponent(
            ".browser-component-switch.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstToken = UUID().uuidString
        try BrowserComponentInstaller.acquireSwitchLock(
            at: lock,
            token: firstToken,
            transactionURL: firstConfig.appendingPathComponent("switch.json"))
        XCTAssertThrowsError(try BrowserComponentInstaller.acquireSwitchLock(
            at: lock,
            token: UUID().uuidString,
            transactionURL: secondConfig.appendingPathComponent("switch.json")))
        BrowserComponentInstaller.releaseSwitchLock(at: lock, token: firstToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testFailedBrowserRelaunchExplainsVerifiedRollback() throws {
        let environmentKey = "CMDY_CONFIG_DIR"
        let previous = getenv(environmentKey).map { String(cString: $0) }
        defer {
            if let previous { setenv(environmentKey, previous, 1) }
            else { unsetenv(environmentKey) }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmdy-failed-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv(environmentKey, root.path, 1)

        let token = UUID().uuidString
        let transactionURL = root.appendingPathComponent("browser-switch.json")
        let appParent = root.appendingPathComponent("Applications", isDirectory: true)
        let lock = root.appendingPathComponent(
            "com.cmdy.app/ComponentSwitch/.browser-component-switch.lock",
            isDirectory: true)
        let transaction = BrowserComponentInstaller.Transaction(
            schemaVersion: 1,
            token: token,
            variant: .browser,
            destinationAppPath: appParent.appendingPathComponent("cmdy.app").path,
            stagedAppPath: appParent.appendingPathComponent(
                ".cmdy-component-stage-test.app").path,
            backupAppPath: appParent.appendingPathComponent(
                ".cmdy-component-backup-test.app").path,
            helperDirectoryPath: root.appendingPathComponent("helper").path,
            lockDirectoryPath: lock.path,
            bundleIdentifier: "com.cmdy.app",
            candidateVersion: "1.0.6",
            candidateBuild: "1",
            waitingPIDs: [],
            activation: nil,
            browserComponentVersion: "2.2.0",
            createdAt: Date().timeIntervalSince1970,
            testOnlyExitAfterConfirmation: false,
            testOnlySuppressConfirmation: false,
            testOnlyConfirmationTimeoutSeconds: nil,
            state: .failed,
            message: "the replacement app exited before confirming startup")
        try JSONEncoder().encode(transaction).write(
            to: transactionURL, options: .atomic)

        let message = BrowserComponentInstaller.failedRelaunchMessageIfRequested([
            "cmdy", BrowserComponentInstaller.failureArgument,
            transactionURL.path, token,
        ])
        XCTAssertEqual(
            message,
            "Browser could not start, so cmdy restored the previous app. "
                + "the replacement app exited before confirming startup")
        XCTAssertNil(BrowserComponentInstaller.failedRelaunchMessageIfRequested([
            "cmdy", BrowserComponentInstaller.failureArgument,
            transactionURL.path, "wrong-token",
        ]))
    }

    func testConfirmationWaitDetectsReplacementProcessExitPromptly() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        try process.run()

        let startedAt = Date()
        let result = BrowserComponentInstaller.waitForConfirmation(
            at: FileManager.default.temporaryDirectory.appendingPathComponent(
                "missing-browser-switch-\(UUID().uuidString).json"),
            token: UUID().uuidString,
            processIdentifier: process.processIdentifier,
            timeout: 3)
        process.waitUntilExit()

        XCTAssertEqual(result, .processExited)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testConfirmationWinsWhenReplacementExitsAtCommitPoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmdy-confirm-exit-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString
        let transactionURL = root.appendingPathComponent("browser-switch.json")
        let appParent = root.appendingPathComponent("Applications", isDirectory: true)
        let lock = root.appendingPathComponent(
            "com.cmdy.app/ComponentSwitch/.browser-component-switch.lock",
            isDirectory: true)
        var transaction = BrowserComponentInstaller.Transaction(
            schemaVersion: 1,
            token: token,
            variant: .browser,
            destinationAppPath: appParent.appendingPathComponent("cmdy.app").path,
            stagedAppPath: appParent.appendingPathComponent(
                ".cmdy-component-stage-test.app").path,
            backupAppPath: appParent.appendingPathComponent(
                ".cmdy-component-backup-test.app").path,
            helperDirectoryPath: root.appendingPathComponent("helper").path,
            lockDirectoryPath: lock.path,
            bundleIdentifier: "com.cmdy.app",
            candidateVersion: "1.0.6",
            candidateBuild: "1",
            waitingPIDs: [],
            activation: nil,
            browserComponentVersion: "2.2.0",
            createdAt: Date().timeIntervalSince1970,
            testOnlyExitAfterConfirmation: true,
            testOnlySuppressConfirmation: false,
            testOnlyConfirmationTimeoutSeconds: 1,
            state: .awaitingConfirmation,
            message: nil)
        try JSONEncoder().encode(transaction).write(
            to: transactionURL, options: .atomic)

        var livenessChecks = 0
        let result = BrowserComponentInstaller.waitForConfirmation(
            at: transactionURL,
            token: token,
            processIdentifier: Int32.max,
            timeout: 1,
            processIsRunning: { _ in
                livenessChecks += 1
                transaction.state = .confirmed
                try? JSONEncoder().encode(transaction).write(
                    to: transactionURL, options: .atomic)
                return false
            })

        XCTAssertEqual(livenessChecks, 1)
        XCTAssertEqual(result, .confirmed)
    }

    func testRestoredAppRelaunchRetriesWithFailureContext() throws {
        let transactionURL = URL(fileURLWithPath: "/tmp/browser-switch.json")
        let token = UUID().uuidString
        var attempts = 0
        var receivedArguments: [String] = []
        try BrowserComponentInstaller.relaunchRestoredApplication(
            at: URL(fileURLWithPath: "/Applications/cmdy.app"),
            transactionURL: transactionURL,
            token: token,
            attempts: 3,
            retryDelayMicroseconds: 0,
            launch: { _, arguments in
                attempts += 1
                receivedArguments = arguments
                if attempts < 3 {
                    throw BrowserComponentSwitchError.helperLaunchFailed(
                        "simulated relaunch refusal")
                }
            })

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(receivedArguments, [
            BrowserComponentInstaller.failureArgument,
            transactionURL.path,
            token,
        ])
    }

    func testRetainedFailedSwitchExplainsAutomaticRelaunchFailure() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "cmdy-retained-relaunch-failure-\(UUID().uuidString)",
            isDirectory: true)
        let transactionURL = root.appendingPathComponent("browser-switch.json")
        let appParent = root.appendingPathComponent("Applications", isDirectory: true)
        let lock = root.appendingPathComponent(
            "com.cmdy.app/ComponentSwitch/.browser-component-switch.lock",
            isDirectory: true)
        try fm.createDirectory(
            at: lock.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let token = UUID().uuidString
        try BrowserComponentInstaller.acquireSwitchLock(
            at: lock, token: token, transactionURL: transactionURL)
        let transaction = BrowserComponentInstaller.Transaction(
            schemaVersion: 1,
            token: token,
            variant: .browser,
            destinationAppPath: appParent.appendingPathComponent("cmdy.app").path,
            stagedAppPath: appParent.appendingPathComponent(
                ".cmdy-component-stage-test.app").path,
            backupAppPath: appParent.appendingPathComponent(
                ".cmdy-component-backup-test.app").path,
            helperDirectoryPath: root.appendingPathComponent(
                "ComponentSwitch/\(UUID().uuidString)").path,
            lockDirectoryPath: lock.path,
            bundleIdentifier: "com.cmdy.app",
            candidateVersion: "1.0.6",
            candidateBuild: "1",
            waitingPIDs: [],
            activation: nil,
            browserComponentVersion: "2.2.0",
            createdAt: Date().timeIntervalSince1970,
            testOnlyExitAfterConfirmation: false,
            testOnlySuppressConfirmation: false,
            testOnlyConfirmationTimeoutSeconds: nil,
            state: .failed,
            message: "the previous app was restored, but macOS refused every relaunch")
        try JSONEncoder().encode(transaction).write(
            to: transactionURL, options: .atomic)

        let message = await BrowserComponentInstaller
            .recoverInterruptedSwitchAfterLaunch(
                lockDirectory: lock,
                browserRuntimeReady: { false })

        XCTAssertTrue(message?.contains("rolled back safely") == true)
        XCTAssertTrue(message?.contains("macOS refused every relaunch") == true)
        XCTAssertFalse(fm.fileExists(atPath: lock.path))
    }

    func testMissingTransactionActivationIntentRecoversEveryRenameBoundary() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "cmdy-activation-intent-\(UUID().uuidString)", isDirectory: true)
        let extensions = root.appendingPathComponent("extensions", isDirectory: true)
        let destination = extensions.appendingPathComponent("chromium", isDirectory: true)
        let backup = extensions.appendingPathComponent(".chromium-backup", isDirectory: true)
        let lock = root.appendingPathComponent(
            ".browser-component-switch.lock", isDirectory: true)
        let transaction = root.appendingPathComponent("missing-transaction.json")
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func writeDirectory(_ url: URL, marker: String) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try marker.write(
                to: url.appendingPathComponent("marker"),
                atomically: true,
                encoding: .utf8)
        }
        func marker(at url: URL) throws -> String {
            try String(
                contentsOf: url.appendingPathComponent("marker"),
                encoding: .utf8)
        }
        func writeDeadLease(_ change: BrowserComponentInstaller.ActivationChange) throws {
            try? fm.removeItem(at: lock)
            try fm.createDirectory(at: lock, withIntermediateDirectories: true)
            let activation: [String: Any] = [
                "kind": change.kind.rawValue,
                "rootPath": change.rootPath,
                "destinationPath": change.destinationPath,
                "backupPath": change.backupPath.map { $0 as Any } ?? NSNull(),
            ]
            let json: [String: Any] = [
                "schemaVersion": 1,
                "token": "dead-owner",
                "transactionPath": transaction.path,
                "ownerPID": Int(Int32.max),
                "createdAt": 0,
                "activation": activation,
            ]
            try JSONSerialization.data(withJSONObject: json).write(
                to: lock.appendingPathComponent("owner.json"), options: .atomic)
        }

        let update = BrowserComponentInstaller.ActivationChange(
            kind: .installed,
            rootPath: extensions.path,
            destinationPath: destination.path,
            backupPath: backup.path)

        // No rename occurred: the previous activation stays untouched.
        try writeDirectory(destination, marker: "old")
        try writeDeadLease(update)
        XCTAssertTrue(BrowserComponentInstaller.recoverStaleSwitchLock(at: lock))
        XCTAssertEqual(try marker(at: destination), "old")

        // The previous activation moved but the new one never arrived.
        try fm.moveItem(at: destination, to: backup)
        try writeDeadLease(update)
        XCTAssertTrue(BrowserComponentInstaller.recoverStaleSwitchLock(at: lock))
        XCTAssertEqual(try marker(at: destination), "old")
        XCTAssertFalse(fm.fileExists(atPath: backup.path))

        // Both renames occurred: discard new and restore old.
        try fm.moveItem(at: destination, to: backup)
        try writeDirectory(destination, marker: "new")
        try writeDeadLease(update)
        XCTAssertTrue(BrowserComponentInstaller.recoverStaleSwitchLock(at: lock))
        XCTAssertEqual(try marker(at: destination), "old")
        XCTAssertFalse(fm.fileExists(atPath: backup.path))

        // Fresh install with no previous backup is removed.
        try fm.removeItem(at: destination)
        try writeDirectory(destination, marker: "fresh")
        let fresh = BrowserComponentInstaller.ActivationChange(
            kind: .installed,
            rootPath: extensions.path,
            destinationPath: destination.path,
            backupPath: nil)
        try writeDeadLease(fresh)
        XCTAssertTrue(BrowserComponentInstaller.recoverStaleSwitchLock(at: lock))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))

        // Removal restores the activation from its durable backup.
        try writeDirectory(backup, marker: "old")
        let removal = BrowserComponentInstaller.ActivationChange(
            kind: .removed,
            rootPath: extensions.path,
            destinationPath: destination.path,
            backupPath: backup.path)
        try writeDeadLease(removal)
        XCTAssertTrue(BrowserComponentInstaller.recoverStaleSwitchLock(at: lock))
        XCTAssertEqual(try marker(at: destination), "old")
        XCTAssertFalse(fm.fileExists(atPath: backup.path))

        // Missing both sides is ambiguous and must preserve the lease.
        try fm.removeItem(at: destination)
        try writeDeadLease(removal)
        XCTAssertFalse(BrowserComponentInstaller.recoverStaleSwitchLock(at: lock))
        XCTAssertTrue(fm.fileExists(atPath: lock.path))
    }

    func testOnlyCanonicalBrowserManifestCanActivateHostComponent() throws {
        let browser = try ExtensionManifest(
            id: BrowserEdition.marketplaceID,
            name: "Browser",
            version: "2.1.0",
            entrypoint: "browser-component",
            capabilities: [],
            hostComponent: BrowserEdition.hostComponentIdentifier)
        XCTAssertTrue(BrowserEdition.authorizesHostComponent(
            BrowserEdition.hostComponentIdentifier, manifest: browser))

        var impersonator = browser
        impersonator.id = "dev.example.impersonator"
        XCTAssertFalse(BrowserEdition.authorizesHostComponent(
            BrowserEdition.hostComponentIdentifier, manifest: impersonator))
        XCTAssertFalse(BrowserEdition.authorizesHostComponent(
            "unknown-host-component", manifest: browser))
    }

    @MainActor
    func testTransientCLIStopPreservesBrowserEnabledPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmdy-transient-browser-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try ExtensionManifest(
            id: BrowserEdition.marketplaceID,
            name: "Browser",
            version: "2.2.0",
            entrypoint: "browser-component",
            enabled: true,
            capabilities: [],
            hostComponent: BrowserEdition.hostComponentIdentifier)
        try manifest.encoded().write(to: root.appendingPathComponent("manifest.json"))
        let executable = root.appendingPathComponent("browser-component")
        try "#!/bin/sh\nexit 0\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try PluginManager.shared.setPluginRunningTransiently(false, at: root)
        XCTAssertTrue(try ExtensionManifest.load(from: root).enabled)
    }

    func testBrowserUsesStableMarketplaceExtensionIdentity() {
        XCTAssertEqual(BrowserEdition.marketplaceID, "dev.termite.chromium")
        XCTAssertTrue(BrowserEdition.guide.plainText.contains("real split inside"))
        XCTAssertTrue(BrowserEdition.guide.plainText.contains("visible browser is built into"))
        XCTAssertTrue(BrowserEdition.guide.plainText.lowercased().contains("remove browser"))
    }

    func testConfigTemplateDoesNotOfferRetiredBootBanner() {
        XCTAssertNil(ConfigFile.parse(ConfigFile.template())["banner"])
    }

    func testEditingMigratesRetiredBannerAndPreservesCustomSettings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "cmdy-banner-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let environmentKey = "CMDY_CONFIG_DIR"
        let previous = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, root.path, 1)
        defer {
            if let previous { setenv(environmentKey, previous, 1) }
            else { unsetenv(environmentKey) }
        }

        let original = ConfigFile.template()
            + "\nbanner = true\ncustom-release-note = preserved\n"
        try original.write(to: ConfigFile.url, atomically: true, encoding: .utf8)
        _ = ConfigFile.prepareForEditing()

        let migrated = try String(contentsOf: ConfigFile.url, encoding: .utf8)
        let backup = try String(
            contentsOf: ConfigFile.url.appendingPathExtension("bak"),
            encoding: .utf8)
        XCTAssertNil(ConfigFile.parse(migrated)["banner"])
        XCTAssertEqual(
            ConfigFile.parse(migrated)["custom-release-note"], "preserved")
        XCTAssertEqual(backup, original)
    }

    private func makeSignedTestApp(
        at app: URL,
        version: String,
        build: String = "1",
        partialBrowserPayload: Bool = false
    ) throws -> URL {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("cmdy")
        try "#!/bin/sh\nexit 0\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.cmdy.app",
            "CFBundleExecutable": "cmdy",
            "CFBundleName": "cmdy",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if partialBrowserPayload {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent(
                    "Resources/BrowserMCP", isDirectory: true),
                withIntermediateDirectories: true)
        }
        let result = try ProcessCapture.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force", "--deep", "--sign", "-",
                "--identifier", "com.cmdy.app", app.path,
            ],
            timeout: 60,
            outputLimit: 1_048_576)
        XCTAssertEqual(result.terminationStatus, 0, result.output)
        return app
    }
}
