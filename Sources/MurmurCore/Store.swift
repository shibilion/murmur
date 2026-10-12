import Foundation
import Security
import Synchronization
import os

// MARK: - SecretStoring Protocol

public protocol SecretStoring: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

// MARK: - FileHistoryStore

public final class FileHistoryStore: HistoryStoring, @unchecked Sendable {
    private let directory: URL
    private let now: @Sendable () -> Date
    private let state = Mutex<[HistoryEntry]>([])
    private let historyPath: URL

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
        self.historyPath = directory.appendingPathComponent("history.json")

        // Ensure directory exists with proper permissions
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        // Try to load existing history
        if let loadedEntries = Self.loadFromFile(historyPath) {
            state.withLock { $0 = loadedEntries }
        }
    }

    public func append(_ e: HistoryEntry) async {
        state.withLock { entries in
            let sevenDaysAgo = now().addingTimeInterval(-7 * 24 * 60 * 60)

            // Remove entries older than 7 days
            entries.removeAll { $0.date < sevenDaysAgo }

            // Append new entry
            entries.append(e)

            // Keep only the newest 100
            if entries.count > 100 {
                entries = Array(entries.suffix(100))
            }
        }

        // Write to disk
        try? writeToFile()
    }

    public func recent(_ n: Int) async -> [HistoryEntry] {
        let entries = state.withLock { $0 }
        return Array(entries.suffix(n).reversed())
    }

    public func clear() async {
        state.withLock { $0.removeAll() }
        try? writeToFile()
    }

    // MARK: - Private

    private func writeToFile() throws {
        let entries = state.withLock { $0 }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: historyPath, options: .atomic)

        // Set file permissions to 0600 (read/write for owner only)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: historyPath.path
        )

        // Ensure directory permissions are 0o700
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func loadFromFile(_ path: URL) -> [HistoryEntry]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - SettingsStore

public final class SettingsStore {
    private let directory: URL
    private let settingsPath: URL

    public init(directory: URL) {
        self.directory = directory
        self.settingsPath = directory.appendingPathComponent("settings.json")

        // Ensure directory exists with proper permissions
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            return Settings()
        }

        do {
            let data = try Data(contentsOf: settingsPath)
            let decoder = JSONDecoder()
            return try decoder.decode(Settings.self, from: data)
        } catch {
            // Return defaults on any decode error
            return Settings()
        }
    }

    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsPath, options: .atomic)

        // Set file permissions to 0600
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: settingsPath.path
        )

        // Ensure directory permissions are 0o700
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    public static func defaultDirectory() -> URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupportDir = paths[0].appendingPathComponent("Murmur")
        try? FileManager.default.createDirectory(
            at: appSupportDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: appSupportDir.path
        )
        return appSupportDir
    }
}

// MARK: - KeychainStore

public final class KeychainStore: SecretStoring {
    private static let service = "dev.murmur.app"
    private static let logger = Logger(subsystem: "dev.murmur.app", category: "keychain")

    public init() {}

    public func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        } else if status != errSecSuccess {
            Self.logger.error("Keychain get failed for key \(key): \(status)")
            return nil
        }

        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String?) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        if let value = value {
            let data = value.data(using: .utf8) ?? Data()

            // Try to update first
            let updateStatus = SecItemUpdate(
                attributes as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )

            if updateStatus == errSecSuccess {
                return
            } else if updateStatus == errSecItemNotFound {
                // If not found, add new item
                var addAttrs = attributes
                addAttrs[kSecValueData as String] = data
                let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)

                if addStatus == errSecDuplicateItem {
                    // Race condition: item was added by another thread, retry update
                    let retryStatus = SecItemUpdate(
                        attributes as CFDictionary,
                        [kSecValueData as String: data] as CFDictionary
                    )
                    if retryStatus != errSecSuccess {
                        Self.logger.error("Keychain set retry failed for key \(key): \(retryStatus)")
                    }
                } else if addStatus != errSecSuccess {
                    Self.logger.error("Keychain set failed for key \(key): \(addStatus)")
                }
            } else {
                Self.logger.error("Keychain set failed for key \(key): \(updateStatus)")
            }
        } else {
            // Delete
            let deleteStatus = SecItemDelete(attributes as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                Self.logger.error("Keychain delete failed for key \(key): \(deleteStatus)")
            }
        }
    }
}

// MARK: - InMemorySecretStore

public final class InMemorySecretStore: SecretStoring {
    private let state = Mutex<[String: String]>([:])

    public init() {}

    public func get(_ key: String) -> String? {
        state.withLock { $0[key] }
    }

    public func set(_ key: String, _ value: String?) {
        state.withLock { dict in
            if let value = value {
                dict[key] = value
            } else {
                dict.removeValue(forKey: key)
            }
        }
    }
}
