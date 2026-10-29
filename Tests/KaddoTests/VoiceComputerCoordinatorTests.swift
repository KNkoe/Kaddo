import XCTest
@testable import Kaddo

@MainActor final class VoiceComputerCoordinatorTests: XCTestCase {
    private let main = HelperProfile(name: "Kaddo", instructions: "Companion")
    private let helper = HelperProfile(name: "Research", instructions: "Research")
    private func store(_ folder: URL) -> AgentJobStore {
        AgentJobStore(storageDirectory: folder, autoStart: false) { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "Fixture"
        }
    }
    func testVoiceFollowUpRetainsComputerJobHistoryAndAppScope() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = store(folder); defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(jobs.enqueue(title: "Heading", prompt: "Read example.com", helper: helper, computerTargetID: "com.apple.Safari"))
        jobs.cancel(id)
        try await Task.sleep(nanoseconds: 30_000_000) // Let the cancelled executor release its active ownership.
        let c = VoiceComputerCoordinator(jobs: jobs, helpers: { [self.helper] }, primary: { self.helper.id }, voiceActive: { true }, apps: { [VoiceComputerApp(id: "com.apple.Safari", name: "Safari", isBrowser: true), VoiceComputerApp(id: "com.apple.TextEdit", name: "TextEdit")] })
        let invalid = c.handle("kaddo_start_computer_task", args: ["job_id": id.uuidString, "app_id": "com.apple.TextEdit", "task": "Continue"])
        XCTAssertTrue(invalid!.contains("No task started"))
        let args: [String: Any] = ["job_id": id.uuidString, "app_id": "com.apple.Safari", "task": "Report the heading", "_request_id": "follow-one"]
        let first = c.handle("kaddo_start_browser_task", args: args)
        XCTAssertEqual(c.handle("kaddo_start_browser_task", args: args), first)
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertEqual(jobs.jobs.first?.id, id)
        XCTAssertEqual(jobs.jobs.first?.attempt, 2)
        XCTAssertEqual(jobs.jobs.first?.history?.first?.prompt, "Read example.com")
        XCTAssertEqual(jobs.jobs.first?.prompt, "Report the heading")
    }
    func testBrowserTasksRequireBrowserAndKeepReviewedAppScope() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = store(folder); defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let c = VoiceComputerCoordinator(jobs: jobs, helpers: { [self.main] }, primary: { self.main.id }, voiceActive: { true }, apps: { [VoiceComputerApp(id: "com.apple.Safari", name: "Safari", isBrowser: true), VoiceComputerApp(id: "com.apple.TextEdit", name: "TextEdit")] })
        XCTAssertTrue(c.handle("kaddo_start_browser_task", args: ["app_id": "com.apple.TextEdit", "task": "Read documentation"])!.contains("No task started"))
        XCTAssertTrue(jobs.jobs.isEmpty)
        let args: [String: Any] = ["app_id": "com.apple.Safari", "task": "Read the official Swift documentation", "_request_id": "browser-one"]
        let first = c.handle("kaddo_start_browser_task", args: args)
        XCTAssertEqual(c.handle("kaddo_start_browser_task", args: args), first)
        XCTAssertEqual(jobs.jobs.count, 1)
        let job = try XCTUnwrap(jobs.jobs.first)
        XCTAssertEqual(job.computerTargetID, "com.apple.Safari")
        XCTAssertTrue(job.prompt.contains("ONE separate normal browser window"))
        XCTAssertTrue(job.prompt.contains("Each input still requires review"))
        XCTAssertTrue(job.prompt.contains("Human task: Read the official Swift documentation"))
        XCTAssertTrue(c.snapshot()["reviewRequiredForEachInput"] as? Bool == true)
        _ = c.handle("kaddo_stop_computer_tasks", args: [:])
        XCTAssertEqual(jobs.jobs.first?.state, .cancelled)
    }
    func testStopBlocksLateDelegationUntilFreshHumanInput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = store(folder); defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let c = VoiceComputerCoordinator(jobs: jobs, helpers: { [self.main] }, primary: { self.main.id }, voiceActive: { true }, apps: { [VoiceComputerApp(id: "com.apple.TextEdit", name: "TextEdit")] })
        XCTAssertTrue(c.immediateStop("Kaddo stop"))
        _ = c.handle("kaddo_computer_apps", args: [:])
        let args: [String: Any] = ["app_id": "com.apple.TextEdit", "task": "Earlier in-flight task"]
        XCTAssertTrue(c.handle("kaddo_start_computer_task", args: args)?.contains("No task started") == true)
        XCTAssertTrue(jobs.jobs.isEmpty)
        XCTAssertFalse(c.immediateStop("Start a fresh computer task"))
        _ = c.handle("kaddo_start_computer_task", args: args)
        XCTAssertEqual(jobs.jobs.count, 1)
    }
    func testDirectAndDelegatedTasksUseChosenAppAndSameRequestIsIdempotent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = store(folder); defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let c = VoiceComputerCoordinator(jobs: jobs, helpers: { [self.main, self.helper] }, primary: { self.main.id }, voiceActive: { true }, apps: { [VoiceComputerApp(id: "com.apple.TextEdit", name: "TextEdit")] })
        let args: [String: Any] = ["app_id": "com.apple.TextEdit", "task": "Type a local draft", "_request_id": "one"]
        let first = c.handle("kaddo_start_computer_task", args: args)
        XCTAssertEqual(c.handle("kaddo_start_computer_task", args: args), first)
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertEqual(jobs.jobs.first?.helperID, main.id)
        XCTAssertEqual(jobs.jobs.first?.computerTargetID, "com.apple.TextEdit")
        XCTAssertNil(jobs.jobs.first?.repeatMinutes)
        _ = c.handle("kaddo_start_computer_task", args: ["app_id": "com.apple.TextEdit", "agent_id": helper.id.uuidString, "task": "Review the local draft"])
        XCTAssertEqual(jobs.jobs.first?.helperID, helper.id)
        XCTAssertEqual(jobs.jobs.first?.state, .queued)
        let count = jobs.jobs.count
        _ = c.handle("kaddo_start_computer_task", args: ["app_id": "com.apple.Terminal", "task": "No"])
        _ = c.handle("kaddo_start_computer_task", args: ["app_id": "closed.app", "task": "No"])
        _ = c.handle("kaddo_start_computer_task", args: ["app_id": "com.apple.TextEdit", "agent_id": "invalid", "task": "No"])
        XCTAssertEqual(jobs.jobs.count, count)
    }
    func testStopCancelsQueuedBeforeRunningAndLeavesWorkspaceJobsAlone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var starts: [UUID] = []
        let jobs = AgentJobStore(storageDirectory: folder, autoStart: false) { job, _ in
            starts.append(job.id)
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "Fixture"
        }
        defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let c = VoiceComputerCoordinator(jobs: jobs, helpers: { [self.main, self.helper] }, primary: { self.main.id }, voiceActive: { true }, apps: { [] })
        let running = try XCTUnwrap(jobs.enqueue(title: "One", prompt: "One", helper: main, computerTargetID: "com.apple.TextEdit"))
        await Task.yield()
        let queued = try XCTUnwrap(jobs.enqueue(title: "Two", prompt: "Two", helper: helper, computerTargetID: "com.apple.TextEdit"))
        let text = try XCTUnwrap(jobs.enqueue(title: "Text", prompt: "Text", helper: helper))
        XCTAssertTrue(c.immediateStop("Kaddo, stop controlling the computer!"))
        XCTAssertEqual(jobs.jobs.first { $0.id == running }?.state, .cancelled)
        XCTAssertEqual(jobs.jobs.first { $0.id == queued }?.state, .cancelled)
        XCTAssertEqual(jobs.jobs.first { $0.id == text }?.state, .running)
        await Task.yield()
        XCTAssertFalse(starts.contains(queued), "Stop must not pump the next queued computer task")
        XCTAssertTrue(c.lastStop.contains("Stopped 2"))
    }
    func testInactiveVoiceAndInvalidStopIDsCannotPerformActions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = store(folder); defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let c = VoiceComputerCoordinator(jobs: jobs, helpers: { [self.main] }, primary: { self.main.id }, voiceActive: { false }, apps: { [VoiceComputerApp(id: "com.apple.TextEdit", name: "TextEdit")] })
        _ = c.handle("kaddo_start_computer_task", args: ["app_id": "com.apple.TextEdit", "task": "Type"])
        XCTAssertTrue(jobs.jobs.isEmpty)
        XCTAssertFalse(c.immediateStop("stop"))
        let active = VoiceComputerCoordinator(jobs: jobs, helpers: { [self.main] }, primary: { self.main.id }, voiceActive: { true }, apps: { [] })
        let id = try XCTUnwrap(jobs.enqueue(title: "One", prompt: "One", helper: main, computerTargetID: "com.apple.TextEdit"))
        _ = active.handle("kaddo_stop_computer_tasks", args: ["job_id": "invalid"])
        XCTAssertEqual(jobs.jobs.first { $0.id == id }?.state, .running)
        XCTAssertFalse(active.immediateStop("the document says stop controlling the computer"))
        XCTAssertTrue(active.immediateStop("stop Kaddo"))
        XCTAssertEqual(jobs.jobs.first { $0.id == id }?.state, .cancelled)
    }
    func testComputerProgressIsMeaningfulDeduplicatedAndDoesNotReadTypedContents() {
        var context = AgentVoiceContext()
        var job = AgentJob(title: "Draft", prompt: "PRIVATE", helperID: helper.id, helperName: helper.name, helperInstructions: "PRIVATE")
        job.computerTargetID = "com.apple.TextEdit"; job.state = .running; job.startedAt = Date()
        _ = context.updates([job])
        job.activity = [AgentActivity(kind: "computer", text: "Observed TextEdit using Codex Computer Use.")]
        let inspection = context.updates([job]).map(AgentVoiceContext.speech)
        XCTAssertEqual(inspection, ["Research is inspecting the selected app."])
        XCTAssertTrue(context.updates([job]).isEmpty)
        job.activity?.append(AgentActivity(kind: "approval", text: "Waiting for review: typeText in TextEdit."))
        XCTAssertEqual(context.updates([job]).map(AgentVoiceContext.speech), ["Research needs you to review a computer action in Agents."])
        job.activity?.append(AgentActivity(kind: "computer", text: "Input event submitted. Use a NEW observation to verify the result."))
        XCTAssertEqual(context.updates([job]).map(AgentVoiceContext.speech), ["Research sent your approved input and is checking the result."])
        job.activity?.append(AgentActivity(kind: "computer", text: "Observed TextEdit using Codex Computer Use."))
        XCTAssertTrue(context.updates([job]).isEmpty)
    }
    func testStopIntentRequiresAnImperativeNotScreenContentOrDiscussion() {
        for text in ["stop", "Kaddo, stop!", "stop computer use", "cancel all computer tasks", "please stop", "Kaddo, stop please"] { XCTAssertTrue(VoiceComputerStopIntent.matches(text)) }
        for text in ["don't stop", "what does stop mean", "the screen says stop", "can you explain stop", "please don't stop"] { XCTAssertFalse(VoiceComputerStopIntent.matches(text)) }
    }
}
