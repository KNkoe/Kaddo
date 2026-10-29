import XCTest
import CoreGraphics
import AppKit
import Vision
@testable import Kaddo

final class DesktopTests: XCTestCase {
    func testScrollMovesPointerBeforeWheelAtReviewedPoint() throws {
        let action = DesktopAction(type: .scroll, x: 120, y: 240, scrollDelta: -3)
        let events = try action.scrollEvents(source: nil)
        XCTAssertEqual(events.map(\.type), [.mouseMoved, .scrollWheel])
        XCTAssertEqual(events[0].location, CGPoint(x: 120, y: 240))
        XCTAssertEqual(events[1].location, CGPoint(x: 120, y: 240))
        XCTAssertEqual(events[1].getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertThrowsError(try DesktopAction(type: .scroll, x: 1, y: 2, scrollDelta: Int.min).scrollEvents(source: nil))
    }
    private let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1280, y: 0, width: 1280, height: 720)]
    func testCoordinatesMustBeOnConnectedDisplay() throws {
        XCTAssertNoThrow(try DesktopAction(type: .click, x: -100, y: 50).validate(in: displays))
        for point in [(Double.nan, 1.0), (1, Double.infinity), (3000, 20), (-100, 900)] {
            XCTAssertThrowsError(try DesktopAction(type: .click, x: point.0, y: point.1).validate(in: displays))
        }
        XCTAssertThrowsError(try DesktopAction(type: .click).validate(in: displays))
    }
    func testEmptyOCRResultsStayEmpty() { XCTAssertEqual(DesktopController.orderedOCRText([]), "") }
    func testActionValidation() throws {
        XCTAssertThrowsError(try DesktopAction(type: .typeText, text: "").validate(in: displays))
        XCTAssertThrowsError(try DesktopAction(type: .typeText, text: "bad\0input").validate(in: displays))
        XCTAssertNoThrow(try DesktopAction(type: .typeText, text: "Hello 👋").validate(in: displays))
        XCTAssertThrowsError(try DesktopAction(type: .key, key: "command-q").validate(in: displays))
        XCTAssertNoThrow(try DesktopAction(type: .key, key: "Return").validate(in: displays))
        XCTAssertThrowsError(try DesktopAction(type: .openApp, appID: "app; rm").validate(in: displays))
        XCTAssertNoThrow(try DesktopAction(type: .openApp, appID: "com.apple.TextEdit").validate(in: displays))
        XCTAssertThrowsError(try DesktopAction(type: .scroll, x: 5, y: 5, scrollDelta: Int.min).validate(in: displays))
        XCTAssertThrowsError(try DesktopAction(type: .scroll, x: 5, y: 5, scrollDelta: 0).validate(in: displays))
        XCTAssertNoThrow(try DesktopAction(type: .scroll, x: 5, y: 5, scrollDelta: -3).validate(in: displays))
    }
    func testSnapshotAndActionRoundtrip() throws {
        let snapshot = ScreenSnapshot(text: "Local screen text", appName: "Notes", windowTitle: "Draft", capturedAt: Date(timeIntervalSince1970: 0), warning: "Accessibility only")
        XCTAssertEqual(try JSONDecoder().decode(ScreenSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertTrue(snapshot.chatContext.contains("Accessibility only"))
        XCTAssertTrue(snapshot.chatContext.contains("Notes"))
        let action = DesktopAction(type: .click, x: 50, y: 75)
        XCTAssertEqual(try JSONDecoder().decode(DesktopAction.self, from: JSONEncoder().encode(action)), action)
        XCTAssertTrue(action.preview.contains("50"))
    }
    func testBlankImageHasNoInventedOCRText() async throws {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 500, height: 200))
        let image = try XCTUnwrap(context.makeImage())
        do {
            let text = try await DesktopController.recognizeTextBounded(in: image)
            XCTAssertEqual(text, "")
        } catch { throw XCTSkip("Host Vision OCR unavailable: \(error.localizedDescription)") }
    }
    @MainActor func testRenderedWindowTextIsRecognizedLocally() async throws {
        let image = NSImage(size: NSSize(width: 640, height: 160))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 160)).fill()
        ("Desktop verification" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let text = try await DesktopController.recognizeTextBounded(in: cgImage)
        XCTAssertTrue(text.lowercased().filter { !$0.isWhitespace }.contains("desktopverification"), "Actual rendered words must be recognized. Got: \(text)")
    }
    @MainActor func testInvalidApprovalCannotExecuteEvents() async {
        let controller = DesktopController()
        await controller.executeApproved(id: UUID())
        XCTAssertTrue(controller.error?.contains("no longer valid") == true)
        XCTAssertTrue(controller.audit.isEmpty)
        XCTAssertNil(controller.snapshot)
    }
}
