import MurmurCore
import SwiftUI

struct CloudSection: View {
    @Bindable var model: SettingsModel
    let secrets: any SecretStoring

    var body: some View {
        Form {
            Section {
                Toggle("Cloud boost", isOn: $model.settings.cloudBoost)
            }
            Section("API keys") {
                KeyRow(title: "Anthropic", account: "anthropic", secrets: secrets)
                KeyRow(title: "Groq", account: "groq", secrets: secrets)
                KeyRow(title: "Sarvam", account: "sarvam", secrets: secrets)
            }
            Section("Sarvam") {
                TextField("Sarvam model", text: $model.settings.sarvamModel)
                Text(SettingsCopy.sarvamNote).font(.caption).foregroundStyle(.secondary)
            }
            Section("What gets sent") {
                Text(SettingsCopy.cloudSent).foregroundStyle(.secondary)
            }
        }
    }
}

/// A stored key is never read back into the UI: the row only knows whether one exists.
struct KeyRow: View {
    let title: String
    let account: String
    let secrets: any SecretStoring

    @State private var isSaved = false
    @State private var draft = ""

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(isSaved ? "Saved" : "Not set").foregroundStyle(.secondary)
                SecureField("Paste key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .labelsHidden()
                Button("Save") {
                    let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    secrets.set(account, key)
                    draft = ""
                    isSaved = true
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") {
                    secrets.set(account, nil)
                    isSaved = false
                }
                .disabled(!isSaved)
            }
        }
        .onAppear { isSaved = secrets.get(account)?.isEmpty == false }
    }
}
