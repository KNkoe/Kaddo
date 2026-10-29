import XCTest
@testable import Kaddo

final class AgentComputerUseTests: XCTestCase {
    @MainActor func testNativeSelectorsCannotHideTypedTextInReview() throws {
        let action = DesktopAction(type: .typeText, text: "REVIEW_THIS_TEXT")
        XCTAssertThrowsError(try AgentComputerPolicy.validate(action, elementIndex: 3))
        XCTAssertNoThrow(try AgentComputerPolicy.validate(action, elementIndex: nil))
        let approval = DesktopApproval(action: action, appName: "QA", appID: "com.example.QA", pid: 1, windowTitle: "QA", focusedElement: "Input", windowID: nil, windowFrame: nil)
        let review = AgentComputerReview(jobID: UUID(), approval: approval, reason: "QA", elementIndex: 3)
        XCTAssertEqual(review.actionDescription, action.preview)
        XCTAssertTrue(review.actionDescription.contains("REVIEW_THIS_TEXT"))
        let longText = String(repeating: "A", count: 200) + "VISIBLE_END"
        let fullApproval = DesktopApproval(action: DesktopAction(type: .typeText, text: longText), appName: "QA", appID: "com.example.QA", pid: 1, windowTitle: "QA", focusedElement: "Input", windowID: nil, windowFrame: nil)
        XCTAssertTrue(AgentComputerReview(jobID: UUID(), approval: fullApproval, reason: "QA").actionDescription.hasSuffix("VISIBLE_END"))
        let scrollApproval = DesktopApproval(action: DesktopAction(type: .scroll, scrollDelta: -2), appName: "QA", appID: "com.example.QA", pid: 1, windowTitle: "QA", focusedElement: "List", windowID: nil, windowFrame: nil)
        XCTAssertEqual(AgentComputerReview(jobID: UUID(), approval: scrollApproval, reason: "QA", elementIndex: 7).actionDescription, "Scroll down 2 pages at element 7")
    }
    func testObservationIsFreshOneUseAndWrongTokensInvalidateIt() {
        var gate = AgentComputerObservation()
        let now = Date()
        let first = gate.issue(now: now)
        XCTAssertFalse(gate.consume("wrong", now: now))
        XCTAssertFalse(gate.consume(first, now: now))
        let second = gate.issue(now: now)
        XCTAssertTrue(gate.consume(second, now: now.addingTimeInterval(29)))
        XCTAssertFalse(gate.consume(second, now: now.addingTimeInterval(29)))
        XCTAssertFalse(gate.consume(gate.issue(now: now), now: now.addingTimeInterval(30)))
        let future = gate.issue(now: now.addingTimeInterval(2))
        XCTAssertFalse(gate.consume(future, now: now))
        let cancelled = gate.issue(now: now); gate.clear()
        XCTAssertFalse(gate.consume(cancelled, now: now))
    }
    func testControlPolicyRejectsUnscopedAndOversizedActions() throws {
        XCTAssertFalse(AgentComputerPolicy.validTarget("com.apple.Terminal"))
        XCTAssertFalse(AgentComputerPolicy.validTarget("com.apple.systempreferences"))
        XCTAssertFalse(AgentComputerPolicy.validTarget("app.kaddo.mac"))
        XCTAssertFalse(AgentComputerPolicy.validTarget(""))
        XCTAssertTrue(AgentComputerPolicy.validTarget("com.apple.TextEdit"))
        XCTAssertThrowsError(try AgentComputerPolicy.action(["type": "openApp", "appID": "com.apple.Terminal"]))
        XCTAssertThrowsError(try AgentComputerPolicy.action(["type": "shell", "text": "ls"]))
        XCTAssertThrowsError(try AgentComputerPolicy.action(["type": "typeText", "text": String(repeating: "a", count: 1001)]))
        let bounds = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let click = try AgentComputerPolicy.action(["type": "click", "x": 10.0, "y": 20.0])
        XCTAssertNoThrow(try click.validate(in: bounds))
        let outside = try AgentComputerPolicy.action(["type": "click", "x": 200.0, "y": 20.0])
        XCTAssertThrowsError(try outside.validate(in: bounds))
        let command = try AgentComputerPolicy.action(["type": "key", "key": "cmd+q"])
        XCTAssertThrowsError(try command.validate(in: bounds))
    }
}

