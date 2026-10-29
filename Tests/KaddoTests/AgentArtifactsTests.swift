import XCTest
@testable import Kaddo

final class AgentArtifactsTests: XCTestCase {
    func testOnlyRealOutputFilesAreShown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "proof".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        try "private".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("linked.txt"), withDestinationURL: root.appendingPathComponent("notes.md"))
        XCTAssertEqual(AgentArtifacts.files(in: root).map(\.lastPathComponent), ["result.txt"])
    }
    func testSymlinkedOutputDirectoryIsNotExposed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "private".write(to: outside.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("output"), withDestinationURL: outside)
        XCTAssertTrue(AgentArtifacts.files(in: root).isEmpty)
    }
    func testManyTechnicalReceiptsCannotHideTheActualDeliverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for index in 1...20 { try "{}".write(to: output.appendingPathComponent("audit-\(index)-verification.json"), atomically: true, encoding: .utf8) }
        try "report".write(to: output.appendingPathComponent("z-final-report.md"), atomically: true, encoding: .utf8)
        let files = AgentArtifacts.files(in: root)
        XCTAssertEqual(files.count, 21)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "z-final-report.md" })
    }
    func testNestedDeliverablesAreFoundWithoutFollowingDirectorySymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        let reports = output.appendingPathComponent("research")
        let outside = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let report = reports.appendingPathComponent("report.md")
        try "report".write(to: report, atomically: true, encoding: .utf8)
        try "private".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: reports.appendingPathComponent("linked-file.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
        XCTAssertEqual(AgentArtifacts.files(in: root).map { $0.resolvingSymlinksInPath() }, [report.resolvingSymlinksInPath()])
    }
}
