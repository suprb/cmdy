import CryptoKit
import Foundation
import ProductIdentity

extension Notification.Name {
    /// Posted on the main thread when an app release becomes available or is cleared.
    public static let cmdyAppUpdateChanged = Notification.Name("cmdy.appUpdateChanged")
}

public struct AppReleaseUpdate: Codable, Equatable, Sendable {
    public let version: String
    public let name: String
    public let releaseURL: URL
    public let assetURL: URL?
    public let assetName: String?
    public let checksumURL: URL?
    public let notes: String

    public var downloadURL: URL { assetURL ?? releaseURL }
    public var canDownloadAutomatically: Bool {
        assetURL != nil && assetName != nil && checksumURL != nil
    }
}

public enum AppUpdateDownloadState: Equatable, Sendable {
    case idle
    case downloading
    case ready(URL)
    case failed(String)
}

/// Checks the latest stable GitHub Release at most twice a day. When the
/// release contains a matching macOS ZIP and SHA-256 sidecar, cmdy stages the
/// archive in its cache automatically. Installation remains an explicit user
/// action: downloaded code is never executed and the running app is never
/// replaced by this monitor.
public final class AppUpdateMonitor {
    nonisolated(unsafe) public static let shared = AppUpdateMonitor(
        stateURL: ConfigFile.directory.appendingPathComponent(
            "app-update-state.json"))

    public private(set) var availableUpdate: AppReleaseUpdate?
    public private(set) var downloadState: AppUpdateDownloadState = .idle
    public private(set) var isChecking = false
    public var currentVersion: String? {
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           Self.versionComponents(value) != nil {
            return value
        }

        // Test harnesses and direct CLI launches do not always associate the
        // process with its surrounding .app bundle. Fall back to the adjacent
        // Contents/Info.plist so those launches receive the same update state.
        guard let executable = BrowserComponentInstaller.runningExecutableURL() else {
            return nil
        }
        let infoURL = executable
            .deletingLastPathComponent()
            // Contents/MacOS/cmdy -> Contents/Info.plist
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let value = dictionary["CFBundleShortVersionString"] as? String,
              Self.versionComponents(value) != nil else { return nil }
        return value
    }

    nonisolated static let checkInterval: TimeInterval = 12 * 60 * 60
    nonisolated static let latestReleaseURL =
        ProductIdentity.current.latestReleaseAPIURL

