import CryptoKit
import Foundation
import Testing
@testable import MurmurCore
@testable import MurmurEngines

private func sha(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func catalog(_ id: String, _ files: [(String, String)]) -> CatalogModel {
    CatalogModel(id: id, kind: .speech, name: id, blurb: "", languages: "", accuracy: 0, speed: 0, recommended: false,
                 files: files.map { ModelFile(relativePath: $0.0, url: URL(string: "https://stub.test/\($0.0)")!,
                                              sha256: sha($0.1), bytes: Int64($0.1.utf8.count)) })
}

private func write(_ dir: URL, _ path: String, _ body: String) {
    let u = dir.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! body.write(to: u, atomically: true, encoding: .utf8)
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

private let pFiles = [("Enc.mlmodelc/weights/w.bin", "weights"), ("vocab.json", "{}")]
private let wFiles = [("Audio.mlmodelc/w.bin", "audio"), ("config.json", "cfg"), ("tokenizer/tokenizer.json", "tok"), ("tokenizer/config.json", "tcfg")]

@Suite("ModelMigration")
struct ModelMigrationTests {
    @Test func migratesParakeet() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models"), old = base.appendingPathComponent("FluidAudio/pk")
        let m = catalog("pk", pFiles)
        for (p, b) in pFiles { write(old, p, b) }
        let r = await ModelMigration.run(root: root, legacy: ["pk": old], models: [m])
        #expect(r["pk"] == .migrated)
        #expect(ModelVerification.isVerified(folder: root.appendingPathComponent("pk"), model: m))
        #expect(!exists(old))
    }

    @Test func migratesWhisper() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models")
        let old = root.appendingPathComponent("models/argmax/wk"), tok = root.appendingPathComponent("models/openai/wv3")
        let m = catalog("wk", wFiles)
        write(old, "Audio.mlmodelc/w.bin", "audio"); write(old, "config.json", "cfg")
        write(tok, "tokenizer.json", "tok"); write(tok, "config.json", "tcfg")
        let r = await ModelMigration.run(root: root, legacy: ["wk": old, "wk/tokenizer": tok], models: [m])
        #expect(r["wk"] == .migrated)
        let dest = root.appendingPathComponent("wk")
        #expect(ModelVerification.isVerified(folder: dest, model: m))
        #expect(exists(dest.appendingPathComponent("tokenizer/tokenizer.json")))
        #expect(!exists(root.appendingPathComponent("models")))
    }

    @Test func migratesWithoutDeletingOnFailure() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models"), old = base.appendingPathComponent("old")
        let m = catalog("pk", pFiles)
        write(old, "Enc.mlmodelc/weights/w.bin", "weights"); write(old, "vocab.json", "CORRUPT")
        let r = await ModelMigration.run(root: root, legacy: ["pk": old], models: [m])
        guard case .failed = r["pk"] else { Issue.record("expected failure, got \(String(describing: r["pk"]))"); return }
        #expect(exists(old.appendingPathComponent("Enc.mlmodelc/weights/w.bin")))
        #expect(exists(old.appendingPathComponent("vocab.json")))
        #expect(!ModelVerification.isVerified(folder: root.appendingPathComponent("pk"), model: m))
        #expect(!exists(root.appendingPathComponent("pk/.verified")))
    }

    @Test func missingFileLeavesLegacyUntouched() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models"), old = base.appendingPathComponent("old")
        write(old, "vocab.json", "{}")
        let r = await ModelMigration.run(root: root, legacy: ["pk": old], models: [catalog("pk", pFiles)])
        guard case .failed = r["pk"] else { Issue.record("expected failure"); return }
        #expect(exists(old.appendingPathComponent("vocab.json")))
    }

    @Test func idempotent() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models"), old = base.appendingPathComponent("old")
        let m = catalog("pk", pFiles)
        for (p, b) in pFiles { write(old, p, b) }
        _ = await ModelMigration.run(root: root, legacy: ["pk": old], models: [m])
        let again = await ModelMigration.run(root: root, legacy: ["pk": old], models: [m])
        #expect(again["pk"] == .skippedAlreadyVerified)
        #expect(ModelVerification.isVerified(folder: root.appendingPathComponent("pk"), model: m))
    }

    @Test func skipsAlreadyVerified() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models"), old = base.appendingPathComponent("old")
        let m = catalog("pk", pFiles)
        for (p, b) in pFiles { write(root.appendingPathComponent("pk"), p, b); write(old, p, b) }
        try ModelVerification.writeMarker(folder: root.appendingPathComponent("pk"), model: m)
        let r = await ModelMigration.run(root: root, legacy: ["pk": old], models: [m])
        #expect(r["pk"] == .skippedAlreadyVerified)
        #expect(exists(old.appendingPathComponent("vocab.json")))
    }

    @Test func noLegacyMeansNothingToMigrate() async throws {
        let base = tmp()
        let r = await ModelMigration.run(root: base.appendingPathComponent("Models"),
                                         legacy: ["pk": base.appendingPathComponent("nope")], models: [catalog("pk", pFiles)])
        #expect(r["pk"] == .nothingToMigrate)
    }

    @Test func engineThrowsModelMissingWhenNotVerified() async throws {
        let folder = tmp().appendingPathComponent("pk")
        let p = ParakeetTranscriber(folder: folder)
        await #expect(throws: EngineError.modelMissing("parakeet-v2")) { try await p.prepare() }
        let w = WhisperKitTranscriber(folder: folder)
        await #expect(throws: EngineError.modelMissing("whisper-large-v3-turbo")) { try await w.prepare() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MURMUR_MIGRATION_LIVE"] == "1"))
    func liveMigration() async throws {
        let root = ModelLocations.murmurModels
        let r = await ModelMigration.run(root: root, legacy: ModelMigration.defaultLegacy())
        print("LIVE MIGRATION \(r)")
        for id in ["parakeet-v2", "whisper-large-v3-turbo"] {
            let m = ModelCatalog.model(id)!
            #expect(ModelVerification.isVerified(folder: root.appendingPathComponent(id), model: m))
            for f in m.files {
                #expect(try FileHash.sha256(of: root.appendingPathComponent(id).appendingPathComponent(f.relativePath)) == f.sha256)
            }
        }
    }
}

