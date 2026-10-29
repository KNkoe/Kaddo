import XCTest
import AppKit
@testable import Kaddo

final class CompanionMotionTests: XCTestCase {
    func testFollowerTrajectoryMatchesAcrossRefreshRates() {
        let bounds = CGRect(x: -1200, y: -200, width: 2400, height: 1400)
        func position(hz: Int) -> CGPoint {
            var point = CGPoint(x: -500, y: 0)
            for _ in 0..<hz { point = NotchGeometry.followerPosition(pointer: CGPoint(x: 700, y: 700), previous: point, bounds: bounds, size: 45, elapsed: 1 / Double(hz)) }
            return point
        }
        let reference = position(hz: 30)
        for hz in [60, 120] {
            XCTAssertEqual(position(hz: hz).x, reference.x, accuracy: 0.00001)
            XCTAssertEqual(position(hz: hz).y, reference.y, accuracy: 0.00001)
        }
    }
    func testFollowerWholeFrameFitsNegativeOriginDisplayAtEdges() {
        let bounds = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        for pointer in [CGPoint(x: -1920, y: -300), CGPoint(x: -1, y: 779)] {
            let point = NotchGeometry.followerPosition(pointer: pointer, previous: .zero, bounds: bounds, size: 45, reduceMotion: true)
            XCTAssertGreaterThanOrEqual(point.x, bounds.minX); XCTAssertGreaterThanOrEqual(point.y, bounds.minY)
            XCTAssertLessThanOrEqual(point.x + 45, bounds.maxX); XCTAssertLessThanOrEqual(point.y + 45, bounds.maxY)
        }
    }
    func testReduceMotionSeedsAtTargetAndDoesNotDependOnElapsedTime() {
        let point = NotchGeometry.followerPosition(pointer: CGPoint(x: 200, y: 300), previous: CGPoint(x: 0, y: 0), bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), size: 45, reduceMotion: true, elapsed: 0)
        XCTAssertEqual(point, CGPoint(x: 223, y: 258))
    }
    func testGazeIsRelativeToCharacterRatherThanDisplayCenter() {
        let center = CGPoint(x: -400, y: 200)
        XCTAssertEqual(NotchGeometry.gaze(pointer: center, center: center, size: 100), .zero)
        let rightAbove = NotchGeometry.gaze(pointer: CGPoint(x: -200, y: 400), center: center, size: 100)
        XCTAssertEqual(rightAbove.width, 3.5, accuracy: 0.0001)
        XCTAssertEqual(rightAbove.height, -7.5, accuracy: 0.0001)
    }
    func testPreviewFitsSharedRowGeometryAndShrinksForOneHelper() {
        XCTAssertEqual(NotchGeometry.peekBodyHeight(helperCount: 6), 492)
        XCTAssertEqual(NotchGeometry.peekBodyHeight(helperCount: 1), 172)
        XCTAssertEqual(NotchGeometry.peekBodyHeight(helperCount: 20), 492)
    }
    func testShortPreviewKeepsHeaderAndFooterVisibleAndScrollsRows() {
        for count in [1, 3, 6, 20] {
            for available: CGFloat in [240, 360, 600] {
                let rows = NotchGeometry.peekRowsHeight(helperCount: count, availableBodyHeight: available)
                XCTAssertGreaterThan(rows, 0)
                XCTAssertLessThanOrEqual(rows + NotchGeometry.peekHeaderHeight + NotchGeometry.peekFooterHeight, available)
            }
        }
    }
    func testContentWaitsForBothShellDimensionsAndReversesWithoutState() {
        let target = CGSize(width: 914, height: 635)
        XCTAssertEqual(NotchGeometry.contentOpacity(visibleSize: CGSize(width: 914, height: 400), contentSize: target), 0)
        XCTAssertEqual(NotchGeometry.contentOpacity(visibleSize: CGSize(width: 400, height: 635), contentSize: target), 0)
        XCTAssertEqual(NotchGeometry.contentOpacity(visibleSize: target, contentSize: target), 1)
        for step in 0...100 {
            let fraction = CGFloat(step) / 100
            let value = NotchGeometry.contentOpacity(visibleSize: CGSize(width: target.width * fraction, height: target.height * fraction), contentSize: target)
            XCTAssertTrue(value.isFinite); XCTAssertTrue((0...1).contains(value))
            if fraction <= 0.84 { XCTAssertEqual(value, 0) }
        }
        XCTAssertEqual(NotchGeometry.contentOpacity(visibleSize: .zero, contentSize: .zero), 0)
    }
    func testSilhouetteRemainsFiniteAcrossPreviewWorkspaceCollapseMorph() {
        for step in 0...60 {
            let progress = CGFloat(step) / 60
            let rect = CGRect(x: 0, y: 0, width: 220 + 694 * progress, height: 39 + 596 * progress)
            let bounds = NotchSilhouette(expanded: true, expansion: min(1, (rect.height - 39) / 80), preview: 1 - progress).path(in: rect).boundingRect
            XCTAssertTrue(bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite)
            XCTAssertGreaterThan(bounds.width, 0); XCTAssertGreaterThan(bounds.height, 0)
        }
    }
}
