import AppKit
import CryptoKit
import Darwin
import ProductIdentity

/// The marketplace engine — fetch the registry, install its entries.
/// See MARKETPLACE.md for the design. UI-agnostic and synchronous: the CLI
/// verbs call it directly, the panel calls it off-main and hops back.
///
/// Registry = one JSON (default: the public cmdy-registry repo; override
/// with `marketplace-registry` in the config — an https URL, a file:// URL,
/// or a local path, which makes gates and offline dev trivial). Content
/// entries (`file`) resolve RELATIVE to the registry URL. Extension zips verify
/// against pinned sha256, unpack fresh-inode, re-sign ad-hoc, and only lose
/// their quarantine bit when the caller passed explicit consent.
public enum Marketplace {

    public enum NativePayloadFormat: String, Sendable {
        case zip
    }

    public struct NativePayload: Sendable {
        public let url: String
        public let sha256: String
        public let format: NativePayloadFormat

        init?(_ json: [String: Any]) {
            guard let url = json["url"] as? String,
                  let sha256 = json["sha256"] as? String else { return nil }
            let rawFormat = json["format"] as? String ?? NativePayloadFormat.zip.rawValue
            guard let format = NativePayloadFormat(rawValue: rawFormat) else { return nil }
            self.url = url
            self.sha256 = sha256
            self.format = format
        }
    }

    public enum ChannelSetupFieldKind: String, Sendable {
        case text
        case secret
        case boolean
        case integer
        case stringList = "string-list"
        case integerList = "integer-list"
        case path
        case json
    }

    public struct ChannelSetupField: Sendable {
        public let key: String
        public let label: String
        public let kind: ChannelSetupFieldKind
        public let required: Bool
        public let defaultValue: String?
        public let placeholder: String
        public let help: String
        public let keychainService: String?

        public init?(key: String, label: String, kind: ChannelSetupFieldKind,
                     required: Bool, defaultValue: String? = nil,
                     placeholder: String = "", help: String = "",
                     keychainService: String? = nil) {
            guard !key.isEmpty, !label.isEmpty, key.utf8.count <= 64,
                  label.utf8.count <= 128 else { return nil }
            self.key = key
            self.label = label
            self.kind = kind
            self.required = required
            self.defaultValue = defaultValue.map { String($0.prefix(4_096)) }
            self.placeholder = String(placeholder.prefix(512))
            self.help = String(help.prefix(512))
            self.keychainService = keychainService.map { String($0.prefix(128)) }
        }

        fileprivate init?(_ json: [String: Any]) {
            guard let key = json["key"] as? String, !key.isEmpty,
                  let label = json["label"] as? String, !label.isEmpty,
                  let rawKind = json["type"] as? String,
                  let kind = ChannelSetupFieldKind(rawValue: rawKind),
                  let required = json["required"] as? Bool else { return nil }
            let defaultValue: String?
            switch json["default"] {
            case let value as String: defaultValue = value
            case let value as Bool: defaultValue = value ? "true" : "false"
            case let value as NSNumber: defaultValue = value.stringValue
            default: defaultValue = nil
            }
            self.init(
                key: key, label: label, kind: kind, required: required,
                defaultValue: defaultValue,
                placeholder: json["placeholder"] as? String ?? "",
                help: json["help"] as? String ?? "",
                keychainService: json["keychainService"] as? String)
        }
    }

    private final class FetchState: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Data, Error>?

        func complete(_ value: Result<Data, Error>) {
            lock.lock()
            if result == nil { result = value }
            lock.unlock()
        }

        func take() -> Result<Data, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    struct DownloadProgress: Equatable, Sendable {
        let receivedBytes: Int64
        let expectedBytes: Int64?

        var percentComplete: Int? {
            guard let expectedBytes, expectedBytes > 0 else { return nil }
            let boundedReceived = min(max(receivedBytes, 0), expectedBytes)
            return Int(
                (Double(boundedReceived) / Double(expectedBytes) * 100).rounded(.down))
        }
    }

    public struct Entry: Sendable {
        public let kind: String        // shader | theme | rig | patch | plugin | channel
        public let id: String
        public let name: String
        public let description: String
        public let author: String
        public let license: String
        public let version: String
        public let homepage: String?   // public source/project page
        public let file: String?       // content path relative to the registry
        public let url: String?        // absolute plugin asset URL
        public let sha256: String?
        public let note: String?
        public let channelMode: String?
        public let setup: String?
        public let guide: CmdyProductGuide
        public let channelConfigurationVersion: Int?
        public let channelSetupFields: [ChannelSetupField]
        public let payload: NativePayload?
        /// Distinguishes an absent payload from a declared but malformed one;
        /// the latter must fail closed before any native archive is fetched.
        let payloadWasDeclared: Bool
        /// The registry that supplied this entry. Relative content and archive
        /// paths must keep resolving against it when a renamed product fell
        /// back to a still-published legacy registry.
        let sourceRegistryURL: URL?