    private struct PersistedState: Codable {
        var lastCheck: TimeInterval = 0
        var cachedRelease: AppReleaseUpdate?
        var notifiedAvailableVersion: String?
        var notifiedDownloadVersion: String?
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let htmlURL: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
            case draft
            case prerelease
            case assets
        }
    }

    private var restoredCache = false
    private var checkTimer: Timer?
    private var checkCompletions: [(AppReleaseUpdate?) -> Void] = []
    private var checksumTask: URLSessionDownloadTask?
    private var archiveTask: URLSessionDownloadTask?
    private var activeDownloadID: UUID?
    private let stateURL: URL

    init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func startMonitoring() {
        precondition(Thread.isMainThread, "app update state is main-thread owned")
        checkIfDue()
        guard checkTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.checkInterval, repeats: true
        ) { [weak self] _ in
            self?.checkIfDue()
        }
        timer.tolerance = 15 * 60
        checkTimer = timer
    }

    public func checkIfDue(
        force: Bool = false,
        completion: ((AppReleaseUpdate?) -> Void)? = nil
    ) {
        precondition(Thread.isMainThread, "app update state is main-thread owned")
        guard let currentVersion else {
            completion?(nil)
            return
        }
        let prefersBrowserEdition = browserEditionInstalled
        restoreCache(
            currentVersion: currentVersion,
            prefersBrowserEdition: prefersBrowserEdition)

        var state = loadState()
        let elapsed = Date().timeIntervalSince1970 - state.lastCheck
        if isChecking {
            if let completion { checkCompletions.append(completion) }
            return
        }
        guard force || state.lastCheck == 0 || elapsed >= Self.checkInterval else {
            completion?(availableUpdate)
            return
        }
        if let completion { checkCompletions.append(completion) }

        isChecking = true
        state.lastCheck = Date().timeIntervalSince1970
        saveState(state)

        var request = URLRequest(
            url: Self.latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(
            "\(ProductIdentity.current.slug)/\(currentVersion)",
            forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let release: AppReleaseUpdate?
            if status == 404 {
                release = nil
            } else if status == 200, let data, data.count <= 1_048_576 {
                release = try? Self.decodeRelease(
                    data,
                    prefersBrowserEdition: prefersBrowserEdition)
            } else {
                release = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                // Network and server failures retain a previously known update.
                if status == 200 || status == 404 {
                    var saved = self.loadState()
                    saved.cachedRelease = release
                    self.saveState(saved)
                    self.apply(release, currentVersion: currentVersion)
                }
                self.finishCheckCompletions()
            }
        }.resume()
    }

    nonisolated static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        guard let candidate = versionComponents(candidate),
              let installed = versionComponents(installed) else { return false }
        return installed.lexicographicallyPrecedes(candidate)
    }

    nonisolated static func isNumericVersion(_ value: String) -> Bool {
        versionComponents(value) != nil
    }

    nonisolated static func decodeRelease(
        _ data: Data,
        prefersBrowserEdition: Bool = false,
        requiredBrowserComponentVersion: String? = nil
    ) throws -> AppReleaseUpdate? {
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !payload.draft, !payload.prerelease,
              let version = normalizedVersion(payload.tagName),
              payload.htmlURL.scheme == "https",
              payload.htmlURL.host?.lowercased() == "github.com" else { return nil }

        let archives = payload.assets.filter { candidate in
            return isReleaseArchiveName(
                candidate.name,
                version: version,
                browserEdition: prefersBrowserEdition,
                requiredBrowserComponentVersion: requiredBrowserComponentVersion)
                && safeAssetName(candidate.name)
                && isOfficialAssetURL(candidate.browserDownloadURL)
        }
        let asset = preferredArchive(in: archives)
        let checksum = asset.flatMap { archive in
            payload.assets.first { candidate in
                candidate.name == archive.name + ".sha256"
                    && safeAssetName(candidate.name)
                    && isOfficialAssetURL(candidate.browserDownloadURL)
            }
        }
        return AppReleaseUpdate(
            version: version,
            name: String((payload.name ?? payload.tagName).prefix(200)),
            releaseURL: payload.htmlURL,
            assetURL: asset?.browserDownloadURL,
            assetName: asset?.name,
            checksumURL: checksum?.browserDownloadURL,
            notes: String((payload.body ?? "").prefix(8_000)))
    }

    nonisolated static func isReleaseArchiveName(
        _ rawName: String,
        version: String,
        browserEdition: Bool,
        requiredBrowserComponentVersion: String? = nil
    ) -> Bool {
        let name = rawName.lowercased()
        let prefix = ProductIdentity.current.releaseAssetPrefix.lowercased()
        let expectedPrefix = "\(prefix)-\(version.lowercased())-"
        guard name.hasPrefix(expectedPrefix), name.hasSuffix(".zip") else {
            return false
        }

        let body = String(name.dropFirst(expectedPrefix.count).dropLast(4))
        let supportedArchitectures = [
            "arm64", "x86_64", "arm64-x86_64", "x86_64-arm64",
            "universal", "universal2",
        ]

        if browserEdition {
            guard body.hasPrefix("browser-"),
                  let platformRange = body.range(of: "-macos-"),
                  platformRange.lowerBound > body.startIndex else { return false }
            let browserVersion = body[
                body.index(body.startIndex, offsetBy: "browser-".count)
                    ..< platformRange.lowerBound]
            let architecture = String(body[platformRange.upperBound...])
            let matchesRequiredVersion = requiredBrowserComponentVersion.map {
                String(browserVersion) == $0
                    || isVersion(String(browserVersion), newerThan: $0)
            } ?? true
            return browserVersion.split(separator: ".").count == 3
                && browserVersion.split(separator: ".").allSatisfy {
                    !$0.isEmpty && $0.allSatisfy(\.isNumber)
                }
                && matchesRequiredVersion
                && supportedArchitectures.contains(architecture)
        }

        return supportedArchitectures.contains { body == "macos-\($0)" }
    }

    nonisolated private static func preferredArchive(
        in assets: [GitHubRelease.Asset]
    ) -> GitHubRelease.Asset? {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = ""
        #endif
        return assets.sorted { lhs, rhs in
            func score(_ asset: GitHubRelease.Asset) -> Int {
                let name = asset.name.lowercased()
                if !architecture.isEmpty && name.contains("-\(architecture).") { return 3 }
                if name.contains("-universal.") || name.contains("-universal2.") { return 2 }
                return 1
            }
            return score(lhs) > score(rhs)
        }.first
    }

    nonisolated private static func isOfficialAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return false }
        let repository = ProductIdentity.current.githubRepository.lowercased()
        return url.path.lowercased().hasPrefix("/\(repository)/releases/download/")
    }

    nonisolated static func safeAssetName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 240
            && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("/") && !value.contains("\\")
    }

    nonisolated static func expectedChecksum(
        from data: Data,
        assetName: String
    ) -> String? {
        guard data.count <= 8 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first else { continue }
            let digest = String(first).lowercased()
            guard digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }) else { continue }
            if fields.count > 1 {
                let publishedName = String(fields.last!).trimmingCharacters(
                    in: CharacterSet(charactersIn: "*"))
                guard URL(fileURLWithPath: publishedName).lastPathComponent
                        == assetName else { continue }
            }
            return digest
        }
        return nil
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func normalizedVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        return versionComponents(version) == nil ? nil : version
    }

    nonisolated private static func versionComponents(_ value: String) -> [Int]? {
        let normalized = value.lowercased().hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece) else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        return numbers
    }

    private var browserEditionInstalled: Bool {
        let activationInstalled = BrowserEdition.isActivationInstalled
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "CMDYBrowserEdition") as? Bool {
            return Self.prefersBrowserEdition(
                bundleMarker: value,
                browserActivationInstalled: activationInstalled)
        }

        guard let executable = BrowserComponentInstaller.runningExecutableURL() else {
            return activationInstalled
        }
        let infoURL = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return activationInstalled
        }
        return Self.prefersBrowserEdition(
            bundleMarker: dictionary["CMDYBrowserEdition"] as? Bool ?? false,
            browserActivationInstalled: activationInstalled)
    }

    /// 1.0.3's canonical artifact contained CEF but deliberately carried a
    /// false edition marker. Preserve Browser for those users when its normal
    /// Marketplace activation is installed, while new lean installs continue
    /// to follow the lean update stream.
    nonisolated static func prefersBrowserEdition(
        bundleMarker: Bool,
        browserActivationInstalled: Bool
    ) -> Bool {
        bundleMarker || browserActivationInstalled
    }

    nonisolated private static func releaseMatchesEdition(
        _ release: AppReleaseUpdate,
        prefersBrowserEdition: Bool
    ) -> Bool {
        guard let assetName = release.assetName else { return true }
        return assetName.lowercased().contains("-browser-") == prefersBrowserEdition
    }

    private func restoreCache(
        currentVersion: String,
        prefersBrowserEdition: Bool
    ) {
        guard !restoredCache else { return }
        restoredCache = true
        var state = loadState()
        if let cached = state.cachedRelease,
           !Self.releaseMatchesEdition(
            cached,
            prefersBrowserEdition: prefersBrowserEdition) {
            // The canonical app and legacy Browser-edition updater clients
            // deliberately share settings. Do not let a cached archive for
            // the other variant replace this installation; force a fresh
            // release lookup instead.
            state.cachedRelease = nil
            state.lastCheck = 0
            saveState(state)
        }
        apply(state.cachedRelease, currentVersion: currentVersion)
    }

    func apply(
        _ release: AppReleaseUpdate?,
        currentVersion: String,
        notify: Bool = true
    ) {
        let next = release.flatMap {
            Self.isVersion($0.version, newerThan: currentVersion) ? $0 : nil
        }
        let changed = next != availableUpdate
        availableUpdate = next
        if let next {
            if changed { notifyAvailabilityIfNeeded(next) }
            if changed || downloadState == .idle { startAutomaticDownload(next) }
        } else {
            cancelDownload()
            setDownloadState(.idle, release: nil)
        }
        if notify && changed {
            NotificationCenter.default.post(name: .cmdyAppUpdateChanged, object: self)
        }
    }

    private func notifyAvailabilityIfNeeded(_ release: AppReleaseUpdate) {
        var state = loadState()
        guard Self.shouldNotifyAvailableVersion(
            release.version,
            previouslyNotified: state.notifiedAvailableVersion
        ) else { return }
        state.notifiedAvailableVersion = release.version
        saveState(state)
        Notifier.post(
            title: Self.availabilityNotificationTitle,
            body: Self.availabilityNotificationBody(for: release))
    }

    nonisolated static var availabilityNotificationTitle: String {
        "New \(ProductIdentity.current.displayName) update available"
    }

    nonisolated static func shouldNotifyAvailableVersion(
        _ version: String,
        previouslyNotified: String?
    ) -> Bool {
        previouslyNotified != version
    }

    nonisolated static func availabilityNotificationBody(
        for release: AppReleaseUpdate
    ) -> String {
        if release.canDownloadAutomatically {
            return "Version \(release.version) is downloading and being verified. "
                + "Open Check for Updates for details."
        }
        return "Version \(release.version) is available. "
            + "Open Check for Updates to view the release."
    }

    public func retryAutomaticDownload() {
        precondition(Thread.isMainThread, "app update state is main-thread owned")
        guard let availableUpdate else { return }
        startAutomaticDownload(availableUpdate)
    }

    private func startAutomaticDownload(_ release: AppReleaseUpdate) {
        cancelDownload()
        guard let assetURL = release.assetURL,
              let assetName = release.assetName,
              let checksumURL = release.checksumURL,
              Self.safeAssetName(assetName) else {
            setDownloadState(.idle, release: release)
            return
        }

        let downloadID = UUID()
        activeDownloadID = downloadID
        setDownloadState(.downloading, release: release)
        let checksumRequest = Self.downloadRequest(
            url: checksumURL, version: release.version)
        let task = URLSession.shared.downloadTask(with: checksumRequest) {
            [weak self] temporaryURL, response, error in
            let checksumResult = Result<String, Error> {
                if let error { throw error }
                try Self.validate(response: response, maximumBytes: 8 * 1024)
                guard let temporaryURL else { throw AppUpdateError.emptyResponse }
                let data = try Self.boundedData(
                    at: temporaryURL, maximumBytes: 8 * 1024)
                guard let checksum = Self.expectedChecksum(
                    from: data, assetName: assetName) else {
                    throw AppUpdateError.invalidChecksum
                }
                return checksum
            }
            DispatchQueue.main.async {
                guard let self, self.activeDownloadID == downloadID else { return }
                switch checksumResult {
                case .success(let checksum):
                    self.downloadArchive(
                        release: release,
                        url: assetURL,
                        name: assetName,
                        expectedChecksum: checksum,
                        downloadID: downloadID)
                case .failure(let error):
                    self.failDownload(error, release: release, downloadID: downloadID)
                }
            }
        }
        checksumTask = task
        task.resume()
    }

    private func downloadArchive(
        release: AppReleaseUpdate,
        url: URL,
        name: String,
        expectedChecksum: String,
        downloadID: UUID
    ) {
        let destination = Self.downloadURL(version: release.version, assetName: name)
        if FileManager.default.fileExists(atPath: destination.path),
           (try? Self.sha256(of: destination)) == expectedChecksum {
            activeDownloadID = nil
            setDownloadState(.ready(destination), release: release)
            return
        }

        let request = Self.downloadRequest(url: url, version: release.version)
        let task = URLSession.shared.downloadTask(with: request) {
            [weak self] temporaryURL, response, error in
            let result = Result<URL, Error> {
                if let error { throw error }
                try Self.validate(
                    response: response, maximumBytes: Self.maximumArchiveBytes)
                guard let temporaryURL else { throw AppUpdateError.emptyResponse }
                let values = try temporaryURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let size = values.fileSize,
                      size > 0, size <= Self.maximumArchiveBytes else {
                    throw AppUpdateError.archiveTooLarge
                }
                let actual = try Self.sha256(of: temporaryURL)
                guard actual == expectedChecksum else {
                    throw AppUpdateError.checksumMismatch
                }
                let directory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return destination
            }
            DispatchQueue.main.async {
                guard let self, self.activeDownloadID == downloadID else { return }
                switch result {
                case .success(let destination):
                    self.activeDownloadID = nil
                    self.setDownloadState(.ready(destination), release: release)
                case .failure(let error):
                    self.failDownload(error, release: release, downloadID: downloadID)
                }
            }
        }
        archiveTask = task
        task.resume()
    }

    private func failDownload(
        _ error: Error,
        release: AppReleaseUpdate,
        downloadID: UUID
    ) {
        guard activeDownloadID == downloadID else { return }
        activeDownloadID = nil
        let message = String(error.localizedDescription.prefix(240))
        setDownloadState(.failed(message), release: release)
    }

    private func cancelDownload() {
        checksumTask?.cancel()
        archiveTask?.cancel()
        checksumTask = nil
        archiveTask = nil
        activeDownloadID = nil
    }

    private func setDownloadState(
        _ next: AppUpdateDownloadState,
        release: AppReleaseUpdate?
    ) {
        guard next != downloadState else { return }
        downloadState = next
        if case .ready = next, let release {
            var state = loadState()
            if state.notifiedDownloadVersion != release.version {
                state.notifiedDownloadVersion = release.version
                saveState(state)
                Notifier.post(
                    title: "\(ProductIdentity.current.displayName) \(release.version) downloaded",
                    body: "The SHA-256 checksum passed. Open Check for Updates to reveal it.")
            }
        }
        NotificationCenter.default.post(name: .cmdyAppUpdateChanged, object: self)
    }

    private func finishCheckCompletions() {
        let completions = checkCompletions
        checkCompletions.removeAll()
        completions.forEach { $0(availableUpdate) }
    }

    nonisolated private static let maximumArchiveBytes = 1024 * 1024 * 1024

    nonisolated private static func downloadRequest(url: URL, version: String) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue(
            "\(ProductIdentity.current.slug)/\(version)",
            forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated private static func validate(
        response: URLResponse?,
        maximumBytes: Int
    ) throws {
        guard let response else { throw AppUpdateError.emptyResponse }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AppUpdateError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw AppUpdateError.archiveTooLarge
        }
    }

    nonisolated private static func boundedData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0, size <= maximumBytes else {
            throw AppUpdateError.archiveTooLarge
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func downloadURL(
        version: String,
        assetName: String
    ) -> URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
            ?? ConfigFile.directory.appendingPathComponent("cache", isDirectory: true)
        return base
            .appendingPathComponent(ProductIdentity.current.slug, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(assetName)
    }

    private enum AppUpdateError: LocalizedError {
        case archiveTooLarge
        case checksumMismatch
        case emptyResponse
        case httpStatus(Int)
        case invalidChecksum

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge: return "The update archive exceeds the 1 GB safety limit."
            case .checksumMismatch: return "The downloaded update did not match its SHA-256 checksum."
            case .emptyResponse: return "GitHub returned an empty update response."
            case .httpStatus(let status): return "GitHub returned HTTP \(status)."
            case .invalidChecksum: return "The release checksum is missing or invalid."
            }
        }
    }

    private func loadState() -> PersistedState {
        guard let data = try? BoundedFileReader.data(at: stateURL, maxBytes: 64 * 1024) else {
            return PersistedState()
        }
        return (try? JSONDecoder().decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    private func saveState(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}
