import AppKit
import MurmurCore
import SwiftUI

// MARK: - Per-app rules

struct RulesSection: View {
    @Bindable var model: SettingsModel
    @State private var selected: String?

    var body: some View {
        Form {
            Section {
                if model.settings.rules.isEmpty {
                    Text("No rules yet.").foregroundStyle(.secondary)
                }
                List(selection: $selected) {
                    ForEach(Array(model.settings.rules.enumerated()), id: \.element.bundleId) { index, rule in
                        ruleRow(index: index, rule: rule).tag(rule.bundleId)
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Button("Add current app…") { model.addCapturedAppRule() }
                        .disabled(model.capturedApp == nil)
                    Button("−") {
                        if let selected { model.settings.rules.removeAll { $0.bundleId == selected } }
                        selected = nil
                    }
                    .disabled(selected == nil)
                    .help("Remove the selected rule")
                    if let app = model.capturedApp {
                        Text(app.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func ruleRow(index: Int, rule: AppRule) -> some View {
        let rules = $model.settings.rules
        let force = Binding<String>(
            get: { rule.force?.rawValue ?? "default" },
            set: { v in if rules.wrappedValue.indices.contains(index) { rules.wrappedValue[index].force = AppRule.Force(rawValue: v) } }
        )
        let tone = Binding<String>(
            get: { rule.tone?.rawValue ?? "default" },
            set: { v in if rules.wrappedValue.indices.contains(index) { rules.wrappedValue[index].tone = v == "default" ? nil : Tone(rawValue: v) } }
        )
        let cleanupOff = Binding<Bool>(
            get: { rule.cleanupOff },
            set: { v in if rules.wrappedValue.indices.contains(index) { rules.wrappedValue[index].cleanupOff = v } }
        )
        return HStack {
            Text(SettingsModel.appName(forBundleId: rule.bundleId)).frame(minWidth: 110, alignment: .leading)
            Spacer()
            Picker("Force", selection: force) {
                Text("Default").tag("default")
                Text("Local").tag("local")
                Text("Cloud").tag("cloud")
            }.frame(width: 140)
            Toggle("Cleanup off", isOn: cleanupOff)
            Picker("Tone", selection: tone) {
                Text("Default").tag("default")
                Text("Casual").tag("casual")
                Text("Formal").tag("formal")
            }.frame(width: 140)
        }
    }
}

// MARK: - Dictionary

struct DictionarySection: View {
    @Bindable var model: SettingsModel
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add a word", text: $newWord).onSubmit(add)
                    Button("Add", action: add).disabled(trimmed.isEmpty)
                }
            }
            Section {
                if model.settings.dictionary.isEmpty { Text("No words yet.").foregroundStyle(.secondary) }
                ForEach(Array(model.settings.dictionary.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("Word", text: Binding(
                            get: { model.settings.dictionary.indices.contains(index) ? model.settings.dictionary[index] : "" },
                            set: { if model.settings.dictionary.indices.contains(index) { model.settings.dictionary[index] = $0 } }
                        ))
                            .labelsHidden()
                        Button("Remove") { model.settings.dictionary.remove(at: index) }
                    }
                }
            }
        }
    }

    private var trimmed: String { newWord.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        guard !trimmed.isEmpty, !model.settings.dictionary.contains(trimmed) else { newWord = ""; return }
        model.settings.dictionary.append(trimmed)
        newWord = ""
    }
}

// MARK: - Snippets and replacements

struct SnippetsSection: View {
    @Bindable var model: SettingsModel
    @State private var rows: [ReplacementRow] = []

    struct ReplacementRow: Identifiable {
        let id = UUID()
        var from: String
        var to: String
    }

    var body: some View {
        Form {
            Section("Snippets") {
                ForEach(Array(model.settings.snippets.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("When I say", text: Binding(
                            get: { model.settings.snippets.indices.contains(index) ? model.settings.snippets[index].trigger : "" },
                            set: { if model.settings.snippets.indices.contains(index) { model.settings.snippets[index].trigger = $0 } }
                        ))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Insert", text: Binding(
                            get: { model.settings.snippets.indices.contains(index) ? model.settings.snippets[index].expansion : "" },
                            set: { if model.settings.snippets.indices.contains(index) { model.settings.snippets[index].expansion = $0 } }
                        ))
                        Button("Remove") { model.settings.snippets.remove(at: index) }
                    }
                }
                Button("Add snippet") { model.settings.snippets.append(Snippet(trigger: "", expansion: "")) }
            }
            Section("Replacements") {
                ForEach($rows) { $row in
                    HStack {
                        TextField("Replace", text: $row.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("With", text: $row.to)
                        Button("Remove") { rows.removeAll { $0.id == row.id } }
                    }
                }
                Button("Add replacement") { rows.append(ReplacementRow(from: "", to: "")) }
            }
        }
        .onAppear {
            rows = model.settings.replacements.sorted { $0.key < $1.key }.map { ReplacementRow(from: $0.key, to: $0.value) }
        }
        .onChange(of: rows.map { [$0.from, $0.to] }) {
            // Rows with an empty "Replace" are drafts and are not saved.
            var dict: [String: String] = [:]
            for r in rows where !r.from.isEmpty { dict[r.from] = r.to }
            if dict != model.settings.replacements { model.settings.replacements = dict }
        }
    }
}

// MARK: - History

struct HistorySection: View {
    let history: any HistoryStoring
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Kept for 7 days.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear history") { confirmClear() }.disabled(entries.isEmpty)
                }
            }
            Section {
                if entries.isEmpty { Text("No dictations yet.").foregroundStyle(.secondary) }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    DisclosureGroup {
                        HStack(alignment: .top) {
                            Text(entry.raw).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            Button("Copy raw") { copy(entry.raw) }
                        }
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.final).lineLimit(2)
                                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(SettingsModel.appName(forBundleId: entry.appBundleId))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Copy") { copy(entry.final) }
                        }
                    }
                }
            }
        }
        .task { entries = await history.recent(100) }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear history?"
        alert.informativeText = "This removes all saved dictations from this Mac."
        alert.addButton(withTitle: "Clear history")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await history.clear()
            entries = await history.recent(100)
        }
    }
}
