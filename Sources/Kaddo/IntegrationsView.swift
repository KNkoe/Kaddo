import SwiftUI
import Foundation

struct IntegrationsView: View {
    @ObservedObject var store: IntegrationStore
    var onAddToChat: (String) -> Void
    @State private var query = ""
    @State private var slug = ""
    @State private var arguments = "{}"
    @State private var values: [String: String] = [:]
    @State private var account = ""
    @State private var approval = false
    @State private var formError: String?
    @State private var reconnectItem: IntegrationConnection?
    @State private var showAuthorization = false
    private var usableAccount: Bool { store.connectionsVerified && store.connections.contains { $0.id == account && $0.health == .connected } }
    private var actionName: String { store.tools.first(where: { $0.slug == store.selectedSlug })?.name ?? store.selectedSlug }
    private var setupCommands: String {
        let path = ComposioTransport.discover()?.path ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".composio/composio").path
        return "\(path) login\n\(path) link gmail"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Your apps", systemImage: "puzzlepiece.extension").font(.title2.bold())
                    Spacer()
                    if store.busy { ProgressView().controlSize(.small); Button("Cancel") { store.cancel() } }
                    Button("Refresh") { Task { await store.refresh() } }.disabled(store.busy)
                }
                Text("Find an action, fill in the details, then review it before Kaddo runs it.").foregroundStyle(.secondary)
                if let error = store.error {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                        if error.localizedCaseInsensitiveContains("key") || error.localizedCaseInsensitiveContains("auth") {
                            Text("The connection manager needs attention. Use Connection setup below to refresh its sign-in, then tap Refresh.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Connected apps").font(.headline)
                    Spacer()
                    if let checked = store.connectionsCheckedAt, store.connectionsVerified {
                        Text("Checked \(checked, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = store.connectionRefreshError {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if store.connections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.busy ? "Checking your apps…" : "No connected apps yet").font(.callout.weight(.semibold))
                        Text("Your app accounts and their connection status will appear here. Use Connection setup below to add an app.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(store.connections) { item in
                            IntegrationAccountCard(item: item, selected: account == item.id,
                                verified: store.connectionsVerified, busy: store.busy,
                                select: { account = item.id },
                                reconnect: { reconnectItem = item; showAuthorization = true; store.clearAuthorization() })
                        }
                    }
                    Text("Select a connected account for the action below. Connection status comes from your app provider through Composio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("What would you like to do? Search email, calendar, files…", text: $query).textFieldStyle(KaddoTextFieldStyle()).onSubmit { search() }
                    Button("Find actions") { search() }.disabled(store.busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if store.hasSearched && store.tools.isEmpty && !store.busy { Text("No matching actions were returned. Try a more specific request or Advanced action lookup.").font(.caption).foregroundStyle(.secondary) }
                if !store.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.tools) { tool in
                            Button { choose(tool.slug) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: store.selectedSlug == tool.slug ? "checkmark.circle.fill" : "circle").padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tool.name).font(.headline)
                                        Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    Spacer()
                                }.padding(12).contentShape(Rectangle())
                                    .background(store.selectedSlug == tool.slug ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
                            }.buttonStyle(.plain).disabled(store.busy)
                        }
                    }
                }
                if !store.schemaText.isEmpty {
                    Divider()
                    Text(actionName).font(.headline)
                    if let fields = store.formFields {
                        ForEach(fields.filter(\.isSimple)) { field in simpleField(field) }
                        if fields.contains(where: { !$0.isSimple }) {
                            Text("This action includes structured details. Add them under Advanced request data.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("This action uses structured request data. Open Advanced request data and follow its input schema.").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Advanced request data") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.formFields == nil ? "Request details as JSON" : "Additional structured details as JSON. Fields above take precedence.").font(.caption).foregroundStyle(.secondary)
                            KaddoTextEditor(text: $arguments, monospaced: true).frame(height: 132).accessibilityLabel("Advanced request JSON")
                            DisclosureGroup("View input schema") {
                                Text(store.schemaText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 8)
                    }
                    if let formError { Text(formError).foregroundStyle(.orange) }
                    HStack {
                        Button("Review action") { preview() }.buttonStyle(KaddoButtonStyle(prominent: true)).disabled(store.busy || !usableAccount)
                        Spacer()
                        Button("Approve & run…") { approval = true }.disabled(store.busy || !usableAccount || store.previewText.isEmpty)
                    }
                }
                if !store.previewText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Review the exact request").font(.headline)
                        Text(store.previewText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
                }
                if !store.resultText.isEmpty {
                    HStack { Text("Result").font(.headline); Spacer(); Button("Add result to chat") { onAddToChat("Integration result from \(store.selectedSlug):\n\(store.resultText)") } }
                    Text(store.resultText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                DisclosureGroup("Connection setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use Reconnect on an existing app to sign in again. To add another app, use the connection command below in Terminal, then tap Refresh. Credentials stay with your local Composio connection manager.").font(.caption).foregroundStyle(.secondary)
                        Text(setupCommands).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Other apps include googlecalendar, googledrive, and github. Replace gmail with the app you want to connect.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                DisclosureGroup("Advanced action lookup") {
                    HStack {
                        TextField("Exact action identifier", text: $slug).textFieldStyle(KaddoTextFieldStyle())
                        Button("Load action") { choose(slug) }.disabled(store.busy)
                    }.padding(.top, 8)
                }
            }.padding(24)
        }.buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: arguments) { _, _ in invalidate() }
            .onChange(of: values) { _, _ in invalidate() }
            .onChange(of: account) { _, _ in invalidate() }
            .onChange(of: slug) { _, _ in invalidate() }
            .confirmationDialog("Run \(actionName)?", isPresented: $approval) {
                Button("Run approved action") { Task { await store.executeApproved() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Kaddo will use the exact account and details in the review. This action may change data or send messages. Check recipients and content before approving.") }
            .task {
                await store.refresh()
                chooseUsableAccount()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await store.refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await store.refresh(); chooseUsableAccount() }
            }
            .onChange(of: store.connections) { _, _ in chooseUsableAccount() }
            .sheet(isPresented: $showAuthorization) { authorizationSheet }

    }
    @ViewBuilder private func simpleField(_ field: IntegrationField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(field.label + (field.required ? " *" : "")).font(.callout.weight(.medium))
            if field.type == "boolean" {
                KaddoSegmentedPicker(title: field.label, selection: valueBinding(field),
                    options: (field.required ? [] : [("", "Not specified")]) + [("true", "Yes"), ("false", "No")])
            } else if !field.choices.isEmpty {
                KaddoMenuPicker(title: field.label, selection: valueBinding(field),
                    options: [("", "Choose…")] + field.choices.map { ($0, $0) })
            } else {
                TextField(field.type == "integer" || field.type == "number" ? "Enter a number" : field.label, text: valueBinding(field), axis: .vertical).lineLimit(1...5).textFieldStyle(KaddoTextFieldStyle())
            }
            if !field.description.isEmpty { Text(field.description).font(.caption).foregroundStyle(.secondary) }
        }.disabled(store.busy)
    }
    private func valueBinding(_ field: IntegrationField) -> Binding<String> {
        Binding(get: { values[field.key] ?? field.initialValue }, set: { values[field.key] = $0 })
    }
    private func chooseUsableAccount() {
        if let connection = store.authorizedConnection {
            account = connection.id
        } else if !store.connections.contains(where: { $0.id == account && $0.health == .connected }) {
            account = store.connections.first(where: { $0.health == .connected })?.id ?? ""
        }
    }
    private var authorizationSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IntegrationAppIcon(toolkit: reconnectItem?.toolkit ?? "")
                Text("Reconnect \(reconnectItem?.displayName ?? "app")").font(.title2.bold())
                Spacer()
                Button("Close") { showAuthorization = false }.disabled(store.busy)
            }
            Text("Sign in to the account you want Kaddo to use. Your existing connections stay available; this creates a fresh authorization.").foregroundStyle(.secondary)
            if let item = reconnectItem { Text("Previous account: \(item.alias)").font(.caption).foregroundStyle(.secondary) }
            if store.authorizedAccountIsActive {
                Label("Connected and ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Use this account") { chooseUsableAccount(); showAuthorization = false }
                    .buttonStyle(KaddoButtonStyle(prominent: true))
            } else if let authorization = store.authorization {
                Text("Continue sign-in, then check the connection. Kaddo will only mark it connected after the provider confirms it.").font(.callout)
                Link("Continue in browser", destination: authorization.url).buttonStyle(KaddoButtonStyle(prominent: true))
                Button("Check connection") { Task { await store.refresh(); chooseUsableAccount() } }.disabled(store.busy)
            } else {
                Button("Start secure sign-in") {
                    guard let item = reconnectItem else { return }
                    Task { await store.beginAuthorization(for: item) }
                }.buttonStyle(KaddoButtonStyle(prominent: true)).disabled(store.busy)
            }
            if store.busy { ProgressView().controlSize(.small) }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(24).frame(width: 460).buttonStyle(KaddoButtonStyle())
    }
    private func invalidate() { formError = nil; store.invalidatePreview() }
    private func choose(_ selected: String) {
        slug = selected; arguments = "{}"; values = [:]; formError = nil
        Task { await store.select(toolSlug: selected) }
    }
    private func preview() {
        do {
            let json = try IntegrationForm.encode(fields: store.formFields ?? [], values: values, advancedJSON: arguments)
            Task { await store.preparePreview(argumentsJSON: json, account: account) }
        } catch { formError = error.localizedDescription }
    }
    private func search() { Task { await store.search(query) } }
}
