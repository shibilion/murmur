import Combine
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import MurmurCore
@testable import MurmurEngines

// MARK: helpers

private func sha(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dm-test-\(UUID().uuidString)")
}

private func model(_ id: String = UUID().uuidString, files: [(String, String)] = [("a.bin", "hello"), ("sub/b.bin", "world!")],
                   declaredBytes: Int64? = nil) -> CatalogModel {
    CatalogModel(id: id, kind: .speech, name: id, blurb: "", languages: "", accuracy: 0, speed: 0, recommended: false,
                 files: files.map {
                     ModelFile(relativePath: $0.0, url: URL(string: "https://stub.test/\(id)/\($0.0)")!,
                               sha256: sha($0.1), bytes: declaredBytes ?? Int64($0.1.utf8.count))
                 })
}

private func contents(_ m: CatalogModel, _ f: ModelFile) -> String {
    // Test files: body is derived from the sha table below.
    bodies.withLock { $0[f.sha256] ?? "" }
}
private let bodies = Mutex<[String: String]>([:])
private func register(_ files: [(String, String)]) { bodies.withLock { b in files.forEach { b[sha($0.1)] = $0.1 } } }

private func waitFor(_ timeout: Double = 5, _ cond: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

/// Fake downloader: writes the body matching the file's URL and reports scripted progress.
final class FakeDownloader: Downloader, @unchecked Sendable {
    struct Calls { var resumeData: [Data?] = [] }
    let calls = Mutex(Calls())
    let bodyFor: @Sendable (URL) -> String
    let behavior: @Sendable (Int, @Sendable (Int64) -> Void) async throws -> Void
    init(bodyFor: @escaping @Sendable (URL) -> String,
         behavior: @escaping @Sendable (Int, @Sendable (Int64) -> Void) async throws -> Void = { _, _ in }) {
        self.bodyFor = bodyFor; self.behavior = behavior
    }
    func download(url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let n = calls.withLock { $0.resumeData.append(resumeData); return $0.resumeData.count }
        try await behavior(n, progress)
        let body = bodyFor(url)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString)")
        try Data(body.utf8).write(to: out)
        progress(Int64(body.utf8.count))
        return out
    }
}

private func bodyLookup(_ m: CatalogModel) -> @Sendable (URL) -> String {
    let table = Dictionary(uniqueKeysWithValues: m.files.map { f in (f.url, bodies.withLock { $0[f.sha256] ?? "" }) })
    return { table[$0] ?? "" }
}

