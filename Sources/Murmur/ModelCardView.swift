import MurmurCore
import MurmurEngines
import SwiftUI

extension DownloadState {
    /// The card's view of this state (the pure presentation lives in MurmurCore).
    var cardState: CardState {
        switch self {
        case .notDownloaded: .notDownloaded
        case .downloading(let d, let t, let s): .downloading(done: d, total: t, bytesPerSec: s)
        case .paused(let d, let t): .paused(done: d, total: t)
        case .failed(let m): .failed(m)
        case .verifying: .verifying
        case .preparing: .preparing
        case .ready: .ready
        }
    }
}

/// A small horizontal meter for the fixed accuracy and speed values.
private struct Meter: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Capsule().fill(.quaternary)
                .frame(width: 70, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor).frame(width: 70 * min(max(value, 0), 1), height: 5)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// One selectable card: a catalog model, or a provider without a download (Apple Intelligence, None).
struct ModelCardView: View {
    var name: String
    var blurb: String
    var languages: String?
    var accuracy: Double?
    var speed: Double?
    var recommended = false
    var selected = false
    var status: String
    var statusIsError = false
    var progress: Double?
    var isReady = false
    var caption: String?
    var button: CardButton?
    var onButton: (CardButton) -> Void = { _ in }
    /// A second, plain action (for example "Open Settings" or Delete).
    var secondaryTitle: String?
    var onSecondary: () -> Void = {}
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.headline)
                if recommended {
                    Text("Recommended").font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                if let languages { Text(languages).font(.caption).foregroundStyle(.secondary) }
            }
            Text(blurb).font(.callout).foregroundStyle(.secondary)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            if accuracy != nil || speed != nil {
                HStack(spacing: 16) {
                    if let accuracy { Meter(label: "Accuracy", value: accuracy) }
                    if let speed { Meter(label: "Speed", value: speed) }
                }
            }
            if let progress { ProgressView(value: progress) }
            HStack {
                if isReady {
                    Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text(status).foregroundStyle(statusIsError ? Color.red : Color.secondary)
                }
                Spacer()
                if let secondaryTitle { Button(secondaryTitle, action: onSecondary) }
                if let button {
                    Button(button.title) { onButton(button) }
                        .disabled(button == .selected)
                        .buttonStyle(.bordered)
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
        )
        .opacity(dimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension ModelCardView {
    /// A card for a downloadable catalog model.
    init(model: CatalogModel, state: DownloadState?, selected: Bool, selectable: Bool = true, caption: String? = nil,
         onButton: @escaping (CardButton) -> Void, onDelete: (() -> Void)? = nil) {
        let s = state ?? .notDownloaded
        let p = CardPresentation.make(state: s.cardState, sizeBytes: model.sizeBytes, selected: selected, selectable: selectable)
        var failed = false
        if case .failed = s { failed = true }
        var deletable = false
        switch s {
        case .ready, .failed: deletable = onDelete != nil
        default: break
        }
        self.init(name: model.name, blurb: model.blurb, languages: model.languages,
                  accuracy: model.accuracy, speed: model.speed, recommended: model.recommended,
                  selected: selected, status: p.statusText, statusIsError: failed, progress: p.progress, isReady: p.isReady, caption: caption,
                  button: p.primary, onButton: onButton,
                  secondaryTitle: deletable ? "Delete" : nil, onSecondary: { onDelete?() })
    }
}

/// Shared by Get started and Settings: what each card button does for a catalog model.
@MainActor
enum ModelCardActions {
    static func perform(_ button: CardButton, id: String, models: DownloadManager, use: () -> Void) {
        switch button {
        case .download, .resume: models.start(id)
        case .cancel: models.cancel(id)
        case .useThis: use()
        case .selected: break
        }
    }

    static func confirmDelete(_ model: CatalogModel, models: DownloadManager) {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.name)? You can download it again later."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? models.delete(model.id)
    }
}
