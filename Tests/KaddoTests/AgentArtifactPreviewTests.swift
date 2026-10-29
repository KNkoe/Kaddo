import XCTest
@testable import Kaddo

final class AgentArtifactPreviewTests: XCTestCase {
    func testExecutableAndActiveContentAlwaysUseTextEditor() {
        for name in ["run.command", "run.sh", "payload", "page.html", "image.svg", "macro.workflow", "shortcut.webloc"] {
            XCTAssertEqual(AgentArtifactPreview.application(for: URL(fileURLWithPath: name)).lastPathComponent, "TextEdit.app")
        }
        XCTAssertEqual(AgentArtifactPreview.application(for: URL(fileURLWithPath: "report.pdf")).lastPathComponent, "Preview.app")
    }
    func testSnapshotIsDataAndRejectsLeafAndParentSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = output.appendingPathComponent("test.command")
        let data = Data("echo preview-only".utf8)
        try data.write(to: file)
        let copy = try AgentArtifactPreview.snapshot(file, workspace: root)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: copy), data)
        let permissions = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let link = output.appendingPathComponent("linked.command")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AgentArtifactPreview.snapshot(link, workspace: root))
        let linkedDirectory = output.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: output)
        XCTAssertThrowsError(try AgentArtifactPreview.snapshot(linkedDirectory.appendingPathComponent("test.command"), workspace: root))
        XCTAssertThrowsError(try AgentArtifactPreview.snapshot(root.appendingPathComponent("outside.txt"), workspace: root))
    }
}
