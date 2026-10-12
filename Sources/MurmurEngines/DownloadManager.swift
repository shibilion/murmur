import Combine
import CryptoKit
import Foundation
import Synchronization
import MurmurCore

public enum DownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(done: Int64, total: Int64, bytesPerSec: Double)
    case paused(done: Int64, total: Int64)
    case failed(String)
    case verifying
    case preparing
    case ready
}

// MARK: - Downloader seam

/// Thrown by a `Downloader` when the transfer was interrupted by network loss.
public struct DownloadInterrupted: Error, Sendable {
    public let resumeData: Data?
    public init(resumeData: Data?) { self.resumeData = resumeData }

    static func isNetworkLoss(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .networkConnectionLost, .timedOut, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

public struct DownloadHTTPError: Error, Sendable, Equatable {
    public let code: Int
    public init(code: Int) { self.code = code }
}

public enum DownloadError: Error, Sendable { case outsideRoot }

public protocol Downloader: Sendable {
    /// Downloads `url` (continuing from `resumeData` when given) and returns a temp file the caller owns.
    /// `progress` receives cumulative bytes written for this file.
    func download(url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

final class URLSessionDownloader: Downloader, @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession) { self.session = session }

    func download(url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = TaskDelegate(progress: progress)
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await delegate.run(task)
        } onCancel: {
            delegate.cancel()
        }
    }

    private final class TaskDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private struct S {
            var cont: CheckedContinuation<URL, Error>?
            var task: URLSessionDownloadTask?
            var file: URL?
            var failure: Error?
            var cancelled = false
        }
        private let state = Mutex(S())
        private let progress: @Sendable (Int64) -> Void
        init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

        func run(_ task: URLSessionDownloadTask) async throws -> URL {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let cancelled = state.withLock { s -> Bool in s.cont = cont; s.task = task; return s.cancelled }
                if cancelled { finish(.failure(CancellationError())); return }
                task.delegate = self
                task.resume()
            }
        }

        func cancel() {
            let t = state.withLock { s -> URLSessionDownloadTask? in s.cancelled = true; return s.task }
            t?.cancel()
        }

