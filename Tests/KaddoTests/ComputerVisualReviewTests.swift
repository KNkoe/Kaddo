import XCTest
import AppKit
@testable import Kaddo

final class ComputerVisualReviewTests: XCTestCase {
    private func screenshot(_ color: UInt8) throws -> String {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(image.bitmapData)
        for row in 0..<2 {
            for column in 0..<2 {
                let offset = row * image.bytesPerRow + column * 4
                pixels[offset] = color; pixels[offset + 1] = 40; pixels[offset + 2] = 80; pixels[offset + 3] = 255
            }
        }
        return "data:image/png;base64," + (try XCTUnwrap(image.representation(using: .png, properties: [:]))).base64EncodedString()
    }

    func testCoordinateActionsRequireVisualReviewButIndexedActionsDoNot() {
        XCTAssertTrue(AgentComputerVisualReview.required(for: DesktopAction(type: .click, x: 1, y: 1), elementIndex: nil))
        XCTAssertTrue(AgentComputerVisualReview.required(for: DesktopAction(type: .scroll, x: 1, y: 1, scrollDelta: -1), elementIndex: nil))
        XCTAssertFalse(AgentComputerVisualReview.required(for: DesktopAction(type: .click), elementIndex: 2))
        XCTAssertFalse(AgentComputerVisualReview.required(for: DesktopAction(type: .typeText, text: "Draft"), elementIndex: nil))
    }

    func testChangedCanvasPixelsInvalidateApprovalEvenWithIdenticalAccessibilityText() throws {
        let before = NativeComputerState(text: "0 canvas", imageURL: try screenshot(10))
        let after = NativeComputerState(text: "0 canvas", imageURL: try screenshot(200))
        XCTAssertEqual(before.text, after.text)
        XCTAssertTrue(AgentComputerVisualReview.matches(reviewed: before.imageURL, current: before.imageURL))
        XCTAssertFalse(AgentComputerVisualReview.matches(reviewed: before.imageURL, current: after.imageURL))
    }

    func testMissingOrUnreadableScreenshotCannotPassVisualRevalidation() throws {
        let image = try screenshot(10)
        XCTAssertFalse(AgentComputerVisualReview.matches(reviewed: nil, current: image))
        XCTAssertFalse(AgentComputerVisualReview.matches(reviewed: image, current: nil))
        XCTAssertFalse(AgentComputerVisualReview.matches(reviewed: "data:image/png;base64,YWJj", current: "data:image/png;base64,YWJj"))
        XCTAssertNil(AgentComputerVisualReview.imageData("https://example.com/image.png"))
    }
}
