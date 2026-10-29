import XCTest
@testable import Kaddo

final class ProactiveWorkMatchingTests: XCTestCase {
    private func suggestion(_ title: String, _ task: String, helper: UUID = UUID()) -> ProactiveSuggestion {
        ProactiveSuggestion(title: title, reason: "Useful follow-up", task: task, helperID: helper, dedupeID: UUID().uuidString)
    }

    func testSameTaskAcrossHelpersAndRephrasedTitleIsOneSuggestion() {
        let first = suggestion("Review MoPay homepage", "Review the MoPay homepage for unsupported claims and unclear onboarding copy.")
        let second = suggestion("Audit MoPay homepage", "Audit the MoPay homepage for unverified claims and unclear onboarding copy.")
        XCTAssertNotEqual(first.helperID, second.helperID)
        XCTAssertEqual(ProactiveWorkMatching.unique([first, second]).count, 1)
    }

    func testExistingDuplicateQAPlansIgnoreRenamedOutputFiles() {
        let first = suggestion("Plan remaining Kaddo QA checks", "Save a concise QA checklist as output/kaddo-qa-checklist.md using the supplied recent outcomes. Cover exact input replacement, stopping before Apply, cancellation, and app approval errors. Specify expected results and evidence needed for each check. Distinguish observed failures from unverified behavior. Do not run desktop actions.")
        let second = suggestion("Plan remaining Kaddo QA checks", "Save output/kaddo-qa-verification-plan.md with a concise checklist based only on the supplied outcomes: exact-value replacement appended text, stopping left text entered without applying, a cancellation lacks verification evidence, app approval blocked one attempt, and sandbox restrictions blocked the report’s completion gate. Distinguish observed results from unknowns and specify evidence needed for each future check. Do not execute checks or repeat the existing QA report.")
        XCTAssertEqual(ProactiveWorkMatching.unique([first, second]).count, 1)
        let namedA = suggestion("Review MoPay homepage", "Review the MoPay homepage for unsupported claims and unclear onboarding copy. Save as copy-review.md")
        let namedB = suggestion("Audit MoPay homepage", "Audit the MoPay homepage for unverified claims and unclear onboarding copy. Save as homepage-audit.md")
        XCTAssertEqual(ProactiveWorkMatching.unique([namedA, namedB]).count, 1)
    }

    func testDifferentSourceDocumentsURLsDatesAndGenuineFollowUpsRemainDistinct() {
        for pair in [
            ("Review invoice.md for missing tax fields.", "Review invoice.txt for missing tax fields."),
            ("Review the invoice in source-a.pdf for missing tax fields.", "Review the invoice in source-b.pdf for missing tax fields."),
            ("Review homepage copy at https://mopay.co.ls for clarity.", "Review homepage copy at https://example.com for clarity."),
            ("Review merchant activity for October 21 and report failures.", "Review merchant activity for October 22 and report failures.")
        ] {
            XCTAssertEqual(ProactiveWorkMatching.unique([suggestion("Review source content", pair.0), suggestion("Review source content", pair.1)]).count, 2)
        }
        let report = suggestion("Report Kaddo QA gaps", "Write a report summarizing the recorded Kaddo voice and computer QA outcomes.")
        let followUp = suggestion("Plan remaining Kaddo QA checks", "Write a checklist specifying expected results and evidence for exact input replacement and cancellation checks.")
        XCTAssertFalse(ProactiveWorkMatching.sameWork(ProactiveWorkRecord(report), ProactiveWorkRecord(followUp)))
    }

    func testSuccessfulHistoryAndOlderCompletedJobsBlockReplaysButFailuresDoNot() {
        let completed = suggestion("Review MoPay homepage", "Review the MoPay homepage for unsupported claims and unclear onboarding copy.")
        var job = AgentJob(title: completed.title, prompt: completed.agentPrompt, helperID: UUID(), helperName: "Other helper", helperInstructions: "")
        job.state = .succeeded
        var later = (0..<8).map { index in
            var other = job; other.id = UUID(); other.title = "Other task \(index)"; other.prompt = "Different task number \(index)"; return other
        }
        later.append(job)
        XCTAssertTrue(ProactiveWorkMatching.unique([completed], excluding: ProactiveWorkMatching.blockedWork(jobs: later)).isEmpty)
        let rephrased = suggestion("Audit MoPay homepage", "Audit the MoPay homepage for unverified claims and unclear onboarding copy.")
        XCTAssertTrue(ProactiveWorkMatching.unique([rephrased], excluding: ProactiveWorkMatching.blockedWork(jobs: later)).isEmpty)
        job.state = .failed
        XCTAssertEqual(ProactiveWorkMatching.unique([completed], excluding: ProactiveWorkMatching.blockedWork(jobs: [job])).count, 1)
        job.history = [AgentJobExchange(prompt: completed.agentPrompt, result: "Completed", attempt: 1)]
        job.prompt = "Failed follow-up"
        XCTAssertTrue(ProactiveWorkMatching.unique([completed], excluding: ProactiveWorkMatching.blockedWork(jobs: [job])).isEmpty)
    }

