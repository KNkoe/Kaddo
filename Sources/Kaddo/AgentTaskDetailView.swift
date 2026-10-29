import SwiftUI
import AppKit

struct AgentTaskDetailView: View {
    @ObservedObject var store: AgentJobStore
    let jobID: UUID
    var helper: HelperProfile? = nil
    var helperIsMain = false
    @Environment(\.dismiss) private var dismiss
    @State private var followUp = ""
    @State private var sendingError: String?
    @State private var previewError: String?
    @State private var showsFullResponse = false
    @State private var showsHistory = false
    @State private var showsActivity = false
    @State private var showsDetails = false
    @State private var showsRequest = false
    @State private var showsSupportingFiles = false
    @State private var showsMoreFiles = false
    @State private var showsResponse = false
    private var job: AgentJob? { store.jobs.first { $0.id == jobID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job {
                header(job)
                Divider()
                if job.state == .running { AgentExecutionStatusView(job: job) }
                // Approvals and stop controls stay visible; disclosures never gate them.
                AgentComputerControls(computer: store.computer, onlyJob: jobID, cancel: { store.cancel($0) })
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        latestResult(job)
                        files(job)
                        if let previewError { Text(previewError).font(.callout).foregroundStyle(.orange) }
                        DisclosureGroup("Details", isExpanded: $showsDetails) {
                            if showsDetails {
                                VStack(alignment: .leading, spacing: 14) {
                                    supportingFiles(job)
                                    request(job)
                                    history(job)
                                    activity(job)
                                }.padding(.top, 10)
                            }
                        }.font(.callout)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                Divider()
                composer(job)
            } else {
                HStack { Text("Task unavailable").font(.title3.bold()); Spacer(); Button("Done") { dismiss() } }
                Text("This task is no longer available.").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle())
        .padding(22).frame(minWidth: 600, idealWidth: 680, minHeight: 500, idealHeight: 640)
    }

    private func header(_ job: AgentJob) -> some View {
        HStack(spacing: 12) {
            AgentAvatar(profile: helper ?? HelperProfile(id: job.helperID, name: job.helperName, instructions: job.helperInstructions), size: 48, isMain: helperIsMain)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.title3.bold()).lineLimit(2)
                HStack(spacing: 7) {
                    Text(job.helperName)
                    Text("·").accessibilityHidden(true)
                    Text(AgentTaskPresentation.statusLabel(for: job)).foregroundStyle(needsAttention(job) ? Color.orange : Color.secondary)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Menu {
                Button("Show task workspace") { NSWorkspace.shared.open(store.workspaceURL(for: job)) }
                if let result = job.result {
                    Button("Copy response") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }
                }
                if ![.queued, .running, .awaitingApproval].contains(job.state) {
                    Button("Retry request") { store.retry(job.id) }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Task options")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private func latestResult(_ job: AgentJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure = job.failure {
                Label(AgentTaskPresentation.statusLabel(for: job), systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Text(failure).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let result = job.result, !result.isEmpty {
                let hasDeliverables = !AgentTaskPresentation.artifacts(AgentArtifacts.files(in: store.workspaceURL(for: job))).primary.isEmpty
                if job.state == .succeeded && hasDeliverables {
                    DisclosureGroup("Agent’s response", isExpanded: $showsResponse) {
                        if showsResponse { Text(result).font(.callout).textSelection(.enabled).padding(.top, 8) }
                    }.font(.callout)
                } else {
                Text(job.state == .awaitingApproval ? "Review before continuing" : "Latest response").font(.headline)
                if job.state == .awaitingApproval {
                    Text(result).font(.callout).textSelection(.enabled)
                } else if !showsFullResponse { Text(AgentTaskPresentation.resultPreview(result)).font(.callout).textSelection(.enabled) }
                if job.state != .awaitingApproval && AgentTaskPresentation.resultPreview(result) != result.trimmingCharacters(in: .whitespacesAndNewlines) {
                    DisclosureGroup("Full response", isExpanded: $showsFullResponse) {
                        if showsFullResponse { Text(result).font(.callout).textSelection(.enabled).padding(.top, 8) }
                    }.font(.callout)
                }
                }
            } else if job.state == .queued {
                Text("Waiting for an available agent.").font(.callout).foregroundStyle(.secondary)
            } else if job.state == .running {
                Text("Your agent is working. The response will appear here.").font(.callout).foregroundStyle(.secondary)
            } else if job.failure == nil {
                Text(job.state == .cancelled ? "This task was stopped." : "No response was saved for this turn.").font(.callout).foregroundStyle(.secondary)
            }
            if ProactiveSuggestion.displayPrompt(job.prompt) != job.prompt {
                Label("Screen and recent activity attached", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func files(_ job: AgentJob) -> some View {
        let grouped = AgentTaskPresentation.artifacts(AgentArtifacts.files(in: store.workspaceURL(for: job)))
        if !grouped.primary.isEmpty || !grouped.supporting.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !grouped.primary.isEmpty {
                    Text("Result files").font(.headline)
                    ForEach(Array(grouped.primary.prefix(3)), id: \.self) { file in fileButton(file) }
                    if grouped.primary.count > 3 {
                        DisclosureGroup("More files (\(grouped.primary.count - 3))", isExpanded: $showsMoreFiles) {
                            if showsMoreFiles {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(grouped.primary.dropFirst(3)), id: \.self) { file in fileButton(file) }
                                }.padding(.top, 8)
                            }
                        }.font(.callout)
                    }
                }

            }
        }
    }

    @ViewBuilder private func supportingFiles(_ job: AgentJob) -> some View {
        let grouped = AgentTaskPresentation.artifacts(AgentArtifacts.files(in: store.workspaceURL(for: job)))
                if !grouped.supporting.isEmpty {
                    DisclosureGroup("Supporting files (\(grouped.supporting.count))", isExpanded: $showsSupportingFiles) {
                        if showsSupportingFiles {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Verification receipts and saved responses.").font(.caption).foregroundStyle(.secondary)
                                ForEach(grouped.supporting, id: \.self) { file in fileButton(file) }
                            }.padding(.top, 8)
                        }
                    }.font(.callout)
                }
    }

    private func fileButton(_ file: URL) -> some View {
        Button {
            guard let job else { return }
            do { try AgentArtifactPreview.open(file, workspace: store.workspaceURL(for: job)); previewError = nil }
            catch { previewError = error.localizedDescription }
        } label: {
            Label(file.lastPathComponent, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
        }.buttonStyle(.link).help(file.lastPathComponent)
    }

    private func request(_ job: AgentJob) -> some View {
        DisclosureGroup("Request details", isExpanded: $showsRequest) {
            if showsRequest {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ProactiveSuggestion.displayPrompt(job.prompt)).font(.callout).textSelection(.enabled)
                    if ProactiveSuggestion.displayPrompt(job.prompt) != job.prompt {
                        Label("Screen and recent activity attached", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                        Text(job.prompt).font(.caption).textSelection(.enabled)
                    }
                    if let target = job.computerTargetID { Label("Computer task · " + target, systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(.callout)
    }

    @ViewBuilder private func history(_ job: AgentJob) -> some View {
        if let history = job.history, !history.isEmpty {
            DisclosureGroup("Conversation history (\(history.count))", isExpanded: $showsHistory) {
                if showsHistory {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(history) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Turn \(turn.attempt)").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(turn.prompt).font(.callout.weight(.medium)).textSelection(.enabled)
                                if let result = turn.result { Text(result).font(.callout).textSelection(.enabled) }
                                if let failure = turn.failure { Text(failure).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.top, 8)
                }
            }.font(.callout)
        }
    }

    private func activity(_ job: AgentJob) -> some View {
        DisclosureGroup("Activity & verification", isExpanded: $showsActivity) {
            if showsActivity {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Turn \(job.attempt) · \(job.state.rawValue)").font(.caption).foregroundStyle(.secondary)
                    if (job.activity ?? []).isEmpty { Text("No detailed activity was recorded.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(job.activity ?? []) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(event.date.formatted(date: .omitted, time: .standard)) · \(event.kind.capitalized)").font(.caption).foregroundStyle(.secondary)
                            Text(event.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 8)
            }
        }.font(.callout)
    }

    @ViewBuilder private func composer(_ job: AgentJob) -> some View {
        if [.running, .queued].contains(job.state) {
            HStack {
                Text(job.state == .queued ? "Starts when an agent is available." : "You can follow up when this turn finishes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop task") { store.cancel(job.id) }
            }
        } else {
            TextField(job.state == .awaitingApproval ? "Reply after reviewing the request…" : "Follow up with \(job.helperName)…", text: $followUp, axis: .vertical)
                .lineLimit(2...4).accessibilityLabel("Follow-up message")
            HStack {
                Text(followUp.count > 8000 ? "Keep your message under 8,000 characters." : "Continues with the same conversation and files.")
                    .font(.caption).foregroundStyle(followUp.count > 8000 ? Color.orange : Color.secondary)
                Spacer()
                if job.state == .awaitingApproval { Button("Stop task") { store.cancel(job.id) } }
                Button("Send follow-up") {
                    if store.followUp(job.id, text: followUp) { followUp = ""; sendingError = nil; showsFullResponse = false }
                    else { sendingError = store.error ?? "Could not send follow-up. Try again after this task stops." }
                }.buttonStyle(KaddoButtonStyle(prominent: true))
                    .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || followUp.count > 8000)
            }
        }
        if let sendingError { Text(sendingError).font(.caption).foregroundStyle(.orange) }
    }

    private func needsAttention(_ job: AgentJob) -> Bool { [.failed, .interrupted, .awaitingApproval].contains(job.state) }
}