// URLProtocol stub keyed by absolute URL so suites can run in parallel.
final class DMStubProtocol: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable { var status: Int; var body: Data; var error: URLError? }
    private static let table = Mutex<[String: Canned]>([:])
    static func set(_ url: URL, _ c: Canned) { table.withLock { $0[url.absoluteString] = c } }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [DMStubProtocol.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let c = Self.table.withLock { $0[request.url!.absoluteString] } ?? Canned(status: 404, body: Data(), error: nil)
        if let e = c.error { client?.urlProtocol(self, didFailWithError: e); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: c.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: c.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func perms(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

// MARK: tests

@MainActor
struct DownloadManagerTests {
    private func make(_ m: CatalogModel, root: URL, downloader: (any Downloader)? = nil,
                      session: URLSession = .shared, free: Int64 = .max / 4) -> DownloadManager {
        DownloadManager(root: root, session: session, models: [m], downloader: downloader, freeSpace: { free })
    }

    @Test func progressReportsBytes() async {
        let files = [("a.bin", "hello"), ("b.bin", "world!")]; register(files)
        let m = model(files: files)
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let fake = FakeDownloader(bodyFor: bodyLookup(m)) { n, progress in
            if n == 1 { progress(3); await withCheckedContinuation { c in gate.withLock { $0 = c } } }
        }
        let dm = make(m, root: tempRoot(), downloader: fake)
        dm.start(m.id)
        #expect(await waitFor { if case .downloading(let d, let t, _) = dm.states[m.id] { return d == 3 && t == 11 } else { return false } })
        gate.withLock { $0 }?.resume()
        #expect(await waitFor { dm.states[m.id] == .ready })
    }

    @Test func failedLoadMarksFailedNotPreparing() async throws {
        let files = [("a.bin", "hello"), ("b.bin", "world!")]; register(files)
        let m = model("parakeet-v2", files: files)
        let root = tempRoot()
        let dir = root.appendingPathComponent(m.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.bin"))
        try Data("world!".utf8).write(to: dir.appendingPathComponent("b.bin"))
        try ModelVerification.listHash(m).write(to: dir.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        let dm = make(m, root: root)
        #expect(dm.states[m.id] == .ready)
        let engine = ParakeetTranscriber(folder: dir, downloads: dm, model: m)
        await #expect(throws: (any Error).self) { try await engine.prepare() }
        guard case .failed = dm.states[m.id] else { Issue.record("expected .failed, got \(String(describing: dm.states[m.id]))"); return }
    }

    @Test func startFromFailedReverifies() async throws {
        let files = [("a.bin", "hello"), ("b.bin", "world!")]; register(files)
        let m = model(files: files)
        let root = tempRoot()
        let dir = root.appendingPathComponent(m.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.bin"))
        try Data("WORLD!".utf8).write(to: dir.appendingPathComponent("b.bin"))  // corrupt, same size
        let fake = FakeDownloader(bodyFor: bodyLookup(m))
        let dm = make(m, root: root, downloader: fake)
        dm.markFailed(m.id, "Couldn't load the model. Delete it in Settings → Models and download it again.")
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .ready })
        #expect((try? String(contentsOf: dir.appendingPathComponent("b.bin"), encoding: .utf8)) == "world!")
    }

    @Test func cancelLeavesNotDownloaded() async {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        let fake = FakeDownloader(bodyFor: bodyLookup(m)) { _, _ in try await Task.sleep(for: .seconds(60)) }
        let root = tempRoot()
        let dm = make(m, root: root, downloader: fake)
        dm.start(m.id)
        #expect(await waitFor { if case .downloading = dm.states[m.id] { return true } else { return false } })
        dm.cancel(m.id)
        #expect(dm.states[m.id] == .notDownloaded)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(dm.states[m.id] == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: dm.folder(for: m.id).appendingPathComponent(".partial").path))
    }

    @Test func resumeDataSurvivesRestart() async {
        let files = [("a.bin", "hello"), ("b.bin", "world!")]; register(files)
        let m = model(files: files)
        let root = tempRoot()
        let first = FakeDownloader(bodyFor: bodyLookup(m)) { n, _ in
            if n == 2 { throw DownloadInterrupted(resumeData: Data("RD".utf8)) }
        }
        let dm = make(m, root: root, downloader: first)
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .paused(done: 5, total: 11) })

        let second = FakeDownloader(bodyFor: bodyLookup(m))
        let dm2 = make(m, root: root, downloader: second)
        #expect(dm2.states[m.id] == .paused(done: 5, total: 11))
        dm2.resume(m.id)
        #expect(await waitFor { dm2.states[m.id] == .ready })
        let calls = second.calls.withLock { $0.resumeData }
        #expect(calls == [Data("RD".utf8)])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(m.id).appendingPathComponent(".resume/b.bin.data").path))
    }

    @Test func checksumMismatchFails() async {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        let fake = FakeDownloader(bodyFor: { _ in "tampered" })
        let dm = make(m, root: tempRoot(), downloader: fake)
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .failed("The download was damaged. Try again.") })
        #expect(!FileManager.default.fileExists(atPath: dm.folder(for: m.id).appendingPathComponent("a.bin").path))
    }

    @Test func refusesWhenDiskTooSmall() async {
        let m = model(files: [("a.bin", "hello")], declaredBytes: 3_000_000_000)
        let dm = make(m, root: tempRoot(), downloader: FakeDownloader(bodyFor: { _ in "" }), free: 1_000_000_000)
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .failed("Not enough disk space: 3.3 GB needed, 1.0 GB free") })
    }

    @Test func progressThrottledTo4PerSecond() async {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        let fake = FakeDownloader(bodyFor: bodyLookup(m)) { _, progress in
            for i in 1...200 { progress(Int64(i % 5)); try await Task.sleep(for: .milliseconds(5)) }
        }
        let dm = make(m, root: tempRoot(), downloader: fake)
        let count = Mutex(0)
        let id = m.id
        let sub = dm.$states.sink { s in
            if case .downloading = s[id] { count.withLock { $0 += 1 } }
        }
        let t0 = Date()
        dm.start(id)
        #expect(await waitFor(15) { dm.states[id] == .ready })
        let elapsed = Date().timeIntervalSince(t0)
        sub.cancel()
        let n = count.withLock { $0 }
        #expect(n <= Int(elapsed / 0.25) + 3)
        #expect(n >= 1)
    }

    @Test func deleteRemovesFolder() async throws {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        let dm = make(m, root: tempRoot(), downloader: FakeDownloader(bodyFor: bodyLookup(m)))
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .ready })
        try dm.delete(m.id)
        #expect(dm.states[m.id] == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: dm.folder(for: m.id).path))
    }

    @Test func deleteRefusesPathOutsideRoot() throws {
        let root = tempRoot()
        let outside = root.deletingLastPathComponent().appendingPathComponent("dm-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let dm = make(model(), root: root)
        #expect(throws: DownloadError.self) { try dm.delete("../" + outside.lastPathComponent) }
        #expect(throws: DownloadError.self) { try dm.delete("") }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func filesWrittenWith0700Folder() async {
        let files = [("a.bin", "hello"), ("sub/b.bin", "world!")]; register(files)
        let m = model(files: files)
        let root = tempRoot()
        let dm = make(m, root: root, downloader: FakeDownloader(bodyFor: bodyLookup(m)))
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .ready })
        #expect(perms(root) == 0o700)
        #expect(perms(dm.folder(for: m.id)) == 0o700)
        #expect(perms(dm.folder(for: m.id).appendingPathComponent("sub")) == 0o700)
    }

    @Test func externalVerificationShowsVerifyingUntilRefresh() {
        let m = model(files: [("a.bin", "hello")])
        let dm = make(m, root: tempRoot())
        #expect(dm.states[m.id] == .notDownloaded)
        dm.beginExternalVerification([m.id, "unknown"])
        #expect(dm.states[m.id] == .verifying)
        #expect(dm.states["unknown"] == nil)
        dm.refresh()
        #expect(dm.states[m.id] == .notDownloaded)
    }

    @Test func readyDetectedAtInit() async {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        let root = tempRoot()
        let dm = make(m, root: root, downloader: FakeDownloader(bodyFor: bodyLookup(m)))
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .ready })
        #expect(make(m, root: root).states[m.id] == .ready)
        try? FileManager.default.removeItem(at: dm.folder(for: m.id).appendingPathComponent("a.bin"))
        #expect(make(m, root: root).states[m.id] == .notDownloaded)
    }

    @Test func endToEndThroughURLProtocol() async {
        let files = [("a.bin", "hello"), ("sub/b.bin", "world!")]; register(files)
        let m = model(files: files)
        for f in m.files { DMStubProtocol.set(f.url, .init(status: 200, body: Data(contents(m, f).utf8), error: nil)) }
        let dm = make(m, root: tempRoot(), session: DMStubProtocol.session())
        dm.start(m.id)
        #expect(await waitFor(10) { dm.states[m.id] == .ready })
        #expect((try? String(contentsOf: dm.folder(for: m.id).appendingPathComponent("sub/b.bin"), encoding: .utf8)) == "world!")
    }

    @Test func networkLossPausesNotFails() async {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        DMStubProtocol.set(m.files[0].url, .init(status: 200, body: Data(), error: URLError(.notConnectedToInternet)))
        let dm = make(m, root: tempRoot(), session: DMStubProtocol.session())
        dm.start(m.id)
        #expect(await waitFor(10) { dm.states[m.id] == .paused(done: 0, total: 5) })
    }

    @Test func httpErrorFailsWithCode() async {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        DMStubProtocol.set(m.files[0].url, .init(status: 503, body: Data("nope".utf8), error: nil))
        let dm = make(m, root: tempRoot(), session: DMStubProtocol.session())
        dm.start(m.id)
        #expect(await waitFor(10) { dm.states[m.id] == .failed("Download failed (HTTP 503). Try again.") })
    }

    @Test func restartWithFinishedFilesButNoResumeDataShowsPaused() async {
        let files = [("a.bin", "hello"), ("b.bin", "world!")]; register(files)
        let m = model(files: files)
        let root = tempRoot()
        let fake = FakeDownloader(bodyFor: bodyLookup(m)) { n, _ in
            if n == 2 { throw DownloadInterrupted(resumeData: nil) }
        }
        let dm = make(m, root: root, downloader: fake)
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .paused(done: 5, total: 11) })
        #expect(make(m, root: root).states[m.id] == .paused(done: 5, total: 11))
    }

    @Test func allFilesPresentWithoutVerifiedMarkerAreHashed() async throws {
        let files = [("a.bin", "hello"), ("b.bin", "world!")]; register(files)
        let m = model(files: files)
        let root = tempRoot()
        let dir = root.appendingPathComponent(m.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.bin"))
        try Data("WORLD!".utf8).write(to: dir.appendingPathComponent("b.bin"))  // same size, wrong content
        let fake = FakeDownloader(bodyFor: bodyLookup(m))
        let dm = make(m, root: root, downloader: fake)
        #expect(dm.states[m.id] == .paused(done: 11, total: 11))
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .ready })
        #expect(fake.calls.withLock { $0.resumeData.count } == 1)
        #expect((try? String(contentsOf: dir.appendingPathComponent("b.bin"), encoding: .utf8)) == "world!")
    }

    @Test(arguments: [URLError.Code.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed])
    func broaderNetworkLossPauses(code: URLError.Code) async {
        let files = [("a.bin", "hello")]; register(files)
        let m = model(files: files)
        let fake = FakeDownloader(bodyFor: bodyLookup(m)) { _, _ in throw DownloadInterrupted(resumeData: Data("RD".utf8)) }
        let dm = make(m, root: tempRoot(), downloader: fake)
        dm.start(m.id)
        #expect(await waitFor { dm.states[m.id] == .paused(done: 0, total: 5) })
        DMStubProtocol.set(m.files[0].url, .init(status: 200, body: Data(), error: URLError(code)))
        let dm2 = make(m, root: tempRoot(), session: DMStubProtocol.session())
        dm2.start(m.id)
        #expect(await waitFor(10) { dm2.states[m.id] == .paused(done: 0, total: 5) })
    }
}