        private func finish(_ r: Result<URL, Error>) {
            let c = state.withLock { s -> CheckedContinuation<URL, Error>? in let c = s.cont; s.cont = nil; return c }
            c?.resume(with: r)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
            if !(200..<300).contains(status) {
                state.withLock { $0.failure = DownloadHTTPError(code: status) }
                return
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-dl-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                state.withLock { $0.file = dest }
            } catch {
                state.withLock { $0.failure = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (failure, file) = state.withLock { ($0.failure, $0.file) }
            if let failure { finish(.failure(failure)); return }
            if let error {
                if let u = error as? URLError {
                    if u.code == .cancelled { finish(.failure(CancellationError())); return }
                    if DownloadInterrupted.isNetworkLoss(u.code) {
                        finish(.failure(DownloadInterrupted(resumeData: u.downloadTaskResumeData)))
                        return
                    }
                }
                finish(.failure(error))
                return
            }
            if let file { finish(.success(file)) } else { finish(.failure(URLError(.unknown))) }
        }
    }
}

enum FileHash {
    /// Streams the file through SHA-256 in 1 MB chunks.
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let more: Bool = try autoreleasepool {
                guard let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Manager

@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var states: [String: DownloadState] = [:]

    private let root: URL
    private let models: [String: CatalogModel]
    private let downloader: any Downloader
    private let freeSpace: () -> Int64
    private let fm = FileManager.default

    private struct Run { let token: UUID; let task: Task<Void, Never> }
    private var runs: [String: Run] = [:]
    private var lastPublish: [String: Date] = [:]
    private struct Tracker { var time: Date; var bytes: Int64; var speed: Double }
    private var trackers: [String: Tracker] = [:]
    private var activeFile: [String: (token: UUID, base: Int64, total: Int64)] = [:]

    public init(root: URL,
                session: URLSession = DownloadManager.defaultSession(),
                models: [CatalogModel] = ModelCatalog.all,
                downloader: (any Downloader)? = nil,
                freeSpace: @escaping () -> Int64) {
        self.root = root
        self.models = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        self.downloader = downloader ?? URLSessionDownloader(session: session)
        self.freeSpace = freeSpace
        for m in models { states[m.id] = diskState(m) }
    }

    nonisolated public static func defaultSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    // MARK: Public API

    public func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    public func start(_ id: String) {
        guard let model = models[id], runs[id] == nil else { return }
        switch states[id] ?? .notDownloaded {
        case .notDownloaded, .failed, .paused: launch(model)
        default: break
        }
    }

    public func resume(_ id: String) { start(id) }

    public func cancel(_ id: String) {
        runs[id]?.task.cancel()
        runs[id] = nil
        activeFile[id] = nil
        let f = folder(for: id)
        try? fm.removeItem(at: f.appendingPathComponent(".partial"))
        try? fm.removeItem(at: f.appendingPathComponent(".resume"))
        publish(id, .notDownloaded)
    }

    public func delete(_ id: String) throws {
        let target = folder(for: id).resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.hasPrefix(base + "/"), target != base else { throw DownloadError.outsideRoot }
        runs[id]?.task.cancel()
        runs[id] = nil
        activeFile[id] = nil
        try? fm.removeItem(atPath: target)
        publish(id, .notDownloaded)
    }

    /// Re-reads disk state (after a migration, say) for models with no run in flight.
    public func refresh() {
        for m in models.values where runs[m.id] == nil { publish(m.id, diskState(m)) }
    }

    /// Shows `ids` as verifying while something outside the manager (a migration) is hashing their files.
    /// Call `refresh()` afterwards to read the real state back.
    public func beginExternalVerification(_ ids: [String]) {
        for id in ids where runs[id] == nil && models[id] != nil && states[id] != .ready { publish(id, .verifying) }
    }

    public func markPreparing(_ id: String) { publish(id, .preparing) }
    public func markReady(_ id: String) { publish(id, .ready) }
    public func markFailed(_ id: String, _ reason: String) { publish(id, .failed(reason)) }

    // MARK: State plumbing

    private func publish(_ id: String, _ s: DownloadState) {
        states[id] = s
        lastPublish[id] = nil
    }

    private func fileProgress(_ id: String, token: UUID, bytes: Int64) {
        guard let a = activeFile[id], a.token == token, runs[id]?.token == token else { return }
        let now = Date()
        var t = trackers[id] ?? Tracker(time: now, bytes: 0, speed: 0)
        let dt = now.timeIntervalSince(t.time)
        if dt > 0 {
            let inst = Double(bytes - t.bytes) / dt
            let alpha = 1 - exp(-dt / 2.0)
            t.speed = t.speed == 0 ? inst : t.speed + alpha * (inst - t.speed)
            t.time = now
            t.bytes = bytes
            trackers[id] = t
        }
        if let last = lastPublish[id], now.timeIntervalSince(last) < 0.25 { return }
        publish(id, .downloading(done: a.base + bytes, total: a.total, bytesPerSec: t.speed))
        lastPublish[id] = now
    }

    // MARK: Disk layout

    private func sanitised(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "__") }
    private func finalURL(_ m: CatalogModel, _ f: ModelFile) -> URL { folder(for: m.id).appendingPathComponent(f.relativePath) }
    private func partialURL(_ m: CatalogModel, _ f: ModelFile) -> URL {
        folder(for: m.id).appendingPathComponent(".partial").appendingPathComponent(sanitised(f.relativePath))
    }
    private func resumeURL(_ m: CatalogModel, _ f: ModelFile) -> URL {
        folder(for: m.id).appendingPathComponent(".resume").appendingPathComponent(sanitised(f.relativePath) + ".data")
    }
    private func verifiedURL(_ m: CatalogModel) -> URL { folder(for: m.id).appendingPathComponent(".verified") }

    private func listHash(_ m: CatalogModel) -> String { ModelVerification.listHash(m) }

    private func isFinished(_ m: CatalogModel, _ f: ModelFile) -> Bool {
        let attrs = try? fm.attributesOfItem(atPath: finalURL(m, f).path)
        return (attrs?[.size] as? NSNumber)?.int64Value == f.bytes
    }

