import XCTest
@testable import Kaddo

final class AgentResultWriterTests: XCTestCase {
    private func fixture() throws -> (root: URL, helper: UUID, job: UUID, output: URL, outside: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let helper = UUID(), job = UUID()
        let output = root.appendingPathComponent("Helpers/\(helper.uuidString)/Jobs/\(job.uuidString)/output")
        let outside = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (root, helper, job, output, outside)
    }
    func testSymlinkedOutputDirectoryCannotReceiveHostResult() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.output)
        try FileManager.default.createSymbolicLink(at: f.output, withDestinationURL: f.outside)
        XCTAssertThrowsError(try AgentResultWriter.write("Agent result", storageDirectory: f.root, helperID: f.helper, jobID: f.job, attempt: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("result-attempt-1.md").path))
    }
    func testSymlinkedResultCannotOverwriteUnrelatedFile() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let unrelated = f.outside.appendingPathComponent("original.md")
        try "Preserve original".write(to: unrelated, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: f.output.appendingPathComponent("result-attempt-1.md"), withDestinationURL: unrelated)
        XCTAssertThrowsError(try AgentResultWriter.write("Agent result", storageDirectory: f.root, helperID: f.helper, jobID: f.job, attempt: 1))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "Preserve original")
    }
    func testAtomicResultReplacementDoesNotTruncateAnExistingHardLink() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let unrelated = f.outside.appendingPathComponent("original.md")
        try "Preserve original".write(to: unrelated, atomically: true, encoding: .utf8)
        let result = f.output.appendingPathComponent("result-attempt-1.md")
        try FileManager.default.linkItem(at: unrelated, to: result)
        try AgentResultWriter.write("Agent result", storageDirectory: f.root, helperID: f.helper, jobID: f.job, attempt: 1)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "Preserve original")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "Agent result")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.output.path), ["result-attempt-1.md"])
    }
}

@MainActor final class AgentNotesBoundaryTests: XCTestCase {
    func testAgentSymlinksCannotMergePrivateDataFromEitherNotesFile() async throws {
        for filename in ["notes.md", ".notes-baseline.md"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let unrelated = root.appendingPathComponent("private-fixture.txt")
            try "PRIVATE_FIXTURE_MUST_NOT_MERGE".write(to: unrelated, atomically: true, encoding: .utf8)
            let helper = HelperProfile(name: "QA", instructions: "Test")
            let store = AgentJobStore(storageDirectory: root, autoStart: false) { _, workspace in
                let path = workspace.appendingPathComponent(filename)
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: unrelated)
                return "Completed task"
            }
            defer { store.shutdown() }
            let id = try XCTUnwrap(store.enqueue(title: "Boundary test", prompt: "Test notes", helper: helper))
            for _ in 0..<200 where store.jobs.first(where: { $0.id == id })?.state == .running {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(store.jobs.first(where: { $0.id == id })?.state, .failed)
            let notes = try XCTUnwrap(AgentResultWriter.readNotes(storageDirectory: root, helperID: helper.id))
            XCTAssertFalse(notes.contains("PRIVATE_FIXTURE"))
            XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "PRIVATE_FIXTURE_MUST_NOT_MERGE")
        }
    }
}
