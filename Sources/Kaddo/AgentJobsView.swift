import SwiftUI
import AppKit

struct AgentJobsView: View {
    @ObservedObject var store: AgentJobStore
    var helpers: [HelperProfile]
    var createAgent: (() -> Void)? = nil
    var showSuggestions: (() -> Void)? = nil
    var suggestionCount = 0
    var selectedAgentID: UUID? = nil
    var requestedJobID: UUID? = nil
    var onInspectionDismiss: (() -> Void)? = nil
    var onProfile: ((HelperProfile) -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @State private var inspectedJob: AgentJob?
    @State private var filterID: UUID?
    @State private var editingAgent: HelperProfile?
    @State private var title = ""
    @State private var prompt = ""
    @State private var helperID: UUID?
    @State private var repeats = false
    @State private var repeatMinutes = 60
    @State private var computerUse = false
    @State private var computerTarget = ""
    @State private var computerTargets: [NSRunningApplication] = []
    @State private var showsNewTask = false
    @State private var optionsExpanded = false
    @FocusState private var taskPromptFocused: Bool
    private var visibleJobs: [AgentJob] { store.jobs.filter { filterID == nil || $0.helperID == filterID } }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your agents").font(.title2.bold())
                Spacer()
                Text("\(store.jobs.filter { $0.state == .running }.count) working").foregroundStyle(.secondary)
                Button("New task") { showsNewTask = true }.buttonStyle(KaddoButtonStyle(prominent: true)).disabled(helpers.isEmpty)
            }
            if let showSuggestions {
                HStack {
                    Button(action: showSuggestions) { Label(suggestionCount == 0 ? "Suggestions" : "Suggestions · \(suggestionCount)", systemImage: "sparkles") }
                    Spacer()
                    Menu {
                        if let createAgent { Button("Create agent", action: createAgent) }
                        if let helper = helpers.first(where: { $0.id == selectedAgentID }) {
                            Button("Edit agent profile") {
                                if let onProfile { onProfile(helper) } else { editingAgent = helper }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Agent options")
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HStack {
                Text("Tasks").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                KaddoMenuPicker(title: "Show tasks", selection: $filterID,
                    options: [(nil as UUID?, "All agents")] + helpers.map { (Optional($0.id), $0.name) }).frame(width: 210)
            }
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visibleJobs.isEmpty { ContentUnavailableView("No tasks for this agent", systemImage: "checklist", description: Text("Choose New task, or pick an idea from Suggestions.")) }
                    ForEach(visibleJobs) { job in jobRow(job) }
                }
        }.padding(24).buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
            .safeAreaInset(edge: .top, spacing: 0) {
                AgentComputerControls(computer: store.computer, cancel: { store.cancel($0) }).padding(.horizontal, 24)
            }
            .sheet(item: $inspectedJob, onDismiss: { onInspectionDismiss?() }) { job in AgentTaskDetailView(store: store, jobID: job.id, helper: helpers.first { $0.id == job.helperID }, helperIsMain: job.helperID == model.primaryHelperID) }
            .sheet(isPresented: $showsNewTask) { newTaskSheet }
            .sheet(item: $editingAgent) { helper in AgentProfileView(helperID: helper.id).environmentObject(model) }
            .onAppear { helperID = helperID ?? selectedAgentID ?? helpers.first?.id }
            .onChange(of: requestedJobID, initial: true) { _, id in
                if let id, let job = store.jobs.first(where: { $0.id == id }) { filterID = job.helperID; inspectedJob = job }
            }
            .onChange(of: selectedAgentID) { _, id in if let id { helperID = id } }
    }
    private func jobRow(_ job: AgentJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let helper = helpers.first(where: { $0.id == job.helperID }) {
                AgentAvatar(profile: helper, size: 46, isMain: helper.id == model.primaryHelperID)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button { inspectedJob = job } label: { Text(job.title).font(.headline).multilineTextAlignment(.leading).lineLimit(2) }
                    .buttonStyle(.plain).accessibilityLabel("Open task: \(job.title)")
                HStack(spacing: 6) {
                    Text(job.helperName); Text("·")
                    Text(AgentTaskPresentation.statusLabel(for: job)).foregroundStyle(job.state == .failed || job.state == .awaitingApproval || job.state == .interrupted ? Color.orange : Color.secondary)
                }.font(.caption).foregroundStyle(.secondary)
                if job.state == .running { AgentExecutionStatusView(job: job) }
                if let next = job.nextRunAt, job.scheduleEnabled { Text("Next run: \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Button(job.state == .succeeded ? "View result" : job.state == .failed || job.state == .awaitingApproval ? "Review" : "Open") { inspectedJob = job }
                if [.queued, .running, .awaitingApproval].contains(job.state) {
                    Button("Stop") { store.cancel(job.id) }.font(.caption)
                } else {
                    Menu {
                        Button("Run again") { store.retry(job.id) }
                        Button("Open task files") { NSWorkspace.shared.open(store.workspaceURL(for: job)) }
                        if let result = job.result { Button("Copy response") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) } }
                        if job.repeatMinutes != nil { Toggle("Repeat enabled", isOn: Binding(get: { job.scheduleEnabled }, set: { store.setSchedule(job.id, enabled: $0) })) }
                    } label: { Image(systemName: "ellipsis").frame(width: 22, height: 18) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Task options: \(job.title)")
                }
            }
        }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }
    private var newTaskSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("New task").font(.title3.bold()); Spacer(); Button("Cancel") { showsNewTask = false }.keyboardShortcut(.cancelAction) }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        if let helper = helpers.first(where: { $0.id == helperID }) { AgentAvatar(profile: helper, size: 52, isMain: helper.id == model.primaryHelperID) }
                        KaddoMenuPicker(title: "Agent", selection: $helperID, options: helpers.map { (Optional($0.id), $0.name) })
                    }
                    TextField("What would you like done?", text: $prompt, axis: .vertical).lineLimit(4...7).focused($taskPromptFocused).accessibilityLabel("Describe the task")
                    DisclosureGroup(computerUse ? "Options · Computer use" : repeats ? "Options · Repeats" : "Options", isExpanded: $optionsExpanded) {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Task title (optional)", text: $title)
                            Toggle("Use the computer", isOn: $computerUse).toggleStyle(.checkbox)
                                .onChange(of: computerUse) { _, enabled in if enabled { repeats = false; refreshComputerTargets() } }
                            if computerUse {
                                KaddoMenuPicker(title: "Control app", selection: $computerTarget, options: [("", "Choose an open app")] + computerTargets.map { ($0.bundleIdentifier ?? "", $0.localizedName ?? "Application") })
                                HStack { Button("Refresh apps") { refreshComputerTargets() }; Button("Permissions") { store.computer.desktop.openControlSettings() } }
                                Text("Shares the chosen app’s screen. Actions wait for your review; stop at any time.").font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Repeat this task", isOn: $repeats).toggleStyle(.checkbox).disabled(computerUse)
                            if repeats { Stepper("Every \(repeatMinutes) minutes", value: $repeatMinutes, in: 1...1440) }
                        }.padding(.top, 12)
                    }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(22)
            }
            Divider()
            HStack {
                Text("Tasks continue while Kaddo is open.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start task") {
                    if let helper = helpers.first(where: { $0.id == helperID }), store.enqueue(title: title, prompt: prompt, helper: helper, repeatMinutes: repeats ? repeatMinutes : nil, computerTargetID: computerUse ? computerTarget : nil) != nil { title = ""; prompt = ""; filterID = helper.id; showsNewTask = false }
                }.buttonStyle(KaddoButtonStyle(prominent: true)).keyboardShortcut(.return, modifiers: .command).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || helperID == nil || (computerUse && computerTarget.isEmpty))
            }.padding(22)
        }.buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).frame(width: 540, height: 450)
            .onAppear { taskPromptFocused = true }
    }
    private func refreshComputerTargets() {
        store.computer.desktop.refreshTargets()
        computerTargets = store.computer.desktop.targetApplications.filter { AgentComputerPolicy.validTarget($0.bundleIdentifier ?? "") }
        if !computerTargets.contains(where: { $0.bundleIdentifier == computerTarget }) { computerTarget = "" }
    }
    private func stateLabel(_ state: AgentJob.State) -> String {
        switch state {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        case .awaitingApproval: return "Needs approval"
        }
    }
}

struct AgentExecutionStatusView: View {
    let job: AgentJob
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = AgentExecutionPresentation.status(for: job.activity ?? [])
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status.label).lineLimit(2)
                Spacer(minLength: 4)
                Text(AgentExecutionPresentation.elapsed(since: job.startedAt ?? job.createdAt, now: context.date))
                    .monospacedDigit().foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }
}

enum AgentArtifacts {
    static func files(in workspace: URL) -> [URL] {
        let output = workspace.appendingPathComponent("output", isDirectory: true)
        guard let outputInfo = try? output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), outputInfo.isDirectory == true, outputInfo.isSymbolicLink != true,
              let entries = FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { return [] }
        let root = output.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var files: [URL] = []
        for case let file as URL in entries {
            guard let info = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { entries.skipDescendants(); continue }
            guard info.isSymbolicLink != true, file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { entries.skipDescendants(); continue }
            if info.isRegularFile == true { files.append(file) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