    func testAttachedScreenTextCannotMakeDifferentTasksMatch() {
        let first = ProactiveWorkRecord(title: "Review homepage", task: "Review the MoPay homepage copy." + ProactiveSuggestion.sourceContextMarker + String(repeating: "shared screen words ", count: 100))
        let second = ProactiveWorkRecord(title: "Plan invoice checks", task: "Plan invoice validation checks for tax fields." + ProactiveSuggestion.sourceContextMarker + String(repeating: "shared screen words ", count: 100))
        XCTAssertFalse(ProactiveWorkMatching.sameWork(first, second))
    }
}

@MainActor final class ProactiveReplayControllerTests: XCTestCase {
    func testCompletedWorkWhileGeneratorWaitsIsNotOfferedAndLegacyDuplicatesArePruned() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let helper = try XCTUnwrap(model.helpers.first)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs"), autoStart: false, executor: { _, _ in "Completed report" })
        defer { jobs.shutdown() }
        let title = "Review MoPay homepage", task = "Review the MoPay homepage for unsupported claims and unclear onboarding copy."
        let data = try JSONSerialization.data(withJSONObject: ["suggestions": [["title": title, "reason": "Visible copy can be clearer.", "task": task, "helper_id": helper.id.uuidString]]])
        let response = String(decoding: data, as: UTF8.self)
        let url = folder.appendingPathComponent("suggestions.json")
        let original = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "screen" }, onStart: { _ in true }, storageURL: url, generator: { _ in response }, presentsWindow: false)
        await original.checkNow()
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rows = try XCTUnwrap(archive["suggestions"] as? [[String: Any]])
        var duplicate = try XCTUnwrap(rows.first)
        duplicate["id"] = UUID().uuidString; duplicate["helperID"] = UUID().uuidString; duplicate["dedupeID"] = "legacy-other-helper"
        rows.append(duplicate); archive["suggestions"] = rows
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        let restored = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "screen" }, onStart: { _ in true }, storageURL: url, generator: { _ in response }, presentsWindow: false)
        XCTAssertEqual(restored.pendingCount, 1)
        original.stop(); restored.stop()
        let waitingURL = folder.appendingPathComponent("waiting.json")
        var reply: CheckedContinuation<String, Never>?
        let waiting = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "screen" }, onStart: { _ in XCTFail("Never auto-start"); return false }, storageURL: waitingURL, generator: { _ in await withCheckedContinuation { reply = $0 } }, presentsWindow: false)
        let checking = Task { await waiting.checkNow() }
        for _ in 0..<100 where reply == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let jobID = try XCTUnwrap(jobs.enqueue(title: title, prompt: task, helper: helper))
        for _ in 0..<100 where jobs.jobs.first(where: { $0.id == jobID })?.state != .succeeded { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(jobs.jobs.first(where: { $0.id == jobID })?.state, .succeeded)
        let continuation = try XCTUnwrap(reply); continuation.resume(returning: response)
        await checking.value
        XCTAssertEqual(waiting.pendingCount, 0)
        waiting.stop()
    }

    func testRephrasedDismissalStaysSuppressedAfterRelaunchAndStartRechecksJobs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let helper = try XCTUnwrap(model.helpers.first)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs"), autoStart: false, executor: { _, _ in "Done" })
        defer { jobs.shutdown() }
        let storage = folder.appendingPathComponent("suggestions.json")
        var title = "Review MoPay homepage", task = "Review the MoPay homepage for unsupported claims and unclear onboarding copy."
        var starts = 0
        func make() -> ProactiveAgentsController {
            ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "screen" }, onStart: { _ in starts += 1; return true }, storageURL: storage,
                generator: { messages in
                    XCTAssertTrue(messages[1].content.contains("do_not_repeat_work"))
                    let data = try JSONSerialization.data(withJSONObject: ["suggestions": [["title": title, "reason": "Visible homepage needs a copy review.", "task": task, "helper_id": helper.id.uuidString]]])
                    return String(decoding: data, as: UTF8.self)
                }, presentsWindow: false)
        }
        let first = make(); await first.checkNow()
        first.dismiss(try XCTUnwrap(first.suggestions.first?.id)); first.stop()
        title = "Audit MoPay homepage"; task = "Audit the MoPay homepage for unverified claims and unclear onboarding copy."
        let restored = make(); await restored.checkNow()
        XCTAssertTrue(restored.suggestions.isEmpty)
        title = "Draft MoPay launch checklist"; task = "Draft a merchant launch checklist covering sandbox setup and production access."
        await restored.checkNow()
        let pending = try XCTUnwrap(restored.suggestions.first)
        _ = jobs.enqueue(title: title, prompt: task, helper: helper)
        restored.markStarted(pending.id)
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(restored.suggestions.isEmpty)
        restored.stop()
    }
}
