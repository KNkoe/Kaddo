import Foundation
import Combine

struct AgentJobExchange: Codable, Equatable, Identifiable {
    var id = UUID()
    var prompt: String
    var result: String?
    var failure: String?
    var attempt: Int
}

struct AgentJob: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, running, succeeded, failed, cancelled, interrupted, awaitingApproval }
    var id = UUID()
    var title: String
    var prompt: String
    var helperID: UUID
    var helperName: String
    var helperInstructions: String
    var state: State = .queued
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var result: String?
    var failure: String?
    var repeatMinutes: Int?
    var nextRunAt: Date?
    var scheduleEnabled = false
    var attempt = 1
    var context: [AgentJobExchange]?
    var history: [AgentJobExchange]?
    var activity: [AgentActivity]?
    var computerTargetID: String?
}

/// Jobs run while Kaddo is open (including with all windows closed). App quit stops execution.
@MainActor final class AgentJobStore: ObservableObject {
    typealias Executor = (AgentJob, URL) async throws -> String
    @Published private(set) var jobs: [AgentJob] = []
    @Published var error: String?
    @Published private(set) var needsAttention = false
    let storageDirectory: URL
    let computer = AgentComputerUse()
    private let executor: Executor?
    private let maximumConcurrentJobs: Int
    private var active: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var loadFailed = false
    private var stopped = false
    private var fileURL: URL { storageDirectory.appendingPathComponent("jobs.json") }

