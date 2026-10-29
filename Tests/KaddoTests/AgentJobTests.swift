import XCTest
@testable import Kaddo

@MainActor final class AgentJobTests: XCTestCase {
    var directory: URL!
    let helper = HelperProfile(name: "Research", instructions: "Cite evidence")
    override func setUp() async throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func finish(_ store: AgentJobStore) async throws {
        for _ in 0..<300 {
            if !store.jobs.contains(where: { [.queued, .running].contains($0.state) }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Jobs did not finish")
    }
    func testPersistenceAndDeliverable() async throws {
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { job, _ in
            XCTAssertEqual(job.helperInstructions, self.helper.effectiveInstructions)
            return "Verified report"
        }
        let id = store.enqueue(title: "Report", prompt: "Research", helper: helper)!
        try await finish(store)
        let job = try XCTUnwrap(store.jobs.first { $0.id == id })
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertEqual(try String(contentsOf: store.workspaceURL(for: job).appendingPathComponent("output/result-attempt-1.md"), encoding: .utf8), "Verified report")
        let restored = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in XCTFail("Unexpected execution"); return "" }
        XCTAssertEqual(restored.jobs, store.jobs)
        let helperRoot = directory.appendingPathComponent("Helpers/\(helper.id.uuidString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperRoot.appendingPathComponent("AGENTS.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperRoot.appendingPathComponent("notes.md").path))
    }
    func testRecoveryDoesNotRetryInterruptedWork() throws {
        var job = AgentJob(title: "Old", prompt: "Work", helperID: helper.id, helperName: helper.name, helperInstructions: helper.instructions)
        job.state = .running; job.repeatMinutes = 10; job.scheduleEnabled = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([job]).write(to: directory.appendingPathComponent("jobs.json"))
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in XCTFail("Interrupted jobs must not resume"); return "" }
        XCTAssertEqual(store.jobs.first?.state, .interrupted)
        XCTAssertEqual(store.jobs.first?.scheduleEnabled, false)
        XCTAssertTrue(store.needsAttention)
    }
    func testConcurrencyCancellationAndExplicitRetry() async throws {
        var running = 0
        var maximum = 0
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in
            running += 1; maximum = max(maximum, running)
            defer { running -= 1 }
            try await Task.sleep(nanoseconds: 70_000_000)
            return "Done"
        }
        let first = store.enqueue(title: "One", prompt: "One", helper: helper)!
        _ = store.enqueue(title: "Two", prompt: "Two", helper: helper)
        _ = store.enqueue(title: "Three", prompt: "Three", helper: helper)
        try await Task.sleep(nanoseconds: 10_000_000)
        store.cancel(first)
        try await finish(store)
        XCTAssertEqual(maximum, 2)
        XCTAssertEqual(store.jobs.first { $0.id == first }?.state, .cancelled)
        store.retry(first)
        try await finish(store)
        XCTAssertEqual(store.jobs.first { $0.id == first }?.state, .succeeded)
        XCTAssertEqual(store.jobs.first { $0.id == first }?.attempt, 2)
    }
    func testFailureAndRecurringOptIn() async throws {
        struct Expected: Error {}
        var count = 0
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in count += 1; if count == 1 { throw Expected() }; return "Recovered" }
        let id = store.enqueue(title: "Repeat", prompt: "Work", helper: helper, repeatMinutes: 1)!
        try await finish(store)
        XCTAssertEqual(store.jobs.first?.state, .failed)
        XCTAssertTrue(store.needsAttention)
        store.tick(now: Date().addingTimeInterval(61))
        try await finish(store)
        XCTAssertEqual(store.jobs.first?.state, .succeeded)
        XCTAssertEqual(count, 2)
        store.setSchedule(id, enabled: false)
        store.tick(now: Date().addingTimeInterval(3600))
        XCTAssertEqual(count, 2)
    }
    func testCorruptArchivePreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("jobs.json")
        try Data("broken".utf8).write(to: file)
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in "" }
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.enqueue(title: "No", prompt: "No", helper: helper))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
    func testApprovalRequestStopsRepeatingSchedule() async throws {
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in "[KADDO_APPROVAL_REQUIRED] Please review the email draft." }
        _ = store.enqueue(title: "Draft", prompt: "Prepare email", helper: helper, repeatMinutes: 1)
        try await finish(store)
        XCTAssertEqual(store.jobs.first?.state, .awaitingApproval)
        XCTAssertEqual(store.jobs.first?.scheduleEnabled, false)
        XCTAssertTrue(store.needsAttention)
        XCTAssertEqual(store.jobs.first?.result, "Please review the email draft.")
    }

    func testShutdownInterruptsWithoutLateSuccess() async throws {
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in
            try? await Task.sleep(nanoseconds: 40_000_000)
            return "Late result"
        }
        _ = store.enqueue(title: "Slow", prompt: "Work", helper: helper)
        try await Task.sleep(nanoseconds: 5_000_000)
        store.shutdown()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.jobs.first?.state, .interrupted)
        XCTAssertNil(store.jobs.first?.result)
        let restored = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in XCTFail("Must not restart interrupted work"); return "" }
        XCTAssertEqual(restored.jobs.first?.state, .interrupted)
    }

    func testEachAgentRunHasSeparateOutputAndDurableHelperNotes() async throws {
        var roots: [URL] = []
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, workspace in
            roots.append(workspace)
            let notes = workspace.appendingPathComponent("notes.md")
            let saved = try String(contentsOf: notes, encoding: .utf8)
            if roots.count == 1 {
                try (saved + "\nSynthetic durable context\n").write(to: notes, atomically: true, encoding: .utf8)
                try "first output".write(to: workspace.appendingPathComponent("output/first.txt"), atomically: true, encoding: .utf8)
            } else {
                XCTAssertTrue(saved.contains("Synthetic durable context"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("output/first.txt").path))
            }
            return "Verified"
        }
        _ = store.enqueue(title: "First", prompt: "First", helper: helper)
        try await finish(store)
        _ = store.enqueue(title: "Second", prompt: "Second", helper: helper)
        try await finish(store)
        XCTAssertEqual(roots.count, 2)
        XCTAssertNotEqual(roots[0], roots[1])
        XCTAssertTrue(roots.allSatisfy { $0.path.hasPrefix(directory.path + "/Helpers/") })
    }

    func testFollowUpPreservesConversationWorkspaceAndPreviousResult() async throws {
        var seen: [AgentJob] = []
        var roots: [URL] = []
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { job, workspace in
            seen.append(job); roots.append(workspace)
            if seen.count == 1 {
                try "original".write(to: workspace.appendingPathComponent("output/original.txt"), atomically: true, encoding: .utf8)
                return "First answer"
            }
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("output/original.txt"), encoding: .utf8), "original")
            let messages = AgentJobStore.messages(for: job)
            XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
            XCTAssertEqual(messages[1].content, "Original task")
            XCTAssertEqual(messages[2].content, "First answer")
            XCTAssertEqual(messages[3].content, "Refine it")
            return "Refined answer"
        }
        let id = store.enqueue(title: "Task", prompt: "Original task", helper: helper, repeatMinutes: 10)!
        XCTAssertFalse(store.followUp(id, text: "Too soon"))
        try await finish(store)
        XCTAssertFalse(store.followUp(id, text: "  "))
        XCTAssertTrue(store.followUp(id, text: "Refine it"))
        try await finish(store)
        XCTAssertEqual(roots[0], roots[1])
        let job = try XCTUnwrap(store.jobs.first)
        XCTAssertEqual(job.history?.first?.result, "First answer")
        XCTAssertEqual(job.result, "Refined answer")
        XCTAssertEqual(job.attempt, 2)
        XCTAssertFalse(job.scheduleEnabled)
        XCTAssertEqual(try String(contentsOf: roots[0].appendingPathComponent("output/result-attempt-1.md"), encoding: .utf8), "First answer")
        let restored = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in "" }
        XCTAssertEqual(restored.jobs, store.jobs)
    }

    func testFollowUpMergesOnlyNewNotes() async throws {
        var runs = 0
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, workspace in
            runs += 1
            let notes = workspace.appendingPathComponent("notes.md")
            let saved = try String(contentsOf: notes, encoding: .utf8)
            if runs == 1 { try (saved + "\nFIRST_DURABLE_NOTE\n").write(to: notes, atomically: true, encoding: .utf8) }
            if runs == 3 { try (saved + "\nSECOND_DURABLE_NOTE\n").write(to: notes, atomically: true, encoding: .utf8) }
            return "Done"
        }
        let id = try XCTUnwrap(store.enqueue(title: "Notes", prompt: "Work", helper: helper))
        try await finish(store)
        XCTAssertTrue(store.followUp(id, text: "Review unchanged notes")); try await finish(store)
        XCTAssertTrue(store.followUp(id, text: "Add the second note")); try await finish(store)
        let merged = try String(contentsOf: directory.appendingPathComponent("Helpers/\(helper.id.uuidString)/notes.md"), encoding: .utf8)
        XCTAssertEqual(merged.components(separatedBy: "FIRST_DURABLE_NOTE").count - 1, 1)
        XCTAssertEqual(merged.components(separatedBy: "SECOND_DURABLE_NOTE").count - 1, 1)
        store.shutdown()
    }

    func testCappedNoteMergePreservesTheUnmergedTail() async throws {
        var runs = 0
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, workspace in
            runs += 1
            if runs == 1 {
                let notes = workspace.appendingPathComponent("notes.md")
                let saved = try String(contentsOf: notes, encoding: .utf8)
                try (saved + String(repeating: "§", count: 21_000) + "TAIL_NOTE").write(to: notes, atomically: true, encoding: .utf8)
            }
            return "Done"
        }
        let id = try XCTUnwrap(store.enqueue(title: "Notes", prompt: "Work", helper: helper))
        try await finish(store)
        XCTAssertTrue(store.followUp(id, text: "Continue")); try await finish(store)
        let merged = try String(contentsOf: directory.appendingPathComponent("Helpers/\(helper.id.uuidString)/notes.md"), encoding: .utf8)
        XCTAssertEqual(merged.filter { $0 == "§" }.count, 21_000)
        XCTAssertTrue(merged.contains("TAIL_NOTE"))
        store.shutdown()
    }

    func testQueuedAgentsReceiveLatestNotesWithoutOverwritingEdits() async throws {
        var releaseFirst = false
        let store = AgentJobStore(storageDirectory: directory, maximumConcurrentJobs: 1, autoStart: false) { job, workspace in
            let notes = workspace.appendingPathComponent("notes.md")
            if job.title == "First" {
                while !releaseFirst { try await Task.sleep(nanoseconds: 1_000_000) }
                let saved = try String(contentsOf: notes, encoding: .utf8)
                try (saved + "\nLATEST_DURABLE_NOTE\n").write(to: notes, atomically: true, encoding: .utf8)
            } else if job.title == "Second" {
                XCTAssertTrue(try String(contentsOf: notes, encoding: .utf8).contains("LATEST_DURABLE_NOTE"))
            } else {
                XCTAssertTrue(try String(contentsOf: notes, encoding: .utf8).contains("MANUAL_QUEUED_NOTE"))
            }
            return "Done"
        }
        _ = store.enqueue(title: "First", prompt: "Work", helper: helper)
        _ = store.enqueue(title: "Second", prompt: "Work", helper: helper)
        let thirdID = try XCTUnwrap(store.enqueue(title: "Third", prompt: "Work", helper: helper))
        let third = try XCTUnwrap(store.jobs.first { $0.id == thirdID })
        let notes = store.workspaceURL(for: third).appendingPathComponent("notes.md")
        try "MANUAL_QUEUED_NOTE".write(to: notes, atomically: true, encoding: .utf8)
        releaseFirst = true
        try await finish(store)
        XCTAssertTrue(store.jobs.allSatisfy { $0.state == .succeeded })
        let merged = try String(contentsOf: directory.appendingPathComponent("Helpers/\(helper.id.uuidString)/notes.md"), encoding: .utf8)
        XCTAssertEqual(merged.components(separatedBy: "LATEST_DURABLE_NOTE").count - 1, 1)
        store.shutdown()
    }

    func testActivityRejectsStaleAttemptsAndCancelledJobs() async throws {
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { _, _ in
            try await Task.sleep(nanoseconds: 200_000_000); return "Done"
        }
        let id = store.enqueue(title: "Work", prompt: "Work", helper: helper)!
        let event = AgentActivity(kind: "command", text: "pwd")
        store.recordActivity(event, for: id, attempt: 2)
        XCTAssertNil(store.jobs.first?.activity)
        store.recordActivity(event, for: id, attempt: 1)
        XCTAssertEqual(store.jobs.first?.activity?.count, 1)
        store.cancel(id)
        store.recordActivity(event, for: id, attempt: 1)
        XCTAssertEqual(store.jobs.first?.activity?.count, 1)
        try await finish(store)
    }

}