        init?(_ json: [String: Any], sourceRegistryURL: URL? = nil) {
            guard let kind = json["kind"] as? String,
                  let id = json["id"] as? String,
                  let name = json["name"] as? String else { return nil }
            self.kind = kind
            self.id = id
            self.name = name
            self.sourceRegistryURL = sourceRegistryURL
            self.description = json["description"] as? String ?? ""
            self.author = json["author"] as? String ?? "?"
            self.license = json["license"] as? String ?? "?"
            self.version = json["version"] as? String ?? "0"
            self.homepage = json["homepage"] as? String
                ?? json["repository"] as? String
                ?? json["repo"] as? String
            self.file = json["file"] as? String
            self.url = json["url"] as? String
            self.sha256 = json["sha256"] as? String
            self.note = json["note"] as? String
            self.channelMode = json["mode"] as? String
            self.setup = json["setup"] as? String
            self.guide = CmdyProductGuide.decode(json["guide"])
                ?? CmdyProductGuide.marketplace(
                    kind: kind, id: id, name: name,
                    description: self.description,
                    channelMode: self.channelMode, setup: self.setup)
            if let configuration = json["configuration"] as? [String: Any],
               configuration["version"] as? Int == 1,
               let fields = configuration["fields"] as? [[String: Any]] {
                self.channelConfigurationVersion = 1
                self.channelSetupFields = fields.prefix(32).compactMap(ChannelSetupField.init)
            } else {
                self.channelConfigurationVersion = nil
                self.channelSetupFields = []
            }
            self.payloadWasDeclared = json["payload"] != nil
            if let p = json["payload"] as? [String: Any] {
                self.payload = NativePayload(p)
            } else {
                self.payload = nil
            }
        }

        /// "cmdy/drift" → "cmdy-drift" (safe install filename stem).
        public var stem: String { Marketplace.safePathComponent(id) }
        /// "dev.cmdy.detox" → "detox" (plugin folder name).
        public var folderName: String {
            Marketplace.safePathComponent(id.components(separatedBy: ".").last ?? id)
        }
    }

    /// A validated, shareable `.cmdyext` archive waiting for the user's
    /// install confirmation. Keeping the inspected bytes with the metadata
    /// means an HTTPS package is downloaded exactly once and cannot change
    /// between the confirmation sheet and installation.
    public struct ExtensionPackage: Sendable {
        public let sourceURL: URL
        public let manifest: ExtensionManifest
        public let sha256: String
        public let archiveByteCount: Int
        fileprivate let archiveData: Data
        fileprivate let entry: Entry

        public var folderName: String { entry.folderName }
    }

    /// Native install links used by the public Marketplace and independent
    /// Extension authors. Marketplace ids retain pinned registry hashes;
    /// direct package links are restricted to HTTPS and still show the same
    /// manifest/capability confirmation as a double-clicked `.cmdyext` file.
    public enum ExtensionInstallRequest: Equatable, Sendable {
        case marketplace(id: String)
        case package(URL)
    }

    public static func extensionInstallRequest(
        from url: URL
    ) -> ExtensionInstallRequest? {
        guard url.scheme?.caseInsensitiveCompare(
                ProductIdentity.current.slug) == .orderedSame,
              url.host?.caseInsensitiveCompare("extension") == .orderedSame,
              url.path == "/install",
              let components = URLComponents(
                url: url, resolvingAgainstBaseURL: false) else { return nil }
        let ids = components.queryItems?
            .filter { $0.name == "id" }.compactMap(\.value) ?? []
        let urls = components.queryItems?
            .filter { $0.name == "url" }.compactMap(\.value) ?? []
        if ids.count == 1, urls.isEmpty,
           isSafeExtensionID(ids[0]) {
            return .marketplace(id: ids[0])
        }
        if urls.count == 1, ids.isEmpty,
           let packageURL = URL(string: urls[0]),
           packageURL.scheme?.lowercased() == "https",
           packageURL.host != nil,
           packageURL.pathExtension.lowercased() == "cmdyext" {
            return .package(packageURL)
        }
        return nil
    }

    private static func isSafeExtensionID(_ id: String) -> Bool {
        guard id.utf8.count <= 255 else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isASCII,
                  first.isLetter || first.isNumber else { return false }
            return part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
    }

    public enum MarketplaceError: LocalizedError {
        case network(String)
        case badRegistry(String)
        case hashMismatch(expected: String, got: String)
        case badArchive(String)
        case placeholder(String)
        case needsConsent
        public var errorDescription: String? {
            switch self {
            case .network(let m): return "network: \(m)"
            case .badRegistry(let m): return "registry: \(m)"
            case .hashMismatch(let e, let g): return "sha256 mismatch — expected \(e.prefix(12))…, got \(g.prefix(12))… (refusing to install)"
            case .badArchive(let m): return "archive: \(m)"
            case .placeholder(let m): return m
            case .needsConsent: return "Extension install needs explicit consent (native code)"
            }
        }
    }

    /// `channel` is an author-facing marketplace classification, not a second
    /// executable format. Both kinds use the same signed, capability-scoped
    /// Extension installation pipeline.
    public static func isExtensionKind(_ kind: String) -> Bool {
        kind == "plugin" || kind == "channel"
    }

