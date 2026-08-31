import Foundation

extension Notification.Name {
    /// Posted on the main thread whenever the known marketplace update set changes.
    public static let cmdyMarketplaceUpdatesChanged = Notification.Name(
        "cmdy.marketplaceUpdatesChanged")
}

/// A small, receipt-gated update monitor. A fresh or source-only installation
/// never contacts the registry automatically; once the user installs through
/// the marketplace, checks run at most daily and each version set is announced
/// only once.
public final class MarketplaceUpdateMonitor {
    nonisolated(unsafe) public static let shared = MarketplaceUpdateMonitor()

    public private(set) var availableUpdates: [Marketplace.Entry] = []
    public var updateCount: Int { availableUpdates.count }
    public var extensionUpdateCount: Int {
        availableUpdates.filter { $0.kind == "plugin" }.count
    }
    public var channelUpdateCount: Int {
        availableUpdates.filter { $0.kind == "channel" }.count
    }

    private struct PersistedState: Codable {
        var lastCheck: TimeInterval = 0
        var notifiedSignature = ""
    }

    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    private var isChecking = false

    private init() {}

    public func checkIfDue(force: Bool = false) {
        precondition(Thread.isMainThread, "marketplace update state is main-thread owned")
        let enabled = Preferences.shared.marketplaceUpdateChecks
        let hasReceipts = Self.hasMarketplaceReceipts()
        guard enabled, hasReceipts else {
            clearKnownUpdates()
            return
        }

        let now = Date()
        var state = Self.loadState()
        let lastCheck = state.lastCheck > 0
            ? Date(timeIntervalSince1970: state.lastCheck) : nil
        guard !isChecking,
              force || Self.shouldCheck(enabled: enabled,
                                        hasReceipts: hasReceipts,
                                        lastCheck: lastCheck,
                                        now: now) else { return }

        isChecking = true
        state.lastCheck = now.timeIntervalSince1970
        Self.saveState(state)
        let attemptedState = state
        let registry = Preferences.shared.marketplaceRegistry
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Marketplace.fetchEntries(registry: registry) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                if case .success(let entries) = result {
                    self.apply(entries: entries, notify: true, state: attemptedState)
                }
            }
        }
    }

    /// Call when the registry is already visible. This updates badges and the
    /// de-duplication receipt without raising a redundant system notification.
    public func refresh(with entries: [Marketplace.Entry], notify: Bool = false) {
        precondition(Thread.isMainThread, "marketplace update state is main-thread owned")
        // A manager refreshes only its own marketplace kind. Preserve update
        // state for the other manager instead of letting Channels and
        // Extensions overwrite each other's badges.
        let refreshedKinds = Set(entries.lazy.filter {
            Marketplace.isExtensionKind($0.kind)
        }.map(\.kind))
        let merged = availableUpdates.filter { !refreshedKinds.contains($0.kind) } + entries
        apply(entries: merged, notify: notify, state: Self.loadState())
    }

    public func markInstalled(id: String) {
        precondition(Thread.isMainThread, "marketplace update state is main-thread owned")
        let previous = Self.signature(for: availableUpdates)
        availableUpdates.removeAll { $0.id == id }
        guard Self.signature(for: availableUpdates) != previous else { return }
        var state = Self.loadState()
        state.notifiedSignature = Self.signature(for: availableUpdates)
        Self.saveState(state)
        postChanged()
    }

    public func clearKnownUpdates() {
        precondition(Thread.isMainThread, "marketplace update state is main-thread owned")
        guard !availableUpdates.isEmpty else { return }
        availableUpdates.removeAll()
        postChanged()
    }

    nonisolated static func shouldCheck(enabled: Bool, hasReceipts: Bool,
                                        lastCheck: Date?, now: Date) -> Bool {
        guard enabled, hasReceipts else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    nonisolated static func signature(for entries: [Marketplace.Entry]) -> String {
        entries.map { "\($0.id)=\($0.version)" }.sorted().joined(separator: "|")
    }

    nonisolated static func notificationBody(for entries: [Marketplace.Entry]) -> String {
        if let only = entries.first, entries.count == 1 {
            let destination = only.kind == "channel" ? "Channels" : "Extensions"
            return "\(only.name) \(only.version) is ready. Open \(destination) to update."
        }
        let names = entries.prefix(3).map(\.name).joined(separator: ", ")
        let remainder = entries.count > 3 ? " + \(entries.count - 3) more" : ""
        let label: String
        if entries.allSatisfy({ $0.kind == "channel" }) { label = "Channel connectors" }
        else if entries.allSatisfy({ $0.kind == "plugin" }) { label = "Extensions" }
        else { label = "Marketplace updates" }
        return "\(entries.count) \(label) are ready: \(names)\(remainder)."
    }

    private func apply(entries: [Marketplace.Entry], notify: Bool,
                       state initialState: PersistedState) {
        precondition(Thread.isMainThread, "marketplace update state is main-thread owned")
        let updates = entries.filter { entry in
            guard Marketplace.isExtensionKind(entry.kind) else { return false }
            if case .updateAvailable = Marketplace.state(of: entry) { return true }
            return false
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let previous = Self.signature(for: availableUpdates)
        let signature = Self.signature(for: updates)
        availableUpdates = updates

        var state = initialState
        if notify, !updates.isEmpty, state.notifiedSignature != signature {
            Notifier.post(title: "Marketplace updates available",
                          body: Self.notificationBody(for: updates))
        }
        state.notifiedSignature = signature
        Self.saveState(state)
        if signature != previous { postChanged() }
    }

    private func postChanged() {
        NotificationCenter.default.post(
            name: .cmdyMarketplaceUpdatesChanged, object: self)
    }

    nonisolated private static var stateURL: URL {
        ConfigFile.directory.appendingPathComponent("marketplace-update-state.json")
    }

    nonisolated private static func hasMarketplaceReceipts() -> Bool {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(
            at: PluginManager.pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return false }
        return directories.contains {
            fm.fileExists(atPath: $0.appendingPathComponent(".marketplace.json").path)
        }
    }

    nonisolated private static func loadState() -> PersistedState {
        guard let data = try? BoundedFileReader.data(
            at: stateURL, maxBytes: 64 * 1024) else { return PersistedState() }
        return (try? JSONDecoder().decode(PersistedState.self, from: data))
            ?? PersistedState()
    }

    nonisolated private static func saveState(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}
