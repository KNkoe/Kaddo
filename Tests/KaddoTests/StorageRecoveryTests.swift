import XCTest
@testable import Kaddo

@MainActor final class StorageRecoveryTests: XCTestCase {
    func testCorruptConversationArchiveIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("chat.json")
        let original = Data("invalid-but-recoverable-file".utf8)
        try original.write(to: file)
        let model = AppModel(storageURL: file, useKeychain: false)
        model.newConversation(); model.endpoint = "https://example.test/v1"
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testHelperNotesMergeWithoutLosingOtherJobs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentJobStore(storageDirectory: dir, executor: { job, workspace in
            let file = workspace.appendingPathComponent("notes.md")
            let original = try String(contentsOf: file, encoding: .utf8)
            if job.title == "First" { try await Task.sleep(nanoseconds: 30_000_000) }
            try (original + "\nDurable note from \(job.title)\n").write(to: file, atomically: true, encoding: .utf8)
            return "Verified \(job.title)"
        })
        defer { store.shutdown() }
        let helper = HelperProfile(name: "QA", instructions: "Keep useful non-secret notes.")
        store.enqueue(title: "First", prompt: "First task", helper: helper)
        store.enqueue(title: "Second", prompt: "Second task", helper: helper)
        for _ in 0..<200 {
            if store.jobs.allSatisfy({ $0.state == .succeeded }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(store.jobs.allSatisfy { $0.state == .succeeded })
        let notes = try String(contentsOf: dir.appendingPathComponent("Helpers/\(helper.id.uuidString)/notes.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("Durable note from First"))
        XCTAssertTrue(notes.contains("Durable note from Second"))
    }
}
