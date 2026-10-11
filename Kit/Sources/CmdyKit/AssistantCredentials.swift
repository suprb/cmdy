import Foundation
import Security
import LocalAuthentication
import ProductIdentity

/// The built-in assistant owns one credential. Connectors keep their own
/// service/account pairs; this store cannot read or replace those items.
public protocol AssistantCredentialStore: AnyObject {
    func read() throws -> String?
    func write(_ value: String?) throws
}

public final class KeychainAssistantCredentialStore: AssistantCredentialStore {
    private let service: String
    private let account = "anthropic-api-key"

    public init(service: String = ProductIdentity.current.bundleIdentifier + ".assistant") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background diagnostics must not interrupt typing with a Keychain
        // authorization dialog. Explicitly saving a key can ask for access.
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CredentialError.unavailable(status)
        }
        return value.isEmpty ? nil : value
    }

    public func write(_ value: String?) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.unavailable(status)
            }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.unavailable(status) }
    }

    private enum CredentialError: Error {
        case unavailable(OSStatus)
    }
}

/// Isolated UI profiles never touch the user's Keychain, even when a config
/// fixture contains a key. Unit tests can supply this or a faulting fake store.
public final class MemoryAssistantCredentialStore: AssistantCredentialStore {
    private var value: String?
    public init(value: String? = nil) { self.value = value }
    public func read() throws -> String? { value }
    public func write(_ value: String?) throws { self.value = value }
}

/// Migration is deliberately separate from preferences/config UI. The source
/// value is removed only after the destination can return it successfully.
/// A failed read, write or verification leaves the legacy source available.
public final class AssistantCredentials {
    static let legacyDefaultsKey = "anthropicKey"
    static let legacyMigrationSuppressedKey = "assistantLegacyMigrationSuppressed"
    private let defaults: UserDefaults
    private let store: AssistantCredentialStore
    private let migratesLegacyDefaults: Bool
    private var isolatedMigrationSuppressed = false
    private let lock = NSLock()

    public init(defaults: UserDefaults, store: AssistantCredentialStore,
                migratesLegacyDefaults: Bool = true) {
        self.defaults = defaults
        self.store = store
        self.migratesLegacyDefaults = migratesLegacyDefaults
    }

    public var legacyValue: String? {
        guard migratesLegacyDefaults, !legacyMigrationSuppressed else { return nil }
        let value = defaults.string(forKey: Self.legacyDefaultsKey)
        return value?.isEmpty == false ? value : nil
    }

    private var legacyMigrationSuppressed: Bool {
        migratesLegacyDefaults
            ? defaults.bool(forKey: Self.legacyMigrationSuppressedKey)
            : isolatedMigrationSuppressed
    }

    public func value() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let saved = try store.read()
        if let saved, !saved.isEmpty {
            // A previous successful migration or an explicit Settings save
            // takes precedence over the old UserDefaults entry.
            if migratesLegacyDefaults { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
            return saved
        }
        guard let legacy = legacyValue else { return nil }
        try store.write(legacy)
        guard try store.read() == legacy else { throw MigrationError.verificationFailed }
        if migratesLegacyDefaults { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
        return legacy
    }

    public func save(_ value: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized?.isEmpty == false ? normalized : nil
        // SecItemUpdate is atomic; a rejected save keeps the existing item.
        try store.write(key)
        guard try store.read() == key else { throw MigrationError.verificationFailed }
        if migratesLegacyDefaults {
            // Failed plaintext cleanup must not undo an explicit removal on
            // reload or relaunch. Only a verified explicit save re-enables
            // migration; the marker never contains credential material.
            if key == nil {
                defaults.set(true, forKey: Self.legacyMigrationSuppressedKey)
            } else {
                defaults.removeObject(forKey: Self.legacyMigrationSuppressedKey)
            }
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        } else {
            // An isolated profile may share real UserDefaults. Keep its
            // removal decision in memory, like its credential store.
            isolatedMigrationSuppressed = key == nil
        }
    }

    /// Accept a legacy config entry, then ask the caller to remove it from
    /// plaintext. No empty entry can erase a stored key during config reload.
    public func migrateConfigValue(_ value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let existing = try store.read(), !existing.isEmpty {
            // Once migrated, Settings owns key replacement. A plaintext line
            // left by a failed cleanup must never revert a newer Keychain key.
            if migratesLegacyDefaults { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
            return
        }
        guard !legacyMigrationSuppressed else { return }
        try store.write(value)
        guard try store.read() == value else { throw MigrationError.verificationFailed }
        if migratesLegacyDefaults { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
    }

    private enum MigrationError: Error {
        case verificationFailed
    }
}
