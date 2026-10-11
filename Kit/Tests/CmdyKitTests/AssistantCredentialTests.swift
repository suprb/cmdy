import Foundation
import XCTest
@testable import CmdyKit

final class AssistantCredentialTests: XCTestCase {
    private final class Store: AssistantCredentialStore {
        enum Failure: Error { case unavailable }
        var value: String?
        var rejectRead = false
        var rejectWrite = false
        var ignoreWrite = false
        var writes = 0
        init(_ value: String? = nil) { self.value = value }
        func read() throws -> String? {
            if rejectRead { throw Failure.unavailable }
            return value
        }
        func write(_ value: String?) throws {
            if rejectWrite { throw Failure.unavailable }
            writes += 1
            if !ignoreWrite { self.value = value }
        }
    }

    private func withCredentials(
        _ body: (AssistantCredentials, UserDefaults, Store) throws -> Void
    ) throws {
        let domain = "cmdy.credentials.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = Store()
        try body(AssistantCredentials(defaults: defaults, store: store), defaults, store)
    }

    func testLegacyDefaultsRemovedOnlyAfterVerifiedKeychainMigration() throws {
        try withCredentials { credentials, defaults, store in
            defaults.set("fixture-old-key", forKey: AssistantCredentials.legacyDefaultsKey)
            XCTAssertEqual(try credentials.value(), "fixture-old-key")
            XCTAssertEqual(store.value, "fixture-old-key")
            XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyDefaultsKey))
            XCTAssertEqual(store.writes, 1)
            XCTAssertEqual(try credentials.value(), "fixture-old-key")
            XCTAssertEqual(store.writes, 1)
        }
    }

    func testLockedKeychainLeavesLegacyDefaultsUntouched() throws {
        try withCredentials { credentials, defaults, store in
            defaults.set("fixture-old-key", forKey: AssistantCredentials.legacyDefaultsKey)
            store.rejectRead = true
            XCTAssertThrowsError(try credentials.value())
            XCTAssertEqual(credentials.legacyValue, "fixture-old-key")
            XCTAssertEqual(store.writes, 0)
        }
    }

    func testRejectedMigrationLeavesLegacyDefaultsUntouched() throws {
        try withCredentials { credentials, defaults, store in
            defaults.set("fixture-old-key", forKey: AssistantCredentials.legacyDefaultsKey)
            store.rejectWrite = true
            XCTAssertThrowsError(try credentials.value())
            XCTAssertEqual(credentials.legacyValue, "fixture-old-key")
            XCTAssertNil(store.value)
        }
    }

    func testUnverifiedMigrationKeepsOriginalForRetry() throws {
        try withCredentials { credentials, defaults, store in
            defaults.set("fixture-old-key", forKey: AssistantCredentials.legacyDefaultsKey)
            store.ignoreWrite = true
            XCTAssertThrowsError(try credentials.value())
            XCTAssertEqual(credentials.legacyValue, "fixture-old-key")
        }
    }

    func testKeychainValueWinsOverObsoleteDefaults() throws {
        try withCredentials { credentials, defaults, store in
            defaults.set("fixture-obsolete", forKey: AssistantCredentials.legacyDefaultsKey)
            store.value = "fixture-current"
            XCTAssertEqual(try credentials.value(), "fixture-current")
            XCTAssertEqual(store.writes, 0)
            XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyDefaultsKey))
        }
    }

    func testConfigMigrationVerifiesValueWithoutWritingPlaintextDefaults() throws {
        try withCredentials { credentials, defaults, store in
            try credentials.migrateConfigValue("  fixture-config-key \n")
            XCTAssertEqual(store.value, "fixture-config-key")
            XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyDefaultsKey))
        }
    }

    func testRejectedConfigMigrationPreservesLegacyDefaults() throws {
        try withCredentials { credentials, defaults, store in
            defaults.set("fixture-legacy", forKey: AssistantCredentials.legacyDefaultsKey)
            store.rejectWrite = true
            XCTAssertThrowsError(try credentials.migrateConfigValue("fixture-new"))
            XCTAssertNil(store.value)
            XCTAssertEqual(credentials.legacyValue, "fixture-legacy")
        }
    }

    func testLegacyConfigCannotRevertAKeySavedInSettings() throws {
        try withCredentials { credentials, _, store in
            store.value = "fixture-current"
            try credentials.migrateConfigValue("fixture-old-config")
            XCTAssertEqual(store.value, "fixture-current")
            XCTAssertEqual(store.writes, 0)
        }
    }

    func testIsolatedCredentialsNeverReadOrEraseRealLegacyDefaults() throws {
        let domain = "cmdy.credentials.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("fixture-real-legacy", forKey: AssistantCredentials.legacyDefaultsKey)
        defaults.set(true, forKey: AssistantCredentials.legacyMigrationSuppressedKey)
        let credentials = AssistantCredentials(
            defaults: defaults, store: MemoryAssistantCredentialStore(), migratesLegacyDefaults: false)
        XCTAssertNil(try credentials.value())
        try credentials.migrateConfigValue("fixture-isolated-config")
        XCTAssertEqual(try credentials.value(), "fixture-isolated-config")
        try credentials.save("fixture-isolated")
        try credentials.migrateConfigValue("fixture-isolated-config")
        XCTAssertEqual(try credentials.value(), "fixture-isolated")
        XCTAssertEqual(defaults.string(forKey: AssistantCredentials.legacyDefaultsKey), "fixture-real-legacy")
        XCTAssertTrue(defaults.bool(forKey: AssistantCredentials.legacyMigrationSuppressedKey))
    }

    func testEmptyConfigEntryCannotEraseStoredCredential() throws {
        try withCredentials { credentials, _, store in
            store.value = "fixture-current"
            try credentials.migrateConfigValue(" \n")
            XCTAssertEqual(store.value, "fixture-current")
            XCTAssertEqual(store.writes, 0)
        }
    }

    func testExplicitSaveAndRemovalKeepSecretOnlyInCredentialStore() throws {
        try withCredentials { credentials, defaults, store in
            try credentials.save("fixture-key")
            XCTAssertEqual(store.value, "fixture-key")
            XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyDefaultsKey))
            try credentials.save(nil)
            XCTAssertNil(store.value)
        }
    }

    func testExplicitRemovalSuppressesStaleConfigAndDefaultsAcrossCredentialInstances() throws {
        try withCredentials { credentials, defaults, store in
            try credentials.save("fixture-current")
            try credentials.save(nil)
            XCTAssertTrue(defaults.bool(forKey: AssistantCredentials.legacyMigrationSuppressedKey))

            // A failed config cleanup, or an older app restoring its defaults,
            // must not resurrect a key the user explicitly removed.
            defaults.set("fixture-stale-defaults", forKey: AssistantCredentials.legacyDefaultsKey)
            try credentials.migrateConfigValue("fixture-stale-config")
            XCTAssertNil(credentials.legacyValue)
            XCTAssertNil(try credentials.value())

            let relaunched = AssistantCredentials(defaults: defaults, store: store)
            try relaunched.migrateConfigValue("fixture-stale-config")
            XCTAssertNil(relaunched.legacyValue)
            XCTAssertNil(try relaunched.value())
            store.rejectRead = true
            XCTAssertThrowsError(try relaunched.value())
            XCTAssertNil(relaunched.legacyValue, "A failed Keychain read must not revive the legacy fallback.")
            XCTAssertNil(store.value)
            XCTAssertEqual(store.writes, 2)
        }
    }

    func testRejectedAndUnverifiedRemovalPreserveKeyAndMigration() throws {
        for ignoredWrite in [false, true] {
            try withCredentials { credentials, defaults, store in
                store.value = "fixture-current"
                defaults.set("fixture-legacy", forKey: AssistantCredentials.legacyDefaultsKey)
                store.rejectWrite = !ignoredWrite
                store.ignoreWrite = ignoredWrite
                XCTAssertThrowsError(try credentials.save(nil))
                XCTAssertEqual(store.value, "fixture-current")
                XCTAssertEqual(credentials.legacyValue, "fixture-legacy")
                XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyMigrationSuppressedKey))

                store.rejectWrite = false
                store.ignoreWrite = false
                store.value = nil
                try credentials.migrateConfigValue("fixture-retry")
                XCTAssertEqual(store.value, "fixture-retry")
            }
        }
    }

    func testRemovalReadFailureKeepsLegacySourceForRetry() throws {
        try withCredentials { credentials, defaults, store in
            store.value = "fixture-current"
            defaults.set("fixture-legacy", forKey: AssistantCredentials.legacyDefaultsKey)
            store.rejectRead = true
            XCTAssertThrowsError(try credentials.save(nil))
            XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyMigrationSuppressedKey))
            XCTAssertEqual(credentials.legacyValue, "fixture-legacy")
            store.rejectRead = false
            XCTAssertEqual(try credentials.value(), "fixture-legacy")
        }
    }

    func testExplicitSaveClearsRemovalSuppressionOnlyAfterVerifiedSave() throws {
        try withCredentials { credentials, defaults, store in
            try credentials.save(nil)
            store.rejectWrite = true
            XCTAssertThrowsError(try credentials.save("fixture-rejected"))
            XCTAssertTrue(defaults.bool(forKey: AssistantCredentials.legacyMigrationSuppressedKey))

            store.rejectWrite = false
            store.ignoreWrite = true
            XCTAssertThrowsError(try credentials.save("fixture-unverified"))
            XCTAssertTrue(defaults.bool(forKey: AssistantCredentials.legacyMigrationSuppressedKey))
            store.ignoreWrite = false
            try credentials.migrateConfigValue("fixture-stale-config")
            XCTAssertNil(store.value)

            try credentials.save("  fixture-replacement \n")
            XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyMigrationSuppressedKey))
            try credentials.migrateConfigValue("fixture-stale-config")
            XCTAssertEqual(try credentials.value(), "fixture-replacement")
        }
    }

    func testMigrationSuppressionDoesNotHideAuthoritativeStoredKey() throws {
        try withCredentials { credentials, defaults, store in
            defaults.set(true, forKey: AssistantCredentials.legacyMigrationSuppressedKey)
            defaults.set("fixture-stale-defaults", forKey: AssistantCredentials.legacyDefaultsKey)
            store.value = "fixture-current"
            XCTAssertEqual(try credentials.value(), "fixture-current")
            try credentials.migrateConfigValue("fixture-stale-config")
            XCTAssertEqual(store.value, "fixture-current")
            XCTAssertEqual(store.writes, 0)
        }
    }

    func testIsolatedRemovalSuppressesOnlyThatRunWithoutWritingDefaults() throws {
        try withCredentials { _, defaults, _ in
            defaults.set("fixture-real-legacy", forKey: AssistantCredentials.legacyDefaultsKey)
            let credentials = AssistantCredentials(
                defaults: defaults, store: MemoryAssistantCredentialStore(), migratesLegacyDefaults: false)
            try credentials.migrateConfigValue("fixture-isolated-config")
            try credentials.save(nil)
            try credentials.migrateConfigValue("fixture-isolated-config")
            XCTAssertNil(try credentials.value())
            XCTAssertNil(defaults.object(forKey: AssistantCredentials.legacyMigrationSuppressedKey))
            XCTAssertEqual(defaults.string(forKey: AssistantCredentials.legacyDefaultsKey), "fixture-real-legacy")

            let nextRun = AssistantCredentials(
                defaults: defaults, store: MemoryAssistantCredentialStore(), migratesLegacyDefaults: false)
            try nextRun.migrateConfigValue("fixture-isolated-config")
            XCTAssertEqual(try nextRun.value(), "fixture-isolated-config")
        }
    }
}
