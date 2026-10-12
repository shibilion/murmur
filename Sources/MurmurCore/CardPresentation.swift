import Foundation

/// A model's download state as the card sees it (the engines module maps its own state onto this).
public enum CardState: Equatable, Sendable {
    case notDownloaded
    case downloading(done: Int64, total: Int64, bytesPerSec: Double)
    case paused(done: Int64, total: Int64)
    case failed(String)
    case verifying
    case preparing
    case ready
}

public enum CardButton: Equatable, Sendable {
    case download, cancel, resume, useThis, selected

    public var title: String {
        switch self {
        case .download: "Download"
        case .cancel: "Cancel"
        case .resume: "Resume"
        case .useThis: "Use this"
        case .selected: "Selected"
        }
    }
}

public struct CardPresentation: Equatable, Sendable {
    public let statusText: String
    public let primary: CardButton?
    /// Fraction 0...1 while downloading, else nil.
    public let progress: Double?
    /// True when the model is downloaded and usable (drives the green check).
    public let isReady: Bool

    /// `selectable` false hides "Use this"/"Selected" for ready models (cards with nothing to choose).
    public static func make(state: CardState, sizeBytes: Int64, selected: Bool, selectable: Bool = true) -> CardPresentation {
        switch state {
        case .notDownloaded:
            return CardPresentation(statusText: "\(bytes(sizeBytes)) · Download", primary: .download, progress: nil, isReady: false)
        case .downloading(let done, let total, let speed):
            var parts = ["\(bytes(done)) / \(bytes(total))"]
            if speed > 0 {
                parts.append(String(format: "%.1f MB/s", speed / 1_000_000))
                parts.append("\(eta(seconds: Double(max(total - done, 0)) / speed)) left")
            }
            let fraction = total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0
            return CardPresentation(statusText: parts.joined(separator: " · "), primary: .cancel, progress: fraction, isReady: false)
        case .paused(let done, let total):
            return CardPresentation(statusText: "Paused · \(bytes(done)) / \(bytes(total))", primary: .resume, progress: nil, isReady: false)
        case .failed(let reason):
            return CardPresentation(statusText: reason, primary: .download, progress: nil, isReady: false)
        case .verifying:
            return CardPresentation(statusText: "Checking download…", primary: nil, progress: nil, isReady: false)
        case .preparing:
            return CardPresentation(statusText: "Preparing… one-time", primary: nil, progress: nil, isReady: false)
        case .ready:
            return CardPresentation(statusText: "Ready", primary: selectable ? (selected ? .selected : .useThis) : nil, progress: nil, isReady: true)
        }
    }

    public static func bytes(_ n: Int64) -> String {
        if n <= 0 { return "0 MB" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    static func eta(seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded(.up)))
        return s >= 60 ? "\((s + 59) / 60) min" : "\(s) s"
    }
}
