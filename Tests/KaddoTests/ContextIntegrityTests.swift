import XCTest
@testable import Kaddo

final class ContextIntegrityTests: XCTestCase {
    func testHistoricalImagesKeepMessageAssociationAndOmissionMarkers() throws {
        let messages = (1...6).map { ChatMessage(role: "user", content: "Turn \($0)", imagePaths: ["/synthetic/\($0).png"]) }
        let context = try CodexImageContext.prepare(messages: messages)
        XCTAssertEqual(context.paths, (3...6).map { "/synthetic/\($0).png" })
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: context.payload) as? [[String: Any]])
        XCTAssertEqual(payload[0]["omitted_image_count"] as? Int, 1)
        XCTAssertEqual(payload[1]["image_attachment_indices"] as? [Int], [])
        XCTAssertEqual(payload[2]["image_attachment_indices"] as? [Int], [1])
        XCTAssertEqual(payload[5]["image_attachment_indices"] as? [Int], [4])
        XCTAssertEqual(payload[5]["message_index"] as? Int, 6)
        XCTAssertFalse(String(decoding: context.payload, as: UTF8.self).contains("/synthetic/"))
    }
    func testRepeatedImageUsesOneAttachmentWithExplicitReferences() throws {
        let messages = [ChatMessage(role: "user", content: "First", imagePaths: ["/a.png"]), ChatMessage(role: "user", content: "Again", imagePaths: ["/a.png", "/b.png"])]
        let context = try CodexImageContext.prepare(messages: messages)
        XCTAssertEqual(context.paths, ["/a.png", "/b.png"])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: context.payload) as? [[String: Any]])
        XCTAssertEqual(payload[0]["image_attachment_indices"] as? [Int], [1])
        XCTAssertEqual(payload[1]["image_attachment_indices"] as? [Int], [1, 2])
    }
    func testCaptureNeverMatchesDifferentWindowGeometryOrTitle() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        XCTAssertTrue(DesktopController.captureWindowMatches(title: "QA", frame: frame, expectedTitle: "QA", expectedFrame: frame))
        XCTAssertFalse(DesktopController.captureWindowMatches(title: "Other", frame: frame, expectedTitle: "QA", expectedFrame: frame))
        XCTAssertFalse(DesktopController.captureWindowMatches(title: "QA", frame: CGRect(x: 200, y: 100, width: 600, height: 400), expectedTitle: "QA", expectedFrame: frame))
        let thumbnail = CGRect(x: 16, y: 327, width: 102, height: 108)
        XCTAssertTrue(DesktopController.captureWindowMatches(title: "QA", frame: thumbnail, expectedTitle: "QA", expectedFrame: frame, windowID: 42, expectedWindowID: 42))
        XCTAssertFalse(DesktopController.captureWindowMatches(title: "QA", frame: frame, expectedTitle: "QA", expectedFrame: frame, windowID: 43, expectedWindowID: 42))
        XCTAssertFalse(DesktopController.captureWindowMatches(title: "Other", frame: thumbnail, expectedTitle: "QA", expectedFrame: frame, windowID: 42, expectedWindowID: 42))
    }
}
