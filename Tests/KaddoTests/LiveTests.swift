import XCTest
@testable import Kaddo

@MainActor final class LiveTests: XCTestCase {
    func testCodexChatAndPersistence() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_LIVE_TESTS"] == "1" else { throw XCTSkip("Set KADDO_LIVE_TESTS=1 to test the installed signed-in Codex CLI.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chat.json")
        let model = AppModel(storageURL: file, useKeychain: false)
        model.provider = "codex"
        model.input = "Reply with exactly this text and nothing else: Kaddo connection verified"
        model.send()
        for _ in 0..<1800 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selectedConversation?.messages.last?.role, "assistant")
        XCTAssertEqual(model.selectedConversation?.messages.last?.content, "Kaddo connection verified")
        let restored = AppModel(storageURL: file, useKeychain: false)
        XCTAssertEqual(restored.selectedConversation?.messages, model.selectedConversation?.messages)
    }
    func testRealBackgroundAgentProducesFile() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_LIVE_TESTS"] == "1" else { throw XCTSkip("Set KADDO_LIVE_TESTS=1 for real background execution.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-job-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentJobStore(storageDirectory: dir)
        defer { store.shutdown() }
        let helper = HelperProfile(name: "QA helper", instructions: "Be concise. Verify files you create.")
        let id = try XCTUnwrap(store.enqueue(title: "Create QA artifact", prompt: "Create output/qa-proof.txt with exactly the text KADDO_BACKGROUND_VERIFIED. Read it back to verify. Do not inspect other folders or use network. Report the file you made.", helper: helper))
        for _ in 0..<1800 {
            if let job = store.jobs.first(where: { $0.id == id }), ![.queued, .running].contains(job.state) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let job = try XCTUnwrap(store.jobs.first { $0.id == id })
        XCTAssertEqual(job.state, .succeeded, job.failure ?? "No failure detail")
        let proof = store.workspaceURL(for: job).appendingPathComponent("output/qa-proof.txt")
        XCTAssertEqual(try String(contentsOf: proof, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "KADDO_BACKGROUND_VERIFIED")
    }

    func testRealComposioReadOnlyIntegration() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_LIVE_TESTS"] == "1" else { throw XCTSkip("Set KADDO_LIVE_TESTS=1 for real Composio read-only metadata test.") }
        let store = IntegrationStore()
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertFalse(store.connections.isEmpty)
        let account = try XCTUnwrap(store.connections.first { $0.toolkit == "googlecalendar" && $0.status.uppercased() == "ACTIVE" })
        await store.select(toolSlug: "GOOGLECALENDAR_LIST_CALENDARS")
        XCTAssertNil(store.error)
        XCTAssertNotNil(IntegrationForm.fields(from: store.schemaText))
        await store.preparePreview(argumentsJSON: "{}", account: account.alias)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.previewText.isEmpty)
        // The known test action reads calendar-list metadata only; it cannot create or modify events.
        await store.executeApproved()
        XCTAssertNil(store.error)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(store.resultText.utf8)) as? [String: Any])
        XCTAssertFalse(result.isEmpty)
        if let successful = result["successful"] as? Bool { XCTAssertTrue(successful) }
        if let success = result["success"] as? Bool { XCTAssertTrue(success) }
        if let error = result["error"] as? String { XCTAssertTrue(error.isEmpty) }
    }

    func testCodexVisionExplicitImage() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_LIVE_TESTS"] == "1" else { throw XCTSkip("Set KADDO_LIVE_TESTS=1 for real vision request.") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icon = root.appendingPathComponent(".build/Kaddo-icon.png")
        guard FileManager.default.fileExists(atPath: icon.path) else { throw XCTSkip("Run scripts/build.sh first to render the synthetic test icon.") }
        let answer = try await CodexBridge.reply(messages: [ChatMessage(role: "user", content: "What is the dominant color of the little character itself, ignoring the dark background? Reply with only the color name.", imagePaths: [icon.path])])
        XCTAssertTrue(answer.lowercased().contains("green"), "Vision response did not identify the green character")
    }

}
