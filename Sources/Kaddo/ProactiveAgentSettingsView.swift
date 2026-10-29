import SwiftUI

struct ProactiveAgentSettingsView: View {
    @ObservedObject var controller: ProactiveAgentsController
    @ObservedObject var screenSource: ProactiveScreenSource
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if controller.isTestingAutomaticSuggestions { Text(controller.testAgentStartsPermitted ? "Automatic suggestions QA · isolated archive · 6 checks maximum · one explicit agent Start allowed" : "Automatic suggestions QA · isolated archive · 6 checks maximum · agent starts disabled").font(.caption).foregroundStyle(.orange) }
            Text("Proactive agents").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Kaddo looks for useful next steps from recent conversations and your current context, then brings you a short list of ideas.").foregroundStyle(.secondary)
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Suggest helpful tasks").fontWeight(.semibold)
                        Text("Checks in the background while Kaddo is running. Tasks start when you choose Start.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Suggest helpful tasks", isOn: $controller.enabled).labelsHidden().toggleStyle(.switch)
                }
                Divider().overlay(.white.opacity(0.06))
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use screen context").fontWeight(.semibold)
                        Text("Includes locally recognized screen text with recent history in Codex discovery. Screenshots are not retained or sent for these checks.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Use screen context", isOn: $controller.useScreenContext).labelsHidden().toggleStyle(.switch).disabled(!controller.enabled)
                }
            }.disabled(controller.settingsLoadFailed).padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 8) {
                Text("Screen source").font(.callout.weight(.medium))
                HStack {
                    KaddoMenuPicker(title: "Screen source", selection: $screenSource.selectedAppID, options: screenSource.sourceOptions)
                    Button("Refresh apps") { screenSource.refreshApplications() }
                }
                Text("Follow the active app, or keep a specific app in context while you talk to Kaddo. A pinned app stays in context on another desktop. If image capture is unavailable, Kaddo uses the source app’s accessible window text.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!controller.enabled || !controller.useScreenContext || controller.settingsLoadFailed)
            if controller.settingsLoadFailed {
                Text("Restore the saved suggestion settings, then reload. Background discovery and screen context remain paused.").font(.caption).foregroundStyle(.orange)
                Button("Reload suggestion settings") { controller.reloadSettings() }
            }
            HStack(spacing: 10) {
                Button(controller.checking ? "Checking…" : "Check now") { Task { await controller.checkNow() } }.disabled(!controller.enabled || controller.checking)
                Button("Review suggestions · \(controller.pendingCount)") { controller.showSuggestions() }
            }
            Text(controller.contextSummary).font(.caption).foregroundStyle(.secondary)
            if let diagnostic = controller.screenDiagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
            if let last = controller.lastChecked { Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary) }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.onAppear { screenSource.refreshApplications() }
            .onChange(of: screenSource.selectedAppID) { _, _ in controller.screenSourceChanged() }
            .buttonStyle(KaddoButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
    }
}
