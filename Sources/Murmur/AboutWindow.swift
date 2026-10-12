import AppKit
import MurmurCore
import SwiftUI

/// Lazily created, reused About window. Activating the app is allowed here (never for the overlay).
@MainActor
final class AboutWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = AboutView()
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "About Murmur"
            w.styleMask = [.titled, .closable]
            w.setContentSize(NSSize(width: 340, height: 400))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            // App icon and name
            VStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                }
                Text("Murmur")
                    .font(.title)
                    .fontWeight(.semibold)
            }
            .padding(.top, 20)

            // Version
            Text(versionText)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Tagline
            Text(AboutCopy.tagline)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            // Developer
            Text("Developed by **\(AboutCopy.developer)**")
                .font(.body)

            // Website link
            Link(destination: AboutCopy.websiteURL) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text(AboutCopy.websiteLabel)
                }
            }

            // Credits
            Text(AboutCopy.credits)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Licences") {
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionText: String {
        let bundle = Bundle.main
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let buildVersion = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(shortVersion) (build \(buildVersion))"
    }
}
