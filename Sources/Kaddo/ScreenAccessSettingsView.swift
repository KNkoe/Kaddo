import SwiftUI
import AppKit

struct ScreenAccessSettingsView: View {
    @ObservedObject var controller: DesktopController
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(controller.screenAllowed ? "macOS screen access: allowed" : "macOS screen access: not granted", systemImage: controller.screenAllowed ? "checkmark.shield" : "hand.raised")
            Text("Active voice automatically shares screen context with Codex. End voice stops capture. Screen images stay in memory; spoken transcripts stay in your conversation.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Request screen access") { controller.requestScreenPermission() }.buttonStyle(KaddoButtonStyle(prominent: true))
                Button("Open macOS settings") { controller.openPrivacySettings() }
            }
            Button("Refresh status") { controller.refreshPermissions() }
            if let error = model.voiceScreenError {
                Text("Last capture error").font(.headline)
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("If macOS shows Kaddo as allowed but capture fails, turn its entry off and on, then choose Quit & Reopen. A stale entry may need to be removed and re-added using this app.").font(.caption).foregroundStyle(.secondary)
            Text(Bundle.main.bundleURL.path).font(.caption.monospaced()).textSelection(.enabled)
        }.buttonStyle(KaddoButtonStyle()).onAppear { controller.refreshPermissions() }
          .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshPermissions() }
    }
}