    private func diskState(_ m: CatalogModel) -> DownloadState {
        let finished = m.files.filter { isFinished(m, $0) }
        if finished.count == m.files.count,
           let v = try? String(contentsOf: verifiedURL(m), encoding: .utf8), v == listHash(m) {
            return .ready
        }
        let f = folder(for: m.id)
        func nonEmpty(_ name: String) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: f.appendingPathComponent(name).path)) ?? []).isEmpty == false
        }
        if !finished.isEmpty || nonEmpty(".resume") || nonEmpty(".partial") {
            return .paused(done: finished.reduce(0) { $0 + $1.bytes }, total: m.sizeBytes)
        }
        return .notDownloaded
    }

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    // MARK: Run

    private func launch(_ m: CatalogModel) {
        let token = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.run(m, token: token)
        }
        runs[m.id] = Run(token: token, task: task)
    }

    private func isCurrent(_ id: String, _ token: UUID) -> Bool { runs[id]?.token == token }

    private func fail(_ m: CatalogModel, _ token: UUID, _ msg: String) {
        guard isCurrent(m.id, token) else { return }
        activeFile[m.id] = nil
        runs[m.id] = nil
        publish(m.id, .failed(msg))
    }

    private static func gb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000_000) }

    private func run(_ m: CatalogModel, token: UUID) async {
        let id = m.id
        let total = m.sizeBytes
        // All files present but no valid .verified marker: hash them before trusting them.
        let markerOK = (try? String(contentsOf: verifiedURL(m), encoding: .utf8)) == listHash(m)
        if !markerOK, m.files.allSatisfy({ isFinished(m, $0) }) {
            publish(id, .verifying)
            for file in m.files {
                let url = finalURL(m, file)
                let actual = try? await Task.detached { try FileHash.sha256(of: url) }.value
                guard isCurrent(id, token) else { return }
                if actual != file.sha256 { try? fm.removeItem(at: url) }
            }
        }
        let pending = m.files.filter { !isFinished(m, $0) }
        var finished = total - pending.reduce(0) { $0 + $1.bytes }
        let remaining = total - finished

        let needed = Int64(Double(remaining) * 1.1)
        let free = freeSpace()
        if free < needed {
            fail(m, token, "Not enough disk space: \(Self.gb(needed)) GB needed, \(Self.gb(free)) GB free")
            return
        }
        do {
            try mkdir(root)
            try mkdir(folder(for: id))
        } catch {
            fail(m, token, "Couldn't create the model folder. Try again.")
            return
        }
        publish(id, .downloading(done: finished, total: total, bytesPerSec: 0))

        for (i, file) in pending.enumerated() {
            guard isCurrent(id, token) else { return }
            let isLast = i == pending.count - 1
            let resumeFile = resumeURL(m, file)
            let resumeData = try? Data(contentsOf: resumeFile)
            trackers[id] = Tracker(time: Date(), bytes: 0, speed: 0)
            activeFile[id] = (token, finished, total)

            let tmp: URL
            do {
                tmp = try await downloader.download(url: file.url, resumeData: resumeData) { [weak self] bytes in
                    Task { @MainActor in self?.fileProgress(id, token: token, bytes: bytes) }
                }
            } catch {
                handleDownloadError(error, m, file, token, finished: finished, hadResume: resumeData != nil)
                return
            }
            activeFile[id] = nil
            guard isCurrent(id, token) else { try? fm.removeItem(at: tmp); return }
            try? fm.removeItem(at: resumeFile)

            // Move into .partial, verify, then move into place.
            let partial = partialURL(m, file)
            do {
                try mkdir(partial.deletingLastPathComponent())
                try? fm.removeItem(at: partial)
                try fm.moveItem(at: tmp, to: partial)
            } catch {
                fail(m, token, "Download failed. Try again.")
                return
            }
            if isLast { publish(id, .verifying) }
            let expected = file.sha256
            let actual = try? await Task.detached { try FileHash.sha256(of: partial) }.value
            guard isCurrent(id, token) else { return }
            guard actual == expected else {
                try? fm.removeItem(at: partial)
                fail(m, token, "The download was damaged. Try again.")
                return
            }
            let dest = finalURL(m, file)
            do {
                try mkdir(dest.deletingLastPathComponent())
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: partial, to: dest)
            } catch {
                fail(m, token, "Download failed. Try again.")
                return
            }
            finished += file.bytes
        }

        guard isCurrent(id, token) else { return }
        do {
            try listHash(m).write(to: verifiedURL(m), atomically: true, encoding: .utf8)
        } catch {
            fail(m, token, "Download failed. Try again.")
            return
        }
        try? fm.removeItem(at: folder(for: id).appendingPathComponent(".partial"))
        try? fm.removeItem(at: folder(for: id).appendingPathComponent(".resume"))
        runs[id] = nil
        publish(id, .ready)
    }

    private func handleDownloadError(_ error: Error, _ m: CatalogModel, _ file: ModelFile, _ token: UUID,
                                     finished: Int64, hadResume: Bool) {
        guard isCurrent(m.id, token) else { return }
        activeFile[m.id] = nil
        if error is CancellationError { return }

        var interrupted: DownloadInterrupted?
        if let e = error as? DownloadInterrupted { interrupted = e }
        else if let u = error as? URLError, DownloadInterrupted.isNetworkLoss(u.code) { interrupted = DownloadInterrupted(resumeData: nil) }

        if let interrupted {
            if let data = interrupted.resumeData {
                let url = resumeURL(m, file)
                try? mkdir(url.deletingLastPathComponent())
                try? data.write(to: url, options: .atomic)
            }
            runs[m.id] = nil
            publish(m.id, .paused(done: finished, total: m.sizeBytes))
            return
        }
        if hadResume { try? fm.removeItem(at: resumeURL(m, file)) }
        if let h = error as? DownloadHTTPError {
            fail(m, token, "Download failed (HTTP \(h.code)). Try again.")
        } else {
            fail(m, token, "Download failed. Try again.")
        }
    }
}