@MainActor final class ComputerJobTests: XCTestCase {
    func testCancelledComputerJobHoldsSlotUntilItsExecutorUnwinds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var releaseFirst: CheckedContinuation<Void, Never>?
        var firstOpen = false, secondStarted = false, workspaceStarted = false
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { job, _ in
            if job.title == "First" {
                firstOpen = true
                await withCheckedContinuation { releaseFirst = $0 }
                firstOpen = false
            } else if job.computerTargetID != nil {
                XCTAssertFalse(firstOpen)
                secondStarted = true
            } else { workspaceStarted = true }
            return "Done"
        }
        defer { store.shutdown() }
        let helper = HelperProfile(name: "QA", instructions: "Test")
        let first = try XCTUnwrap(store.enqueue(title: "First", prompt: "One", helper: helper, computerTargetID: "com.apple.TextEdit"))
        for _ in 0..<100 where releaseFirst == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNotNil(releaseFirst)
        store.cancel(first)
        _ = store.enqueue(title: "Second", prompt: "Two", helper: helper, computerTargetID: "com.apple.TextEdit")
        _ = store.enqueue(title: "Workspace", prompt: "Three", helper: helper)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(secondStarted)
        XCTAssertTrue(workspaceStarted)
        releaseFirst?.resume(); releaseFirst = nil
        for _ in 0..<100 where !secondStarted { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(secondStarted)
    }

    func testComputerTasksSerializeWithoutBlockingWorkspaceJobsAndCannotRepeat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var computerCount = 0, maxComputerCount = 0, overlappedWorkspace = false
        let store = AgentJobStore(storageDirectory: directory, autoStart: false) { job, _ in
            if job.computerTargetID != nil {
                computerCount += 1; maxComputerCount = max(maxComputerCount, computerCount)
                defer { computerCount -= 1 }
                try await Task.sleep(nanoseconds: 70_000_000)
            } else { overlappedWorkspace = computerCount == 1 }
            return "Verified fixture"
        }
        defer { store.shutdown() }
        let helper = HelperProfile(name: "Tester", instructions: "Test")
        XCTAssertNil(store.enqueue(title: "Bad repeat", prompt: "Repeat", helper: helper, repeatMinutes: 1, computerTargetID: "com.apple.TextEdit"))
        let first = try XCTUnwrap(store.enqueue(title: "First", prompt: "One", helper: helper, computerTargetID: "com.apple.TextEdit"))
        let second = try XCTUnwrap(store.enqueue(title: "Second", prompt: "Two", helper: helper, computerTargetID: "com.apple.TextEdit"))
        _ = store.enqueue(title: "Text", prompt: "Workspace", helper: helper)
        for _ in 0..<150 {
            if !store.jobs.contains(where: { [.running, .queued].contains($0.state) }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(maxComputerCount, 1)
        XCTAssertTrue(overlappedWorkspace)
        XCTAssertEqual(store.jobs.first { $0.id == first }?.state, .succeeded)
        XCTAssertEqual(store.jobs.first { $0.id == second }?.state, .succeeded)
        let restored = AgentJobStore(storageDirectory: directory, autoStart: false)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.jobs.first { $0.id == first }?.computerTargetID, "com.apple.TextEdit")
    }
    func testQueuedComputerTaskDoesNotResumeOnLaunchAndLegacyJobsDecode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var job = AgentJob(title: "Queued", prompt: "Task", helperID: UUID(), helperName: "Agent", helperInstructions: "")
        let legacy = try JSONEncoder().encode(job)
        XCTAssertNil(try JSONDecoder().decode(AgentJob.self, from: legacy).computerTargetID)
        job.computerTargetID = "com.apple.TextEdit"
        try JSONEncoder().encode([job]).write(to: folder.appendingPathComponent("jobs.json"))
        let store = AgentJobStore(storageDirectory: folder, autoStart: false)
        defer { store.shutdown() }
        XCTAssertEqual(store.jobs.first?.state, .interrupted)
    }
}
