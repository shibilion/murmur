import Foundation
import Testing
@testable import MurmurCore

struct StoreTests {
    // MARK: - FileHistoryStore Tests

    @Test
    func pruneOlderThan7Days() async throws {
        let tmpDir = try temporaryDirectory()
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let store = FileHistoryStore(directory: tmpDir, now: { now })

        // Add entry from 8 days ago (should be pruned)
        let oldEntry = HistoryEntry(date: eightDaysAgo, raw: "old", final: "old text", appBundleId: "com.app")
        await store.append(oldEntry)

        // Add entry from now (should remain)
        let newEntry = HistoryEntry(date: now, raw: "new", final: "new text", appBundleId: "com.app")
        await store.append(newEntry)

        let recent = await store.recent(10)
        #expect(recent.count == 1)
        #expect(recent[0].raw == "new")
    }

    @Test
    func capAt100() async throws {
        let tmpDir = try temporaryDirectory()
        let now = Date()
        let store = FileHistoryStore(directory: tmpDir, now: { now })

        // Add 105 entries
        for i in 0..<105 {
            let entry = HistoryEntry(date: now, raw: "text\(i)", final: "final\(i)", appBundleId: "com.app")
            await store.append(entry)
        }

        let recent = await store.recent(200)
        #expect(recent.count == 100)
        // Newest should be first (newest = last added)
        #expect(recent[0].raw == "text104")
    }

    @Test
    func clearEmpties() async throws {
        let tmpDir = try temporaryDirectory()
        let now = Date()
        let store = FileHistoryStore(directory: tmpDir, now: { now })

        let entry = HistoryEntry(date: now, raw: "text", final: "final", appBundleId: "com.app")
        await store.append(entry)

        var recent = await store.recent(10)
        #expect(recent.count == 1)

        await store.clear()

        recent = await store.recent(10)
        #expect(recent.count == 0)
    }

    @Test
    func historyFileIsPrivate() async throws {
        let tmpDir = try temporaryDirectory()
        let now = Date()
        let store = FileHistoryStore(directory: tmpDir, now: { now })

        let entry = HistoryEntry(date: now, raw: "secret", final: "secret text", appBundleId: "com.app")
        await store.append(entry)

        let historyPath = tmpDir.appendingPathComponent("history.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: historyPath.path)
        let permissions = attrs[.posixPermissions] as? Int ?? 0

        // Should be 0o600 (read/write for owner only)
        #expect(permissions == 0o600)
    }

    @Test
    func storeDirectoryIsPrivate() async throws {
        let tmpDir = try temporaryDirectory()
        let now = Date()
        let historyStore = FileHistoryStore(directory: tmpDir, now: { now })

        let entry = HistoryEntry(date: now, raw: "secret", final: "secret text", appBundleId: "com.app")
        await historyStore.append(entry)

        // Check directory permissions after history append
        var attrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
        var permissions = attrs[.posixPermissions] as? Int ?? 0
        #expect(permissions == 0o700)

        // Also test with SettingsStore
        let settingsStore = SettingsStore(directory: tmpDir)
        try settingsStore.save(Settings())

        // Check directory permissions after settings save
        attrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
        permissions = attrs[.posixPermissions] as? Int ?? 0
        #expect(permissions == 0o700)
    }

    // MARK: - SettingsStore Tests

    @Test
    func settingsRoundTrip() async throws {
        let tmpDir = try temporaryDirectory()
        let store = SettingsStore(directory: tmpDir)

        var settings = Settings()
        settings.cloudBoost = true
        settings.strength = .light
        settings.dictionary = ["hello", "world"]
        settings.englishEngine = "whisperkit"

        try store.save(settings)
        let loaded = try store.load()

        #expect(loaded.cloudBoost == true)
        #expect(loaded.strength == .light)
        #expect(loaded.dictionary == ["hello", "world"])
        #expect(loaded.englishEngine == "whisperkit")
    }

    @Test
    func corruptSettingsFileFallsBackToDefaults() throws {
        let tmpDir = try temporaryDirectory()
        let settingsPath = tmpDir.appendingPathComponent("settings.json")

        // Write corrupt JSON
        try "{ invalid json }".write(to: settingsPath, atomically: true, encoding: .utf8)

        let store = SettingsStore(directory: tmpDir)
        let loaded = try store.load()

        // Should return defaults without crashing
        #expect(loaded == Settings())
    }

    @Test
    func settingsMissingKeysUseDefaults() throws {
        let tmpDir = try temporaryDirectory()
        let settingsPath = tmpDir.appendingPathComponent("settings.json")

        // Write JSON with only one key
        let json = #"{"cloudBoost": true}"#
        try Data(json.utf8).write(to: settingsPath, options: .atomic)

        let store = SettingsStore(directory: tmpDir)
        let loaded = try store.load()

        // Assert all fields: loaded should match Settings() except cloudBoost
        var expected = Settings()
        expected.cloudBoost = true
        #expect(loaded == expected)
    }

    // MARK: - InMemorySecretStore Tests

    @Test
    func inMemorySecretStoreSetGetDelete() {
        let store = InMemorySecretStore()

        // Set and get
        store.set("api_key", "secret123")
        #expect(store.get("api_key") == "secret123")

        // Update
        store.set("api_key", "newsecret")
        #expect(store.get("api_key") == "newsecret")

        // Delete
        store.set("api_key", nil)
        #expect(store.get("api_key") == nil)

        // Get non-existent
        #expect(store.get("nonexistent") == nil)
    }

    // MARK: - KeychainStore Tests

    @Test(.enabled(if: isKeychainTestsEnabled()))
    func keychainRoundTrip() throws {
        let testAccount = "test-\(UUID().uuidString)"
        let store = KeychainStore()

        // Set
        store.set(testAccount, "testvalue123")

        // Get
        let value = store.get(testAccount)
        #expect(value == "testvalue123")

        // Update
        store.set(testAccount, "newvalue456")
        #expect(store.get(testAccount) == "newvalue456")

        // Delete
        store.set(testAccount, nil)
        #expect(store.get(testAccount) == nil)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
        let testDir = tmpDir.appendingPathComponent("murmur-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        return testDir
    }
}

private func isKeychainTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["MURMUR_KEYCHAIN_TESTS"] == "1"
}