    init(storageDirectory: URL? = nil, maximumConcurrentJobs: Int = 2, autoStart: Bool = true, executor: Executor? = nil) {
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kaddo", isDirectory: true)
        self.maximumConcurrentJobs = min(2, max(1, maximumConcurrentJobs))
        self.executor = executor
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                jobs = try JSONDecoder().decode([AgentJob].self, from: Data(contentsOf: fileURL))
                for index in jobs.indices where jobs[index].state == .running || (jobs[index].state == .queued && jobs[index].computerTargetID != nil) {
                    jobs[index].state = .interrupted
                    jobs[index].failure = "Kaddo stopped before this job finished. Review its workspace before retrying."
                    jobs[index].finishedAt = Date()
                }
                // Repeating jobs never silently resume after app relaunch.
                for index in jobs.indices { jobs[index].scheduleEnabled = false }
                _ = persist()
            } catch { loadFailed = true; self.error = "Could not load jobs. Saved data was preserved: \(error.localizedDescription)" }
        }
        updateAttention()
        if autoStart {
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            Task { [weak self] in self?.pump() }
        }
    }

    @discardableResult func enqueue(title: String, prompt: String, helper: HelperProfile, repeatMinutes: Int? = nil, computerTargetID: String? = nil) -> UUID? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !loadFailed else { return nil }
        var job = AgentJob(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(text.prefix(60)) : title, prompt: text, helperID: helper.id, helperName: helper.name, helperInstructions: helper.effectiveInstructions)
        job.context = jobs.filter { $0.helperID == helper.id && ![.queued, .running].contains($0.state) }.prefix(4).reversed().map {
            AgentJobExchange(prompt: $0.prompt, result: $0.result, failure: $0.failure, attempt: $0.attempt)
        }
        if let computerTargetID {
            guard AgentComputerPolicy.validTarget(computerTargetID), repeatMinutes == nil else { error = "Choose an application for a one-time computer task. Computer tasks cannot repeat."; return nil }
            job.computerTargetID = computerTargetID
        }
        if let interval = repeatMinutes, interval >= 1 { job.repeatMinutes = interval; job.scheduleEnabled = true }
        do { try prepareWorkspace(for: job) }
        catch { self.error = "Could not prepare helper workspace: \(error.localizedDescription)"; return nil }
        jobs.insert(job, at: 0)
        guard persist() else { jobs.removeAll { $0.id == job.id }; return nil }
        pump()
        return job.id
    }

    func workspaceURL(for job: AgentJob) -> URL {
        storageDirectory.appendingPathComponent("Helpers", isDirectory: true).appendingPathComponent(job.helperID.uuidString, isDirectory: true).appendingPathComponent("Jobs", isDirectory: true).appendingPathComponent(job.id.uuidString, isDirectory: true)
    }

    private func prepareWorkspace(for job: AgentJob) throws {
        let helper = storageDirectory.appendingPathComponent("Helpers", isDirectory: true).appendingPathComponent(job.helperID.uuidString, isDirectory: true)
        let workspace = workspaceURL(for: job)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("output", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rules = "# \(job.helperName)\n\n\(job.helperInstructions)\n\nRead notes.md for durable helper context. Append non-secret durable notes there when useful. Keep deliverables in output/. Do not send messages, make payments, change external accounts, or delete files outside this workspace. Explain needed external actions for user approval. Report evidence and incomplete work honestly.\n"
        try rules.write(to: helper.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try rules.write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let notes = helper.appendingPathComponent("notes.md")
        if !FileManager.default.fileExists(atPath: notes.path) { try "# Helper notes\n".write(to: notes, atomically: true, encoding: .utf8) }
        let savedNotes = try String(contentsOf: notes, encoding: .utf8)
        try savedNotes.write(to: workspace.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try savedNotes.write(to: workspace.appendingPathComponent(".notes-baseline.md"), atomically: true, encoding: .utf8)
        try job.prompt.write(to: workspace.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].scheduleEnabled = false; jobs[index].nextRunAt = nil
        if [.queued, .running, .awaitingApproval].contains(jobs[index].state) {
            jobs[index].state = .cancelled; jobs[index].finishedAt = Date()
            active[id]?.cancel()
            if computer.jobID == id { computer.stop() }
        }
        _ = persist(); updateAttention(); pump()
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), active[id] == nil,
              [.failed, .cancelled, .interrupted, .succeeded, .awaitingApproval].contains(jobs[index].state) else { return }
        jobs[index].state = .queued; jobs[index].result = nil; jobs[index].failure = nil
        jobs[index].startedAt = nil; jobs[index].finishedAt = nil; jobs[index].nextRunAt = nil; jobs[index].attempt += 1
        guard persist() else { return }
        updateAttention(); pump()
    }

    /// Continue the same task and files, retaining previous answers rather than retrying the original request.
    @discardableResult func followUp(_ id: UUID, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stopped, !loadFailed, !text.isEmpty, text.count <= 8000,
              let index = jobs.firstIndex(where: { $0.id == id }), active[id] == nil,
              ![.queued, .running].contains(jobs[index].state) else { return false }
        let previous = jobs[index]
        var history = previous.history ?? []
        history.append(AgentJobExchange(prompt: previous.prompt, result: previous.result, failure: previous.failure, attempt: previous.attempt))
        jobs[index].history = history
        jobs[index].prompt = text
        jobs[index].result = nil; jobs[index].failure = nil
        jobs[index].state = .queued; jobs[index].attempt += 1
        jobs[index].startedAt = nil; jobs[index].finishedAt = nil
        jobs[index].scheduleEnabled = false; jobs[index].nextRunAt = nil
        guard persist() else { jobs[index] = previous; return false }
        updateAttention(); pump(); return true
    }

    static func messages(for job: AgentJob) -> [ChatMessage] {
        var messages = [ChatMessage(role: "system", content: "You are Kaddo helper \(job.helperName). \(job.helperInstructions)\nWork only inside the provided workspace. Write deliverables under output/. Do not send messages, modify external accounts, make payments, or delete files outside this workspace. If an external action is needed, begin the response with [KADDO_APPROVAL_REQUIRED], explain it for the user to approve, and do not execute it. Report actual evidence and incomplete work. Earlier turns are context; inspect existing output files before changing them.")]
        for turn in ((job.context ?? []) + (job.history ?? [])).suffix(12) {
            messages.append(ChatMessage(role: "user", content: String(turn.prompt.prefix(8000))))
            if let result = turn.result { messages.append(ChatMessage(role: "assistant", content: String(result.prefix(16000)))) }
            if let failure = turn.failure { messages.append(ChatMessage(role: "assistant", content: "Previous attempt failed: " + failure)) }
        }
        messages.append(ChatMessage(role: "user", content: job.prompt))
        return messages
    }

    func recordActivity(_ event: AgentActivity, for id: UUID, attempt: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running,
              jobs[index].attempt == attempt else { return }
        var events = jobs[index].activity ?? []
        events.append(event); jobs[index].activity = Array(events.suffix(200))
        _ = persist()
    }

    func setSchedule(_ id: UUID, enabled: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].computerTargetID == nil, let minutes = jobs[index].repeatMinutes else { return }
        jobs[index].scheduleEnabled = enabled
        jobs[index].nextRunAt = enabled ? Date().addingTimeInterval(Double(minutes * 60)) : nil
        _ = persist()
    }

    func shutdown() {
        stopped = true; timer?.invalidate(); timer = nil
        computer.stop()
        for index in jobs.indices where jobs[index].state == .running {
            jobs[index].state = .interrupted; jobs[index].failure = "Kaddo quit before this job finished. Review output before retrying."
            jobs[index].finishedAt = Date()
        }
        for index in jobs.indices { jobs[index].scheduleEnabled = false }
        for task in active.values { task.cancel() }
        _ = persist(); updateAttention()
    }

    func tick(now: Date = Date()) {
        guard !stopped else { return }
        let due = jobs.filter { $0.scheduleEnabled && $0.nextRunAt.map { $0 <= now } == true && active[$0.id] == nil }.map(\.id)
        for id in due { retry(id) }
        pump()
    }

    private func pump() {
        guard !stopped, !loadFailed else { return }
        while active.count < maximumConcurrentJobs, let index = jobs.indices.reversed().first(where: {
            jobs[$0].state == .queued && active[jobs[$0].id] == nil &&
            (jobs[$0].computerTargetID == nil || !jobs.contains { $0.computerTargetID != nil && active[$0.id] != nil })
        }) {
            jobs[index].state = .running; jobs[index].startedAt = Date()
            guard persist() else { jobs[index].state = .queued; return }
            let job = jobs[index]; let workspace = workspaceURL(for: job); let execute = executor
            active[job.id] = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    try self?.refreshQueuedNotes(for: job)
                    let result: String
                    if let execute { result = try await execute(job, workspace) }
                    else if job.computerTargetID != nil, let self {
                        result = try await self.computer.run(job: job, workspace: workspace) { [weak self] event in
                            self?.recordActivity(event, for: job.id, attempt: job.attempt)
                        }
                    }
                    else {
                        result = try await CodexBridge.runAgent(messages: Self.messages(for: job), workspace: workspace) { [weak self] event in
                            Task { @MainActor in self?.recordActivity(event, for: job.id, attempt: job.attempt) }
                        }
                    }
                    try Task.checkCancellation()
                    guard let self else { return }
                    // Every run leaves a concrete local deliverable, even for research-only jobs.
                    try AgentResultWriter.write(result, storageDirectory: self.storageDirectory, helperID: job.helperID, jobID: job.id, attempt: job.attempt)
                    try self.mergeNotes(for: job)
                    self.finish(job.id, result: result, failure: nil)
                } catch let error as AgentVerificationError {
                    guard let self else { return }
                    var failure = error.localizedDescription
                    do { try AgentResultWriter.write(error.response, storageDirectory: self.storageDirectory, helperID: job.helperID, jobID: job.id, attempt: job.attempt) }
                    catch { failure += " Result file could not be saved: " + error.localizedDescription }
                    if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                        self.jobs[index].scheduleEnabled = false; self.jobs[index].nextRunAt = nil
                    }
                    self.finish(job.id, result: error.response, failure: failure)
                } catch is CancellationError { self?.finish(job.id, result: nil, failure: nil, cancelled: true) }
                catch { self?.finish(job.id, result: nil, failure: error.localizedDescription) }
            }
        }
    }

    private func refreshQueuedNotes(for job: AgentJob) throws {
        guard job.attempt == 1 else { return }
        guard let original = try AgentResultWriter.readNotes(storageDirectory: storageDirectory, helperID: job.helperID, jobID: job.id, baseline: true),
              let notes = try AgentResultWriter.readNotes(storageDirectory: storageDirectory, helperID: job.helperID, jobID: job.id) else { throw CocoaError(.fileReadNoSuchFile) }
        guard notes == original else { return }
        guard let latest = try AgentResultWriter.readNotes(storageDirectory: storageDirectory, helperID: job.helperID) else { throw CocoaError(.fileReadNoSuchFile) }
        guard latest != original else { return }
        try AgentResultWriter.writeNotes(latest, storageDirectory: storageDirectory, helperID: job.helperID, jobID: job.id)
        try AgentResultWriter.writeNotes(latest, storageDirectory: storageDirectory, helperID: job.helperID, jobID: job.id, baseline: true)
    }

    private func mergeNotes(for job: AgentJob) throws {
        guard let baseline = try AgentResultWriter.readNotes(storageDirectory: storageDirectory, helperID: job.helperID, jobID: job.id, baseline: true),
              let notes = try AgentResultWriter.readNotes(storageDirectory: storageDirectory, helperID: job.helperID, jobID: job.id), notes != baseline else { return }
        let addition = notes.hasPrefix(baseline) ? String(notes.dropFirst(baseline.count)) : notes
        guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let current = try AgentResultWriter.readNotes(storageDirectory: storageDirectory, helperID: job.helperID) ?? "# Helper notes\n"
        let retainedAddition = String(addition.prefix(20_000))
        let merged = current + "\n\n## Job \(job.title) · \(Date().formatted(date: .abbreviated, time: .shortened))\n" + retainedAddition
        try AgentResultWriter.writeNotes(merged, storageDirectory: storageDirectory, helperID: job.helperID)
        let newBaseline = notes.hasPrefix(baseline) ? baseline + retainedAddition : retainedAddition
        try AgentResultWriter.writeNotes(newBaseline, storageDirectory: storageDirectory, helperID: job.helperID, jobID: job.id, baseline: true)
    }

    private func finish(_ id: UUID, result: String?, failure: String?, cancelled: Bool = false) {
        active[id] = nil
        if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running {
            let approvalRequired = result?.hasPrefix("[KADDO_APPROVAL_REQUIRED]") == true
            var completed = jobs[index]
            completed.state = cancelled ? .cancelled : (failure != nil ? .failed : (approvalRequired ? .awaitingApproval : .succeeded))
            completed.result = result?.replacingOccurrences(of: "[KADDO_APPROVAL_REQUIRED]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            completed.failure = failure; completed.finishedAt = Date()
            if approvalRequired { completed.scheduleEnabled = false; completed.nextRunAt = nil }
            if completed.scheduleEnabled, let interval = completed.repeatMinutes {
                completed.nextRunAt = Date().addingTimeInterval(Double(interval * 60))
            }
            // Publish the terminal state and its result in one coherent snapshot.
            jobs[index] = completed
        }
        _ = persist(); updateAttention(); pump()
    }

    private func updateAttention() { needsAttention = jobs.contains { [.failed, .interrupted, .awaitingApproval].contains($0.state) } }
    @discardableResult private func persist() -> Bool {
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(jobs).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch { self.error = "Could not save jobs: \(error.localizedDescription)"; return false }
    }
}
