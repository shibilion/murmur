import Foundation
import MurmurCore

public enum MigrationResult: Equatable, Sendable {
    case migrated
    case skippedAlreadyVerified
    case nothingToMigrate
    case failed(String)
}

/// Moves models from the pre-0.2 locations (FluidAudio cache, WhisperKit/Hub cache) into
/// `<root>/<catalog id>/<relativePath>`. Files are hashed in place first; nothing moves unless all match.
public enum ModelMigration {
    /// `exists` and `home` are seams for tests. `~/Documents` (a TCC-protected folder) is probed only when the legacy
    /// Whisper model folder exists, so a fresh install never triggers the Documents permission prompt.
    public static func defaultLegacy(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportRoot: URL = ModelLocations.applicationSupport,
        murmurModels: URL = ModelLocations.murmurModels,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: URL] {
        let old = murmurModels.appendingPathComponent("models", isDirectory: true)
        let whisper = old.appendingPathComponent(
            "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        var tokenizer = old.appendingPathComponent("openai/whisper-large-v3", isDirectory: true)
        if exists(whisper.path), !exists(tokenizer.appendingPathComponent("tokenizer.json").path) {
            let docs = home.appendingPathComponent("Documents/huggingface/models/openai/whisper-large-v3", isDirectory: true)
            if exists(docs.appendingPathComponent("tokenizer.json").path) { tokenizer = docs }
        }
        return [
            "parakeet-v2": supportRoot.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v2", isDirectory: true),
            "whisper-large-v3-turbo": whisper,
            "whisper-large-v3-turbo/tokenizer": tokenizer,
        ]
    }

    /// `legacy` maps `<id>` (or `<id>/<subfolder>`) to the old directory holding the files that belong at that path.
    public static func run(root: URL, legacy: [String: URL]? = nil,
                           models: [CatalogModel] = ModelCatalog.all) async -> [String: MigrationResult] {
        let legacy = legacy ?? defaultLegacy()
        var out: [String: MigrationResult] = [:]
        for m in models where m.kind == .speech {
            out[m.id] = migrate(m, root: root, legacy: legacy)
        }
        return out
    }

    private static func legacyURL(_ file: ModelFile, model m: CatalogModel, legacy: [String: URL]) -> URL? {
        var best: (prefix: Int, url: URL)?
        for (key, dir) in legacy {
            let sub: String
            if key == m.id { sub = "" }
            else if key.hasPrefix(m.id + "/") { sub = String(key.dropFirst(m.id.count + 1)) }
            else { continue }
            let rest: String
            if sub.isEmpty { rest = file.relativePath }
            else if file.relativePath.hasPrefix(sub + "/") { rest = String(file.relativePath.dropFirst(sub.count + 1)) }
            else { continue }
            if best == nil || sub.count > best!.prefix { best = (sub.count, dir.appendingPathComponent(rest)) }
        }
        return best?.url
    }

    private static func migrate(_ m: CatalogModel, root: URL, legacy: [String: URL]) -> MigrationResult {
        let fm = FileManager.default
        let dest = root.appendingPathComponent(m.id, isDirectory: true)
        if ModelVerification.isVerified(folder: dest, model: m) { return .skippedAlreadyVerified }

        guard let primary = legacy[m.id], fm.fileExists(atPath: primary.path) || fm.fileExists(atPath: dest.path) else {
            return .nothingToMigrate
        }
        var sources: [(file: ModelFile, from: URL)] = []
        for f in m.files {
            if let from = legacyURL(f, model: m, legacy: legacy), fm.fileExists(atPath: from.path) {
                sources.append((f, from))
            } else if (try? FileHash.sha256(of: dest.appendingPathComponent(f.relativePath))) == f.sha256 {
                continue  // already moved by an interrupted earlier run
            } else {
                return .failed("missing \(f.relativePath)")
            }
        }
        // Verify in place; legacy data is untouched on any mismatch.
        for (f, from) in sources {
            guard (try? FileHash.sha256(of: from)) == f.sha256 else { return .failed("hash mismatch \(f.relativePath)") }
        }
        // Move; roll back on any error.
        var moved: [(from: URL, to: URL)] = []
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (f, from) in sources {
                let to = dest.appendingPathComponent(f.relativePath)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                try fm.moveItem(at: from, to: to)
                moved.append((from, to))
            }
            try ModelVerification.writeMarker(folder: dest, model: m)
        } catch {
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            return .failed("move failed: \(error.localizedDescription)")
        }
        // Remove emptied legacy folders only.
        for (key, dir) in legacy where key == m.id || key.hasPrefix(m.id + "/") {
            removeEmptyTree(dir)
            pruneEmptyParents(of: dir, within: root)
        }
        return .migrated
    }

    /// Removes `dir` if it contains only empty directories. Never deletes a file.
    @discardableResult
    private static func removeEmptyTree(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        var empty = true
        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if !(isDir && removeEmptyTree(u)) { empty = false }
        }
        guard empty else { return false }
        return (try? fm.removeItem(at: dir)) != nil
    }

    /// Walks up from a removed legacy folder, deleting now-empty parents that sit strictly inside `root`.
    private static func pruneEmptyParents(of dir: URL, within root: URL) {
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        var p = dir.deletingLastPathComponent().standardizedFileURL
        while p.path.hasPrefix(base + "/") {
            guard let items = try? fm.contentsOfDirectory(atPath: p.path), items.isEmpty else { return }
            try? fm.removeItem(at: p)
            p = p.deletingLastPathComponent()
        }
    }
}
