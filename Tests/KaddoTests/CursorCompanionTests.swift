import XCTest
import AppKit
@testable import Kaddo

final class CursorCompanionGeometryTests: XCTestCase {
    func testBubblePreservesHeadLocationAndFitsEveryDisplayEdge() {
        for bounds in [CGRect(x: 0, y: 30, width: 1440, height: 850), CGRect(x: -1800, y: -100, width: 1800, height: 1000)] {
            for x in [bounds.minX, bounds.midX, bounds.maxX - 45] {
                for y in [bounds.minY, bounds.midY, bounds.maxY - 45] {
                    let head = CGPoint(x: x, y: y)
                    let layout = CursorCompanionLayout.make(headOrigin: head, bounds: bounds, showingReply: true)
                    XCTAssertTrue(bounds.contains(layout.frame))
                    XCTAssertTrue(CGRect(origin: .zero, size: layout.frame.size).contains(layout.bubbleFrame))
                    XCTAssertEqual(layout.frame.minX + layout.headCenter.x, head.x + 22.5, accuracy: 0.001)
                    XCTAssertEqual(layout.frame.maxY - layout.headCenter.y, head.y + 22.5, accuracy: 0.001)
                }
            }
        }
    }
    func testBubbleFlipsBelowNearMenuBarAndDoesNotEnlargeIdleFollower() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(CursorCompanionLayout.make(headOrigin: CGPoint(x: 200, y: 20), bounds: bounds, showingReply: true).bubbleAbove)
        XCTAssertFalse(CursorCompanionLayout.make(headOrigin: CGPoint(x: 200, y: 550), bounds: bounds, showingReply: true).bubbleAbove)
        let idle = CursorCompanionLayout.make(headOrigin: CGPoint(x: 200, y: 200), bounds: bounds, showingReply: false)
        XCTAssertEqual(idle.frame.size, CGSize(width: 45, height: 45))
        XCTAssertEqual(idle.bubbleFrame, .zero)
    }
    func testShortViewportsFallBackToHeadWithoutOverflow() {
        let layout = CursorCompanionLayout.make(headOrigin: .zero, bounds: CGRect(x: 0, y: 0, width: 100, height: 80), showingReply: true)
        XCTAssertEqual(layout.frame.size, CGSize(width: 45, height: 45)); XCTAssertEqual(layout.bubbleFrame, .zero)
    }
    func testReplyIsBoundedReadableAndRevealsWithoutChangingItsContent() {
        let reply = CompanionReply(text: "## Done\nI checked **three files** and [saved the report](https://example.com/report).", createdAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(reply.text, "Done I checked three files and saved the report.")
        XCTAssertEqual(reply.visibleText(at: Date(timeIntervalSince1970: 100), reducedMotion: false), "")
        XCTAssertFalse(reply.visibleText(at: Date(timeIntervalSince1970: 100.2), reducedMotion: false).isEmpty)
        XCTAssertEqual(reply.visibleText(at: Date(timeIntervalSince1970: 100), reducedMotion: true), reply.text)
        let long = CompanionReply(text: String(repeating: "colorful 🌈 reply ", count: 100))
        XCTAssertLessThanOrEqual(long.text.count, 170); XCTAssertTrue(long.text.hasSuffix("…")); XCTAssertTrue((6...12).contains(long.duration))
        XCTAssertEqual(CompanionReply(text: "```swift\nprint(1)\n```").text, "Open Kaddo to see the full reply.")
    }
}

private final class CompanionReplyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"The short reply is ready."}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class CursorCompanionReplyTests: XCTestCase {
    func testFreshMainResponsePublishesEventWithoutReplayingSavedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompanionReplyProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let file = directory.appendingPathComponent("chats.json")
        let model = AppModel(storageURL: file, session: session, useKeychain: false)
        model.provider = "api"; model.input = "A local reply fixture"; model.send()
        for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(model.error); XCTAssertFalse(model.busy)
        XCTAssertEqual(model.companionReply?.text, "The short reply is ready.")
        XCTAssertNil(AppModel(storageURL: file, session: session, useKeychain: false).companionReply)
        let baseline = model.companionReply?.id
        model.publishCompanionReply("A helper's separate reply", helperID: UUID())
        XCTAssertEqual(model.companionReply?.id, baseline, "A helper reply must not impersonate the main cursor companion")
        model.publishCompanionReply("  \n", helperID: model.primaryHelperID)
        XCTAssertEqual(model.companionReply?.id, baseline)
    }
}