@Suite("ModelMigrationRecovery")
struct ModelMigrationRecoveryTests {
    @Test func resumesPartiallyMovedMigration() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models"), old = base.appendingPathComponent("old")
        let m = catalog("pk", pFiles)
        // Simulate a crash after the first file moved: it is only in the destination.
        write(root.appendingPathComponent("pk"), "Enc.mlmodelc/weights/w.bin", "weights")
        write(old, "vocab.json", "{}")
        let r = await ModelMigration.run(root: root, legacy: ["pk": old], models: [m])
        #expect(r["pk"] == .migrated)
        #expect(ModelVerification.isVerified(folder: root.appendingPathComponent("pk"), model: m))
        #expect(!exists(old))
    }

    /// Verification happens before any move, so a hash mismatch can never trigger rollback; the reachable
    /// trigger is a move error part-way through. Make the second file's destination folder unwritable.
    @Test func rollbackRestoresLegacyOnMismatch() async throws {
        let base = tmp(), root = base.appendingPathComponent("Models"), old = base.appendingPathComponent("old")
        let files = [("a.bin", "aaa"), ("sub/b.bin", "bbb")]
        let m = catalog("pk", files)
        for (p, b) in files { write(old, p, b) }
        let locked = root.appendingPathComponent("pk/sub")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let r = await ModelMigration.run(root: root, legacy: ["pk": old], models: [m])
        guard case .failed = r["pk"] else { Issue.record("expected failure, got \(String(describing: r["pk"]))"); return }
        #expect(exists(old.appendingPathComponent("a.bin")))
        #expect(exists(old.appendingPathComponent("sub/b.bin")))
        #expect(!exists(root.appendingPathComponent("pk/a.bin")))
        #expect(!ModelVerification.isVerified(folder: root.appendingPathComponent("pk"), model: m))
    }

    @Test func freshInstallNeverProbesDocuments() {
        let home = URL(fileURLWithPath: "/Users/someone")
        nonisolated(unsafe) var probed: [String] = []
        let r = ModelMigration.defaultLegacy(home: home, supportRoot: URL(fileURLWithPath: "/nonexistent/support"),
                                             murmurModels: URL(fileURLWithPath: "/nonexistent/models")) { probed.append($0); return false }
        #expect(!probed.isEmpty)
        #expect(!probed.contains { $0.contains("/Documents") })
        #expect(r["whisper-large-v3-turbo/tokenizer"] != nil)
    }

    @Test func upgraderWithLegacyWhisperProbesDocumentsTokenizer() {
        let home = URL(fileURLWithPath: "/Users/someone")
        nonisolated(unsafe) var probed: [String] = []
        let r = ModelMigration.defaultLegacy(home: home, supportRoot: URL(fileURLWithPath: "/s"), murmurModels: URL(fileURLWithPath: "/m")) { p in
            probed.append(p); return p.contains("openai_whisper-large-v3") || p.hasPrefix("/Users/someone/Documents")
        }
        #expect(probed.contains { $0.hasPrefix("/Users/someone/Documents") })
        #expect(r["whisper-large-v3-turbo/tokenizer"]?.path.hasPrefix("/Users/someone/Documents") == true)
    }
}
