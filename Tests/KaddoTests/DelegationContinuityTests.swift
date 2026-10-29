import XCTest
import Combine
@testable import Kaddo

@MainActor final class DelegationContinuityTests: XCTestCase {
    func testDelegatedConversationPersistsFollowUpAndRoutesToSameTask() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json")
        let model = AppModel(storageURL: url, useKeychain: false)
        let selected = model.selectedID
        let helper = HelperProfile(name: "Research", instructions: "Research")
        var job = AgentJob(title: "Read a heading", prompt: "Read example.com", helperID: helper.id, helperName: helper.name, helperInstructions: helper.instructions)
        job.state = .succeeded; job.result = "Example Domain"
        model.syncAgentConversations([job]); model.syncAgentConversations([job])
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.conversations.filter { $0.agentJobID == job.id }.count, 1)
        job.history = [AgentJobExchange(prompt: job.prompt, result: job.result, attempt: 1)]
        job.prompt = "What did you find?"; job.result = "The heading was Example Domain"; job.attempt = 2
        model.syncAgentConversations([job])
        let conversation = try XCTUnwrap(model.conversations.first { $0.agentJobID == job.id })
        XCTAssertEqual(conversation.messages.map(\.content), ["Read example.com", "Example Domain", "What did you find?", "The heading was Example Domain"])
        let loaded = AppModel(storageURL: url, useKeychain: false)
        XCTAssertEqual(loaded.conversations.first { $0.agentJobID == job.id }?.messages, conversation.messages)
        model.selectedID = conversation.id
        var routed: UUID?
        model.coordinatorFollowUp = { id, text in routed = id; XCTAssertEqual(text, "Continue"); return true }
        model.input = "Continue"; model.send()
        XCTAssertEqual(routed, job.id); XCTAssertTrue(model.input.isEmpty)
    }
    func testFreshTaskReceivesSameAgentContextButNeverAnotherAgents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let helper = HelperProfile(name: "Research", instructions: "Research")
        let other = HelperProfile(name: "Planner", instructions: "Plan")
        let jobs = AgentJobStore(storageDirectory: folder, autoStart: false) { job, _ in "Result for " + job.prompt }
        defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        _ = jobs.enqueue(title: "First", prompt: "First request", helper: helper)
        _ = jobs.enqueue(title: "Private other task", prompt: "OTHER_AGENT_CONTEXT", helper: other)
        for _ in 0..<100 where jobs.jobs.contains(where: { $0.state == .running || $0.state == .queued }) { try await Task.sleep(nanoseconds: 10_000_000) }
        let id = try XCTUnwrap(jobs.enqueue(title: "Next", prompt: "Next request", helper: helper))
        let job = try XCTUnwrap(jobs.jobs.first { $0.id == id })
        let context = AgentJobStore.messages(for: job).map(\.content).joined(separator: "\n")
        XCTAssertTrue(context.contains("First request")); XCTAssertTrue(context.contains("Result for First request"))
        XCTAssertFalse(context.contains("OTHER_AGENT_CONTEXT"))
    }
    func testInterruptedSpeechKeepsFinalResultsAndDropsStaleProgress() {
        var queue = VoiceAgentAnnouncements()
        queue.append("Research is working", durable: false)
        queue.append("Research found Example Domain", durable: true)
        for i in 0..<20 { queue.append("Progress \(i)", durable: false) }
        queue.discardProgress()
        XCTAssertEqual(queue.take(), ["Research found Example Domain"])
        XCTAssertTrue(queue.isEmpty)
        var context = AgentVoiceContext()
        let helper = UUID()
        var job = AgentJob(title: "Heading", prompt: "Read", helperID: helper, helperName: "Research", helperInstructions: "")
        _ = context.updates([job]); job.state = .succeeded; job.result = "Example Domain"
        let updates = context.updates([job])
        XCTAssertEqual(updates.count, 1); XCTAssertTrue(AgentVoiceContext.isTerminal(updates[0]))
        XCTAssertTrue(AgentVoiceContext.speech(updates[0]).contains("Example Domain"))
    }
    func testPublishedCompletionAlwaysIncludesResultForVoice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let helper = HelperProfile(name: "Research", instructions: "Research")
        let jobs = AgentJobStore(storageDirectory: folder, autoStart: false) { _, _ in "Example Domain" }
        defer { jobs.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var context = AgentVoiceContext(), spoken: [String] = [], terminalSnapshots = 0
        let done = expectation(description: "coherent completion")
        let observer = jobs.$jobs.sink { values in
            for value in values where value.state == .succeeded {
                terminalSnapshots += 1
                XCTAssertEqual(value.result, "Example Domain")
                XCTAssertNotNil(value.finishedAt)
            }
            let updates = context.updates(values)
            spoken += updates.map(AgentVoiceContext.speech)
            if updates.contains(where: AgentVoiceContext.isTerminal) { done.fulfill() }
        }
        defer { observer.cancel() }
        _ = jobs.enqueue(title: "Heading", prompt: "Read example.com", helper: helper)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(terminalSnapshots, 1)
        XCTAssertEqual(spoken.filter { $0.contains("Example Domain") }.count, 1)
    }
    func testDeletedTaskChatDoesNotReturnOnUpdateOrRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json")
        let model = AppModel(storageURL: url, useKeychain: false)
        let job = AgentJob(title: "Task", prompt: "Task", helperID: UUID(), helperName: "Research", helperInstructions: "")
        model.syncAgentConversations([job])
        let chat = try XCTUnwrap(model.conversations.first { $0.agentJobID == job.id })
        model.deleteConversation(chat.id); model.syncAgentConversations([job])
        XCTAssertFalse(model.conversations.contains { $0.agentJobID == job.id })
        let loaded = AppModel(storageURL: url, useKeychain: false)
        loaded.syncAgentConversations([job])
        XCTAssertFalse(loaded.conversations.contains { $0.agentJobID == job.id })
    }
    func testMainVoiceNeverSelectsOrOverwritesTaskConversation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("state.json"), useKeychain: false)
        let primary = try XCTUnwrap(model.primaryHelperID)
        let jobChat = Conversation(title: "Computer task", messages: [ChatMessage(role: "user", content: "Task only")], helperID: primary, agentJobID: UUID())
        model.conversations.insert(jobChat, at: 0); model.selectedID = jobChat.id
        model.selectMainCompanion()
        XCTAssertNotEqual(model.selectedID, jobChat.id)
        XCTAssertEqual(model.selectedConversation?.helperID, primary)
        XCTAssertNil(model.selectedConversation?.agentJobID)
        XCTAssertEqual(model.conversations.first { $0.id == jobChat.id }?.messages.map(\.content), ["Task only"])
        model.conversations.removeAll { $0.agentJobID == nil }
        model.selectedID = jobChat.id; model.selectMainCompanion()
        XCTAssertNotEqual(model.selectedID, jobChat.id)
        XCTAssertNil(model.selectedConversation?.agentJobID)
    }
    func testTerminalResultsPersistWhileVoiceIsOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json")
        let model = AppModel(storageURL: url, useKeychain: false)
        var context = AgentVoiceContext()
        var job = AgentJob(title: "Heading", prompt: "Read", helperID: UUID(), helperName: "Research", helperInstructions: "")
        _ = context.updates([job]); job.state = .succeeded; job.result = "Example Domain"
        model.announceAgentUpdates(context.updates([job]))
        XCTAssertEqual(model.pendingAgentResults.count, 1)
        XCTAssertTrue(model.pendingAgentResults[0].contains("Example Domain"))
        let loaded = AppModel(storageURL: url, useKeychain: false)
        XCTAssertEqual(loaded.pendingAgentResults, model.pendingAgentResults)
    }
    func testOnlyNarrowReviewedBrowserShortcutsAreAccepted() throws {
        for key in ["new_window", "address_bar"] { try AgentComputerPolicy.validate(DesktopAction(type: .key, key: key), elementIndex: nil) }
        XCTAssertThrowsError(try AgentComputerPolicy.validate(DesktopAction(type: .key, key: "super+anything"), elementIndex: nil))
    }
}
