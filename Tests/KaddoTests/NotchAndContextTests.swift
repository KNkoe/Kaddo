import XCTest
import AppKit
@testable import Kaddo

@MainActor final class NotchAndContextTests: XCTestCase {
    func testNotchTracksTopCenterAcrossDisplays() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 100, width: 1920, height: 1080)] {
            let size = NotchGeometry.collapsedSize(notchWidth: 180, safeTop: 32)
            let frame = NotchGeometry.frame(screen: screen, size: size)
            XCTAssertEqual(frame.midX, screen.midX); XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertEqual(size.width, 220); XCTAssertEqual(size.height, 39)
        }
        XCTAssertEqual(NotchGeometry.collapsedSize(notchWidth: 240, safeTop: 40), CGSize(width: 240, height: 41))
    }
    func testIdleNotchPreservesCameraWidthAndStatusAddsWings() {
        XCTAssertEqual(NotchGeometry.collapsedSize(notchWidth: 221, safeTop: 38), CGSize(width: 221, height: 39))
        XCTAssertEqual(NotchGeometry.collapsedSize(notchWidth: 221, safeTop: 38, active: true), CGSize(width: 293, height: 39))
    }
    func testFollowerTrailsPointerAndClampsToDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let point = NotchGeometry.followerPosition(pointer: CGPoint(x: 800, y: 600), previous: CGPoint(x: 100, y: 100), bounds: bounds, size: 45)
        XCTAssertGreaterThan(point.x, 100); XCTAssertLessThan(point.x, 823)
        let clamped = NotchGeometry.followerPosition(pointer: CGPoint(x: 5000, y: -5000), previous: point, bounds: bounds, size: 45)
        XCTAssertTrue(bounds.contains(clamped)); XCTAssertLessThanOrEqual(clamped.x, 955)
    }
    func testPlannerRequiresStructuredBoundedActions() throws {
        XCTAssertEqual(try DesktopPlanner.decode(#"{"actions":[{"type":"key","key":"tab"}]}"#).first?.key, "tab")
        XCTAssertEqual(try DesktopPlanner.decode("```json\n{\"actions\":[]}\n```").count, 0)
        XCTAssertThrowsError(try DesktopPlanner.decode("I clicked it"))
        XCTAssertThrowsError(try DesktopPlanner.decode(#"{"actions":[{"type":"shell","text":"echo unsafe"}]}"#))
        let actions = Array(repeating: #"{"type":"key","key":"tab"}"#, count: 6).joined(separator: ",")
        XCTAssertThrowsError(try DesktopPlanner.decode("{\"actions\":[\(actions)]}"))
    }
    func testDocumentContextTextLimitsAndErrors() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.txt")
        try "A document for Kaddo".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try DocumentContext.load(file).text, "A document for Kaddo")
        try String(repeating: "x", count: 100_001).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try DocumentContext.load(file).text.contains("truncated"))
        try Data([0, 1, 2]).write(to: file)
        XCTAssertThrowsError(try DocumentContext.load(file))
        try "".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DocumentContext.load(file))
    }
    func testAttachmentRemovalAndNewConversation() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(storageURL: dir.appendingPathComponent("chat.json"), useKeychain: false)
        model.addContext(title: "Screen", text: "Test content")
        XCTAssertEqual(model.attachments.count, 1)
        model.removeContext(model.attachments[0].id); XCTAssertTrue(model.attachments.isEmpty)
        model.addContext(title: "Document", text: "Context")
        model.newConversation(); XCTAssertTrue(model.attachments.isEmpty)
    }
    func testVisionMessageEncodingAndMissingImageFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("test.png")
        try Data([1,2,3]).write(to: path)
        let five = try AppModel.apiMessage(ChatMessage(role: "user", content: "Compare all five", imagePaths: Array(repeating: path.path, count: 5)))
        XCTAssertEqual((five["content"] as? [[String: Any]])?.count, 6, "Every accepted image must reach the provider")
        let encoded = try AppModel.apiMessage(ChatMessage(role: "user", content: "What is this?", imagePaths: [path.path]))
        let parts = try XCTUnwrap(encoded["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2); XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertThrowsError(try AppModel.apiMessage(ChatMessage(role: "user", content: "Missing", imagePaths: [dir.appendingPathComponent("missing.png").path])))
    }
}