    /// Native code is never downloaded unless its registry digest is present
    /// and syntactically a full SHA-256 value. Normalizing case here keeps the
    /// comparison exact without making registries choose a hex case.
    static func requiredSHA256(_ raw: String?, field: String) throws -> String {
        guard let raw,
              raw.utf8.count == 64,
              raw.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57)
                      || ($0 >= 65 && $0 <= 70)
                      || ($0 >= 97 && $0 <= 102)
              }) else {
            throw MarketplaceError.badRegistry(
                "\(field) must be a 64-character hexadecimal sha256")
        }
        return raw.lowercased()
    }

    // MARK: - Registry

    /// The configured registry location, normalized to a URL.
    public static func registryURL(override: String? = nil) -> URL {
        let raw = override ?? Preferences.shared.marketplaceRegistry
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
            return URL(string: raw) ?? cacheURL
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// A display-name rename may precede the public registry repository rename.
    /// Prefer the current product URL, then try registries derived from its
    /// declared legacy names. Explicit user/CLI registry overrides stay exact.
    static func registryURLs(override: String? = nil,
                             configured: String? = nil) -> [URL] {
        let configuredRegistry = configured ?? Preferences.shared.marketplaceRegistry
        let primary = registryURL(override: override ?? configuredRegistry)
        guard override == nil,
              configuredRegistry == Preferences.defaultMarketplaceRegistry else {
            return [primary]
        }
        var seen = Set<String>()
        return ([primary] + ProductIdentity.current.compatibleMarketplaceRegistryURLs)
            .filter { seen.insert($0.absoluteString).inserted }
    }

    static var cacheURL: URL {
        ConfigFile.directory.appendingPathComponent("marketplace-cache.json")
    }

    static var cacheSourceURL: URL {
        ConfigFile.directory.appendingPathComponent("marketplace-cache-source.txt")
    }

    /// Fetch + parse the registry; falls back to the last good cache when the
    /// network is down so browsing keeps working offline.
    public static func fetchEntries(registry: String? = nil) throws -> [Entry] {
        let candidates = registryURLs(override: registry)
        var failures: [String] = []
        for url in candidates {
            do {
                let data = try fetchData(url, maxBytes: 16 * 1024 * 1024)
                let entries = try decodeEntries(data, sourceRegistryURL: url)
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: cacheURL)
                try? url.absoluteString.write(
                    to: cacheSourceURL, atomically: true, encoding: .utf8)
                return entries
            } catch {
                failures.append("\(url.host ?? url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let cached = try? readFile(cacheURL, maxBytes: 16 * 1024 * 1024) {
            let cachedSource = (try? String(contentsOf: cacheSourceURL, encoding: .utf8))
                .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                ?? candidates.first
            return try decodeEntries(cached, sourceRegistryURL: cachedSource)
        }

        throw MarketplaceError.network(
            "\(failures.joined(separator: "; ")) (no cache yet)")
    }

    private static func decodeEntries(_ data: Data,
                                      sourceRegistryURL: URL?) throws -> [Entry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["entries"] as? [[String: Any]] else {
            throw MarketplaceError.badRegistry("registry.json did not parse")
        }
        return raw.prefix(50_000).compactMap {
            Entry($0, sourceRegistryURL: sourceRegistryURL)
        }
    }

    /// Resolve an entry's `file` against the registry base and fetch it.
    public static func fetchContent(_ entry: Entry, registry: String? = nil) throws -> Data {
        let maxBytes = isExtensionKind(entry.kind)
            ? 1024 * 1024 * 1024
            : 16 * 1024 * 1024
        guard let rel = entry.file else {
            guard let abs = entry.url, let url = URL(string: abs) else {
                throw MarketplaceError.badRegistry("\(entry.id) has no file/url")
            }
            return try fetchData(url, maxBytes: maxBytes)
        }
        let base = (registry.map { registryURL(override: $0) }
            ?? entry.sourceRegistryURL
            ?? registryURL()).deletingLastPathComponent()
        return try fetchData(base.appendingPathComponent(rel), maxBytes: maxBytes)
    }

    private static func readFile(_ url: URL, maxBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0, size <= maxBytes else {
            throw MarketplaceError.network(
                "\(url.lastPathComponent) exceeds the \(maxBytes / (1024 * 1024)) MB limit")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Download to URLSession's temporary file first, then enforce the size
    /// limit before materializing Data. This prevents a large registry or
    /// archive response from growing the app's heap without bound.
    static func fetchData(
        _ url: URL,
        maxBytes: Int = 16 * 1024 * 1024,
        timeout: TimeInterval = 60,
        session: URLSession = .shared,
        downloadProgress: (DownloadProgress) -> Void = { _ in }
    ) throws -> Data {
        let boundedMax = min(max(maxBytes, 1), 1024 * 1024 * 1024)
        if url.isFileURL {
            do { return try readFile(url, maxBytes: boundedMax) }
            catch { throw MarketplaceError.network("cannot read \(url.path)") }
        }
        let state = FetchState()
        let sem = DispatchSemaphore(value: 0)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.setValue(
            "\(ProductIdentity.current.slug)/marketplace",
            forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request) { temporaryURL, resp, err in
            if let err { state.complete(.failure(err)) }
            else if url.scheme?.lowercased() == "https",
                    resp?.url?.scheme?.lowercased() != "https" {
                state.complete(.failure(MarketplaceError.network(
                    "refusing an insecure download redirect")))
            }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                state.complete(.failure(MarketplaceError.network(
                    "HTTP \(http.statusCode) for \(url.lastPathComponent)")))
            } else if let expected = resp?.expectedContentLength,
                      expected > Int64(boundedMax) {
                state.complete(.failure(MarketplaceError.network(
                    "\(url.lastPathComponent) exceeds the \(boundedMax / (1024 * 1024)) MB limit")))
            } else if let temporaryURL {
                do {
                    state.complete(.success(
                        try readFile(temporaryURL, maxBytes: boundedMax)))
                } catch {
                    state.complete(.failure(error))
                }
            } else {
                state.complete(.failure(MarketplaceError.network(
                    "empty response for \(url.lastPathComponent)")))
            }
            sem.signal()
        }
        task.resume()

        let deadline = DispatchTime.now() + timeout
        var lastReportedBytes: Int64 = -1
        var lastReportedPercent: Int?
        func reportProgress(force: Bool = false) {
            let received = max(0, task.countOfBytesReceived)
            let expectedRaw = task.countOfBytesExpectedToReceive
            // Keep the caller's useful "downloading…" stage text until the
            // server has supplied a size or the first bytes actually arrive.
            // URLSession reports both values as unknown/zero while connecting.
            guard received > 0 || expectedRaw > 0 else { return }
            let snapshot = DownloadProgress(
                receivedBytes: received,
                expectedBytes: expectedRaw > 0 ? expectedRaw : nil)
            let percent = snapshot.percentComplete
            let changedEnough = percent.map { $0 != lastReportedPercent }
                ?? (received - lastReportedBytes >= 1_048_576)
            guard force || lastReportedBytes < 0 || changedEnough else { return }
            lastReportedBytes = received
            lastReportedPercent = percent
            downloadProgress(snapshot)
        }
        reportProgress()
        while sem.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            reportProgress()
            guard DispatchTime.now() < deadline else {
                task.cancel()
                throw MarketplaceError.network(
                    "timeout fetching \(url.lastPathComponent)")
            }
        }
        reportProgress(force: true)
        guard let result = state.take() else {
            throw MarketplaceError.network("request completed without a result")
        }
        switch result {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }

    // MARK: - Content installs

    /// Write a marketplace shader into the user-shader gallery.
    /// Returns the gallery name ("user/<stem>") ready for `shader = …`.
    @discardableResult
    public static func installShader(_ entry: Entry, source: String) throws -> String {
        try FileManager.default.createDirectory(at: UserShaders.directory,
                                                withIntermediateDirectories: true)
        let url = UserShaders.directory.appendingPathComponent(entry.stem + ".metal")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return "user/" + entry.stem
    }

    /// Write a marketplace theme into the user-theme gallery and reload.
    /// Returns the theme's display name ready for `theme = …`.
    @discardableResult
    public static func installTheme(_ entry: Entry, json data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else {
            throw MarketplaceError.badRegistry("\(entry.id): theme JSON did not parse")
        }
        let dir = ConfigFile.directory.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(entry.stem + ".json"))
        Theme.reloadUserThemes()
        return name
    }

    /// Parse a rig into config key/values (comments and blanks skipped).
    public static func parseRig(_ source: String) -> [String: String] {
        var kv: [String: String] = [:]
        for line in source.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let key = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            kv[key] = value
        }
        return kv
    }

    /// Apply a rig — the whole look in one move. Settings persist through the
    /// usual two-way config sync.
    public static func applyRig(_ source: String) {
        ConfigFile.applyValues(parseRig(source))
    }

    // MARK: - Extension install

    /// Download/read and fully inspect a package before showing install
    /// consent. A `.cmdyext` file is an ordinary ZIP containing exactly one
    /// v1 Extension folder; the distinct suffix lets Finder hand it to cmdy.
    public static func prepareExtensionPackage(
        from sourceURL: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> ExtensionPackage {
        let scheme = sourceURL.scheme?.lowercased()
        guard sourceURL.isFileURL || scheme == "https" else {
            throw MarketplaceError.network(
                "Extension packages must be local files or HTTPS URLs")
        }
        guard sourceURL.pathExtension.lowercased() == "cmdyext" else {
            throw MarketplaceError.badArchive(
                "shareable Extension packages must use the .cmdyext filename extension")
        }
        progress(sourceURL.isFileURL
            ? "reading \(sourceURL.lastPathComponent)…"
            : "downloading \(sourceURL.lastPathComponent)…")
        let archive = try fetchData(sourceURL, maxBytes: 1024 * 1024 * 1024)
        guard archive.count <= 1024 * 1024 * 1024 else {
            throw MarketplaceError.badArchive("Extension package exceeds 1 GB")
        }
        let digest = SHA256.hash(data: archive)
            .map { String(format: "%02x", $0) }.joined()

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ProductIdentity.current.slug)-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpacked = try extractExtensionArchive(archive, into: staging)
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.load(from: unpacked)
        } catch {
            throw MarketplaceError.badArchive(error.localizedDescription)
        }
        guard !manifest.isLegacy else {
            throw MarketplaceError.badArchive(
                "shareable packages require a v1 manifest with explicit capabilities")
        }
        try validateEntrypoint(manifest, inside: unpacked)

        var json: [String: Any] = [
            "kind": manifest.allows(.channels) ? "channel" : "plugin",
            "id": manifest.id,
            "name": manifest.name,
            "description": manifest.description ?? "Shared cmdy Extension",
            "author": "Shared package",
            "version": manifest.version,
            "url": sourceURL.absoluteString,
            "sha256": digest,
        ]
        if let homepage = manifest.homepage { json["homepage"] = homepage }
        if let guide = manifest.guide { json["guide"] = guide.jsonObject }
        guard let entry = Entry(json) else {
            throw MarketplaceError.badArchive("could not describe the Extension package")
        }
        progress("verified \(manifest.name) \(manifest.version) ✓")
        return ExtensionPackage(
            sourceURL: sourceURL,
            manifest: manifest,
            sha256: digest,
            archiveByteCount: archive.count,
            archiveData: archive,
            entry: entry)
    }

    /// Install bytes that were already inspected for an install sheet or CLI
    /// summary. The common Marketplace pipeline still re-validates every path,
    /// manifest field, signature boundary, and digest before swapping files.
    @discardableResult
    public static func installExtensionPackage(
        _ package: ExtensionPackage,
        consented: Bool,
        progress: (String) -> Void = { _ in }
    ) throws -> URL {
        try installPlugin(
            package.entry,
            archive: package.archiveData,
            registry: nil,
            consented: consented,
            progress: progress)
    }

    /// The pipeline: require pinned sha256 → download → verify → unpack →
    /// fresh inode → ad-hoc sign → (consented) de-quarantine → enable.
    /// Returns the installed directory.
    /// Process lifecycle is the CALLER's job (panel/route stop the running
    /// instance on main before calling, launch after) — the engine stays
    /// thread- and runloop-agnostic so the CLI can use it too.
    @discardableResult
    public static func installPlugin(_ entry: Entry, registry: String? = nil,
                                     consented: Bool,
                                     progress: (String) -> Void) throws -> URL {
        try installPlugin(
            entry,
            archive: nil,
            registry: registry,
            consented: consented,
            progress: progress)
    }

    @discardableResult
    private static func installPlugin(_ entry: Entry, archive: Data?,
                                      registry: String?, consented: Bool,
                                      progress: (String) -> Void) throws -> URL {
        guard isExtensionKind(entry.kind) else {
            throw MarketplaceError.badRegistry(
                "\(entry.id) is not an Extension or Channel connector")
        }
        guard consented else { throw MarketplaceError.needsConsent }
        if let url = entry.url, url.contains("PLACEHOLDER") {
            throw MarketplaceError.placeholder(entry.note ?? "\(entry.name): release pending")
        }

        // Validate every native-code digest before starting network or file
        // I/O. A missing payload tuple may mean the registry declared a
        // malformed payload object, which is also a hard failure.
        let expectedArchiveSHA = try requiredSHA256(
            entry.sha256, field: "\(entry.id) archive sha256")
        let expectedPayloadSHA: String?
        if entry.payloadWasDeclared {
            guard let payload = entry.payload else {
                throw MarketplaceError.badRegistry(
                    "\(entry.id) payload requires url and sha256, plus a supported format")
            }
            expectedPayloadSHA = try requiredSHA256(
                payload.sha256, field: "\(entry.id) payload sha256")
        } else {
            expectedPayloadSHA = nil
        }

        if archive == nil {
            progress("downloading \(entry.name) \(entry.version)…")
        } else {
            progress("verifying \(entry.name) \(entry.version)…")
        }
        let zip = try archive ?? fetchContent(entry, registry: registry)
        guard zip.count <= 1024 * 1024 * 1024 else {
            throw MarketplaceError.badArchive("Extension archive exceeds 1 GB")
        }

        let got = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard got == expectedArchiveSHA else {
            throw MarketplaceError.hashMismatch(expected: expectedArchiveSHA, got: got)
        }
        progress("sha256 verified ✓")

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ProductIdentity.current.slug)-mp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpacked = try extractExtensionArchive(
            zip, into: staging, allowDanglingSymlinks: entry.payload != nil)
        let manifestURL = unpacked.appendingPathComponent("manifest.json")
        guard let manifestSize = try? manifestURL.resourceValues(
            forKeys: [.fileSizeKey]).fileSize,
              manifestSize <= 1024 * 1024 else {
            throw MarketplaceError.badArchive("manifest.json exceeds 1 MB")
        }
        guard var manifest = (try? JSONSerialization.jsonObject(
                with: readFile(manifestURL, maxBytes: 1024 * 1024))) as? [String: Any] else {
            throw MarketplaceError.badArchive("manifest.json is not a JSON object")
        }
        let parsedManifest: ExtensionManifest
        do {
            parsedManifest = try ExtensionManifest.load(from: unpacked)
        } catch {
            throw MarketplaceError.badArchive(error.localizedDescription)
        }
        if entry.kind == "channel" {
            guard !parsedManifest.isLegacy else {
                throw MarketplaceError.badArchive(
                    "a Channel marketplace entry requires a v1 Extension manifest")
            }
            guard parsedManifest.effectiveCapabilities.contains(.channels) else {
                throw MarketplaceError.badArchive(
                    "a Channel marketplace entry must request the channels capability")
            }
        }
        if !parsedManifest.isLegacy {
            guard parsedManifest.id == entry.id else {
                throw MarketplaceError.badArchive(
                    "manifest id \(parsedManifest.id) does not match registry id \(entry.id)")
            }
            guard parsedManifest.version == entry.version else {
                throw MarketplaceError.badArchive(
                    "manifest version \(parsedManifest.version) does not match registry version \(entry.version)")
            }
        }
        let execURL = try validateEntrypoint(parsedManifest, inside: unpacked)

        // Browser's small .cmdyext is still a normal activation package, but a
        // lean cmdy installation also needs the real CEF-bearing app variant.
        // Fully download and validate that signed app before touching the live
        // activation. The restart helper is scheduled only after the activation
        // swap below has succeeded, so either both halves commit or both roll
        // back.
        let installsBrowser = BrowserEdition.authorizesHostComponent(
            BrowserEdition.hostComponentIdentifier,
            manifest: parsedManifest)
        let preparedBrowserSwitch = installsBrowser
            ? try BrowserComponentInstaller.prepareSwitch(
                to: .browser,
                requiredBrowserVersion: parsedManifest.version,
                progress: progress)
            : nil
        var browserSwitchLeaseResolved = false
        defer {
            if let preparedBrowserSwitch, !browserSwitchLeaseResolved {
                BrowserComponentInstaller.discard(preparedBrowserSwitch)
            }
        }

        // Payload (chromium's CEF): fetched separately, assembled next to the binary.
        if let payload = entry.payload {
            if payload.url.contains("PLACEHOLDER") {
                throw MarketplaceError.placeholder(entry.note ?? "\(entry.name): payload release pending")
            }
            progress("downloading payload…")
            guard let payloadURL = URL(string: payload.url) else {
                throw MarketplaceError.badRegistry("\(entry.id) payload url is not a valid URL")
            }
            let data = try fetchData(payloadURL, maxBytes: 1024 * 1024 * 1024)
            guard data.count <= 1024 * 1024 * 1024 else {
                throw MarketplaceError.badArchive("Extension payload exceeds 1 GB")
            }
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let expectedPayloadSHA, got == expectedPayloadSHA else {
                throw MarketplaceError.hashMismatch(
                    expected: expectedPayloadSHA ?? "invalid", got: got)
            }
            let pzip = staging.appendingPathComponent("payload.zip")
            try data.write(to: pzip)
            try validateArchivePaths(pzip)
            try run("/usr/bin/ditto", "-x", "-k", pzip.path,
                    unpacked.appendingPathComponent("Frameworks").path)
            try validateExtractedTree(unpacked, inside: staging)
            progress("payload assembled ✓")
        }

        // Finish and sign the staged tree before touching the live install.
        // Updates retain local operator state without ever placing it in the
        // downloaded archive or registry. In particular, Channel guided setup
        // lives in config.json and must survive a package replacement.
        let dest = installedExtensionDirectory(id: entry.id)
            ?? PluginManager.pluginsDirectory.appendingPathComponent(entry.folderName)
        manifest["enabled"] = true
        if FileManager.default.fileExists(atPath: dest.path) {
            try preserveLocalExtensionState(
                from: dest, into: unpacked, manifest: &manifest)
        }
        manifest["id"] = entry.id
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                      options: [.sortedKeys])
        try manifestData.write(to: unpacked.appendingPathComponent("manifest.json"))
        // Receipt: lets the marketplace show installed/update states.
        let receipt: [String: Any] = ["id": entry.id, "version": entry.version]
        try? JSONSerialization.data(withJSONObject: receipt)
            .write(to: unpacked.appendingPathComponent(".marketplace.json"))
        // A packaged helper app may already carry a Developer ID signature
        // and notarization ticket. Re-signing only its inner executable would
        // break the outer bundle seal (this is what made a distributable
        // Browser Extension impossible). Preserve a valid nested app as one
        // signed unit; author-built unsigned helper apps are sealed ad-hoc as
        // a whole bundle after the same explicit native-code consent.
        if let appBundle = enclosingAppBundle(for: execURL, inside: unpacked) {
            if hasValidCodeSignature(appBundle) {
                progress("signed helper verified ✓")
            } else {
                try run("/usr/bin/codesign", "--force", "--deep", "--sign", "-",
                        appBundle.path)
                progress("helper sealed locally ✓")
            }
        } else {
            try run("/usr/bin/codesign", "--force", "--sign", "-", execURL.path)
        }
        _ = try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", unpacked.path)

        // Fresh inode: overwriting a signed binary in place poisons the
        // kernel's code-sign cache (relaunch = SIGKILL). Keep the previous
        // directory until the staged replacement is completely ready, then
        // swap with rollback if the final move fails.
        let backup = PluginManager.pluginsDirectory
            .appendingPathComponent(".\(entry.folderName)-backup-\(UUID().uuidString)")
        progress("installing to \(dest.path)…")
        try FileManager.default.createDirectory(at: PluginManager.pluginsDirectory,
                                                withIntermediateDirectories: true)
        let hadPrevious = FileManager.default.fileExists(atPath: dest.path)
        let activationChange = try preparedBrowserSwitch.map {
            try BrowserComponentInstaller.beginInstalledActivation(
                $0,
                destination: dest,
                previousBackup: hadPrevious ? backup : nil)
        }
        do {
            if hadPrevious {
                try FileManager.default.moveItem(at: dest, to: backup)
            }
            try FileManager.default.moveItem(at: unpacked, to: dest)
            if let preparedBrowserSwitch,
               let activationChange,
               preparedBrowserSwitch.requiresRelaunch {
                try BrowserComponentInstaller.scheduleInstalledActivation(
                    preparedBrowserSwitch,
                    activation: activationChange)
                browserSwitchLeaseResolved = true
            } else {
                if let preparedBrowserSwitch, let activationChange {
                    try BrowserComponentInstaller.completeWithoutRelaunch(
                        preparedBrowserSwitch,
                        activation: activationChange)
                    browserSwitchLeaseResolved = true
                } else if hadPrevious {
                    try? FileManager.default.removeItem(at: backup)
                }
            }
        } catch {
            if let activationChange {
                if let preparedBrowserSwitch,
                   BrowserComponentInstaller.leaseRequiresRecovery(
                    preparedBrowserSwitch) {
                    // The still-live helper is the sole rollback owner. Keep
                    // its lease and activation backup intact.
                    browserSwitchLeaseResolved = true
                    throw error
                }
                do {
                    try BrowserComponentInstaller.rollbackPreparedActivation(
                        activationChange)
                } catch let rollbackError {
                    // Do not release the app-scoped lease when restoration did
                    // not verify. Its durable activation intent is the recovery
                    // record that prevents a conflicting Browser operation.
                    browserSwitchLeaseResolved = true
                    throw BrowserComponentSwitchError.helperLaunchFailed(
                        "installation failed (\(error.localizedDescription)); activation recovery also failed: \(rollbackError.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: dest)
                if hadPrevious {
                    try? FileManager.default.moveItem(at: backup, to: dest)
                }
            }
            throw error
        }

        return dest
    }

    private static func extractExtensionArchive(
        _ archive: Data,
        into staging: URL,
        allowDanglingSymlinks: Bool = false
    ) throws -> URL {
        let zipURL = staging.appendingPathComponent("extension.cmdyext")
        try archive.write(to: zipURL)
        try validateArchivePaths(zipURL)
        try run("/usr/bin/ditto", "-x", "-k", zipURL.path, staging.path)

        // A package contains exactly one top-level Extension directory.
        let candidates = try FileManager.default
            .contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("manifest.json").path) }
        guard candidates.count == 1, let unpacked = candidates.first else {
            throw MarketplaceError.badArchive(
                candidates.isEmpty
                    ? "no manifest.json in the package"
                    : "package contains more than one Extension root")
        }
        try validateExtractedTree(
            unpacked,
            inside: staging,
            allowDanglingSymlinks: allowDanglingSymlinks)
        return unpacked
    }

    @discardableResult
    private static func validateEntrypoint(
        _ manifest: ExtensionManifest,
        inside root: URL
    ) throws -> URL {
        let executable = root.appendingPathComponent(manifest.entrypoint)
            .standardizedFileURL
        guard let rootPath = canonicalExistingPath(root),
              let executablePath = canonicalExistingPath(executable),
              isPath(executablePath, inside: rootPath),
              FileManager.default.fileExists(atPath: executable.path),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MarketplaceError.badArchive(
                "Extension entrypoint is missing, not executable, or leaves its package")
        }
        return executable
    }

    /// Return the nearest `.app` that owns an Extension entrypoint, bounded
    /// by the extracted Extension root. An arbitrary `.app` string elsewhere
    /// in the path can never escape the already validated archive tree.
    static func enclosingAppBundle(for executable: URL, inside root: URL) -> URL? {
        let boundary = root.standardizedFileURL.path
        var candidate = executable.deletingLastPathComponent().standardizedFileURL
        while isPath(candidate.path, inside: boundary), candidate.path != boundary {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    static func hasValidCodeSignature(_ bundle: URL) -> Bool {
        guard let result = try? ProcessCapture.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", bundle.path],
            timeout: 120,
            outputLimit: 1_048_576) else { return false }
        return result.terminationStatus == 0 && !result.outputWasTruncated
    }

    /// Preserve only the two operator-owned pieces of Extension state during
    /// an update. Everything else continues to come from the verified archive.
    /// Refuse unsafe config paths instead of following a symlink or silently
    /// discarding a configuration that cannot be bounded.
    static func preserveLocalExtensionState(
        from existing: URL,
        into staged: URL,
        manifest: inout [String: Any]
    ) throws {
        let oldManifestURL = existing.appendingPathComponent("manifest.json")
        if let data = try? BoundedFileReader.data(
                at: oldManifestURL, maxBytes: 1024 * 1024),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let enabled = object["enabled"] as? Bool {
            manifest["enabled"] = enabled
        }

        let source = existing.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 1024 * 1024 else {
            throw MarketplaceError.badArchive(
                "installed config.json is not a safe bounded file; update stopped")
        }
        let data = try BoundedFileReader.data(at: source, maxBytes: 1024 * 1024)
        let target = staged.appendingPathComponent("config.json")
        try data.write(to: target, options: .atomic)
        guard chmod(target.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func safePathComponent(_ raw: String) -> String {
        let mapped = raw.map { character -> Character in
            if character.isASCII,
               character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." {
                return character
            }
            return "-"
        }
        let value = String(mapped)
            .replacingOccurrences(of: "..", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return value.isEmpty ? "item" : String(value.prefix(160))
    }

    /// Reject absolute and parent-traversing zip entry names before invoking
    /// the system extractor. Post-extraction validation still checks links
    /// and expanded size; this preflight prevents entries from ever naming a
    /// path outside the staging directory.
    static func validateArchivePaths(_ archive: URL) throws {
        let listing = try ProcessCapture.run(
            URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-1", archive.path],
            timeout: 60,
            outputLimit: 16 * 1024 * 1024)
        guard listing.terminationStatus == 0, !listing.outputWasTruncated else {
            throw MarketplaceError.badArchive(
                "could not inspect every archive entry")
        }
        let entries = listing.output.split(separator: "\n", omittingEmptySubsequences: true)
        guard entries.count <= 200_000 else {
            throw MarketplaceError.badArchive(
                "archive contains more than 200,000 entries")
        }
        var seenPaths = Set<String>()
        for rawEntry in entries {
            let entry = String(rawEntry).replacingOccurrences(of: "\\", with: "/")
            var pathComponents = Array(
                entry.split(separator: "/", omittingEmptySubsequences: false))
            if pathComponents.last?.isEmpty == true {
                pathComponents.removeLast()
            }
            guard !entry.hasPrefix("/"), !entry.hasPrefix("~"),
                  !pathComponents.isEmpty,
                  pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else {
                throw MarketplaceError.badArchive(
                    "archive entry escapes the staging directory")
            }
            let canonicalPath = pathComponents.joined(separator: "/")
                .precomposedStringWithCanonicalMapping.lowercased()
            guard seenPaths.insert(canonicalPath).inserted else {
                throw MarketplaceError.badArchive(
                    "archive contains a duplicate path: \(canonicalPath)")
            }
        }
    }

    /// Reject archive roots that are symlinks, escape the staging directory,
    /// expand to an unreasonable size, or contain links outside their own
    /// Extension tree. This also catches accidental malformed release zips.
    static func validateExtractedTree(
        _ root: URL,
        inside staging: URL,
        allowDanglingSymlinks: Bool = false
    ) throws {
        let fm = FileManager.default
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard let stagingPath = canonicalExistingPath(staging),
              let rootPath = canonicalExistingPath(root) else {
            throw MarketplaceError.badArchive(
                "Extension root could not be resolved inside the archive")
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              isPath(rootPath, inside: stagingPath) else {
            throw MarketplaceError.badArchive(
                "Extension root must be a real directory inside the archive")
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: []) else {
            throw MarketplaceError.badArchive("could not inspect extracted Extension")
        }
        var entries = 0
        var bytes: Int64 = 0
        for case let item as URL in enumerator {
            entries += 1
            guard entries <= 200_000 else {
                throw MarketplaceError.badArchive(
                    "Extension expands to more than 200,000 files")
            }
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                try validateSymbolicLink(
                    item,
                    inside: rootPath,
                    allowDangling: allowDanglingSymlinks)
                continue
            }
            guard let resolved = canonicalExistingPath(item),
                  isPath(resolved, inside: rootPath) else {
                throw MarketplaceError.badArchive(
                    "Extension contains an item outside its folder")
            }
            if values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
                guard bytes <= 4 * 1024 * 1024 * 1024 else {
                    throw MarketplaceError.badArchive(
                        "Extension expands beyond 4 GB")
                }
            }
        }
    }

    /// `realpath(3)` gives every comparison the same canonical spelling. On
    /// macOS, enumerating a symlink below `/var` commonly returns `/private/var`
    /// even though Foundation leaves the root URL as `/var`; comparing those
    /// raw strings made safe Browser framework links look like path escapes.
    private static func canonicalExistingPath(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, realpath(path, &buffer) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// Payload-backed Extensions may contain relative links to files that are
    /// downloaded in the next installation stage. Permit those links only
    /// while they are lexically contained by the Extension root, then require
    /// every link to resolve after the payload has been assembled.
    private static func validateSymbolicLink(
        _ item: URL,
        inside rootPath: String,
        allowDangling: Bool
    ) throws {
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: item.path)
        guard !destination.isEmpty, !destination.hasPrefix("/") else {
            throw MarketplaceError.badArchive(
                "Extension contains an absolute or invalid symlink")
        }

        let target = item.deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
        if let resolved = canonicalExistingPath(target) {
            guard isPath(resolved, inside: rootPath) else {
                throw MarketplaceError.badArchive(
                    "Extension contains a symlink outside its folder")
            }
        } else {
            // There is no path for realpath(3) to canonicalize yet. The URL is
            // built from the enumerator's already-canonical parent, so a
            // standardized lexical containment check safely covers this
            // temporary payload-assembly state.
            guard isPath(target.path, inside: rootPath) else {
                throw MarketplaceError.badArchive(
                    "Extension contains a symlink outside its folder")
            }
            guard allowDangling else {
                throw MarketplaceError.badArchive(
                    "Extension contains a dangling symlink")
            }
        }
    }

    // MARK: - Installed state

    /// Locate by manifest identity rather than folder spelling. Local source
    /// installs historically used the complete reverse-DNS id as their folder,
    /// while Marketplace installs use its final component; package updates must
    /// replace either form instead of creating a duplicate running identity.
    public static func installedExtensionDirectory(id: String) -> URL? {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: PluginManager.pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return directories.first {
            (try? ExtensionManifest.load(from: $0).id) == id
        }
    }

    public enum State {
        case notInstalled
        case installed(String)          // version (content kinds: "✓")
        case updateAvailable(String)    // installed version, registry has newer
    }

    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    public static func state(of entry: Entry) -> State {
        switch entry.kind {
        case "shader":
            let path = UserShaders.directory.appendingPathComponent(entry.stem + ".metal").path
            return FileManager.default.fileExists(atPath: path) ? .installed("✓") : .notInstalled
        case "theme":
            let path = ConfigFile.directory.appendingPathComponent("themes/\(entry.stem).json").path
            return FileManager.default.fileExists(atPath: path) ? .installed("✓") : .notInstalled
        case "plugin", "channel":
            let dir = installedExtensionDirectory(id: entry.id)
                ?? PluginManager.pluginsDirectory.appendingPathComponent(entry.folderName)
            let receipt = dir.appendingPathComponent(".marketplace.json")
            let receiptVersion: String? = {
                guard let data = try? BoundedFileReader.data(
                    at: receipt, maxBytes: 1024 * 1024),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { return nil }
                return json["version"] as? String
            }()
            let installedVersion = receiptVersion
                ?? (try? ExtensionManifest.load(from: dir).version)
            guard let installedVersion else {
                return FileManager.default.fileExists(atPath: dir.path)
                    ? .installed("local") : .notInstalled
            }
            if entry.id == BrowserEdition.marketplaceID,
               !BrowserComponentInstaller.currentBundleHasBrowserRuntime {
                // An activation record without the signed CEF-bearing app is
                // not an installed Browser. Keep the Marketplace action on
                // Download so one click repairs the complete installation.
                return .notInstalled
            }
            if isVersion(entry.version, newerThan: installedVersion) {
                return .updateAvailable(installedVersion)
            }
            return .installed(installedVersion)
        default:
            return .notInstalled
        }
    }

    // MARK: - Process helper

    @discardableResult
    static func run(_ launchPath: String, _ args: String...) throws -> String {
        let result = try ProcessCapture.run(
            URL(fileURLWithPath: launchPath),
            arguments: args,
            timeout: 600,
            outputLimit: 1_048_576)
        guard result.terminationStatus == 0 else {
            throw MarketplaceError.badArchive(
                "\((launchPath as NSString).lastPathComponent) failed: "
                + String(result.output.prefix(200)))
        }
        return result.output
    }
}
