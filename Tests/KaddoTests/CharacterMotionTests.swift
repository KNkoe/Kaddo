import XCTest
@testable import Kaddo

final class CharacterMotionTests: XCTestCase {
    func testEveryMoodStaysInsideRestrainedFiniteBounds() {
        for mood in CharacterMood.allCases {
            for tick in 0...2400 {
                let pose = CharacterPose.sample(time: Double(tick) / 20, mood: mood, reducedMotion: false)
                XCTAssertTrue(values(pose).allSatisfy(\.isFinite))
                XCTAssertTrue((0.97...1.03).contains(pose.scaleX))
                XCTAssertTrue((0.97...1.03).contains(pose.scaleY))
                XCTAssertLessThanOrEqual(abs(pose.rotation), 8)
                XCTAssertTrue((0...1).contains(pose.eyeOpen))
                XCTAssertLessThanOrEqual(abs(pose.bob), 0.015)
            }
        }
    }

    func testReduceMotionIsStaticButPreservesExpressions() {
        for mood in CharacterMood.allCases {
            let pose = CharacterPose.sample(time: 0, mood: mood, reducedMotion: true)
            XCTAssertEqual(pose, CharacterPose.sample(time: 54.21, mood: mood, reducedMotion: true, phaseOffset: 4))
            XCTAssertEqual(pose.bob, 0)
        }
        XCTAssertEqual(CharacterPose.sample(time: 0, mood: .sleeping, reducedMotion: true).eyeOpen, 0)
        XCTAssertGreaterThan(CharacterPose.sample(time: 0, mood: .listening, reducedMotion: true).mouthOpen, 0)
    }

    func testMoodsHaveDistinctSilhouettesAndExpressions() {
        let poses = CharacterMood.allCases.map { CharacterPose.sample(time: 1.2, mood: $0, reducedMotion: false) }
        for i in poses.indices {
            for j in poses.indices where i != j { XCTAssertNotEqual(poses[i], poses[j]) }
        }
        XCTAssertGreaterThan(poses[3].smile, poses[0].smile)
        XCTAssertLessThan(poses[2].gazeY, poses[0].gazeY)
    }

    func testDoubleBlinkClosesAndReturnsToOpenEyes() {
        for midpoint in [5.275, 5.68] {
            XCTAssertEqual(CharacterPose.sample(time: midpoint, mood: .idle, reducedMotion: false).eyeOpen, 0, accuracy: 1e-12)
        }
        for time in [0.0, 5.1, 5.45, 5.8, 7.9] {
            XCTAssertEqual(CharacterPose.sample(time: time, mood: .idle, reducedMotion: false).eyeOpen, 1)
        }
    }

    func testMotionIsContinuousIncludingCycleAndBlinkBoundaries() {
        for mood in CharacterMood.allCases {
            for time in [0.0, 5.15, 5.4, 5.59, 5.77, 8, 120] {
                let before = values(CharacterPose.sample(time: time - 0.000001, mood: mood, reducedMotion: false))
                let after = values(CharacterPose.sample(time: time + 0.000001, mood: mood, reducedMotion: false))
                for (a, b) in zip(before, after) { XCTAssertEqual(a, b, accuracy: 0.00001) }
            }
        }
    }

    func testInvalidAndLargeTimesRemainFiniteAndDeterministic() {
        for time in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            for mood in CharacterMood.allCases {
                XCTAssertTrue(values(CharacterPose.sample(time: time, mood: mood, reducedMotion: false, phaseOffset: time)).allSatisfy(\.isFinite))
            }
        }
        XCTAssertEqual(CharacterPose.sample(time: .nan, mood: .idle, reducedMotion: false), CharacterPose.sample(time: 0, mood: .idle, reducedMotion: false))
        XCTAssertEqual(CharacterPose.sample(time: 0, mood: .idle, reducedMotion: false, phaseOffset: 1), CharacterPose.sample(time: 1, mood: .idle, reducedMotion: false))
    }

    func testGazeIsNeutralAtFaceCenterAndTracksDirectionOnNegativeOriginDisplay() {
        let face = CGRect(x: -950, y: -400, width: 80, height: 64)
        XCTAssertEqual(CharacterGaze.target(pointer: CGPoint(x: face.midX, y: face.midY), face: face, size: 80), .zero)
        let gaze = CharacterGaze.target(pointer: CGPoint(x: -500, y: -100), face: face, size: 80)
        XCTAssertGreaterThan(gaze.width, 0)
        XCTAssertLessThan(gaze.height, 0, "AppKit upward motion maps to SwiftUI negative y")
        XCTAssertEqual(gaze.width, 3.2, accuracy: 1e-10)
        XCTAssertEqual(gaze.height, -6, accuracy: 1e-10)
    }

    func testGazeUsesFaceRelativeCoordinatesAndIsBounded() {
        let face = CGRect(x: 20, y: 40, width: 60, height: 50)
        let pointer = CGPoint(x: 100, y: 150)
        let gaze = CharacterGaze.target(pointer: pointer, face: face, size: 60)
        let translated = CharacterGaze.target(pointer: CGPoint(x: pointer.x - 1800, y: pointer.y + 900), face: face.offsetBy(dx: -1800, dy: 900), size: 60)
        XCTAssertEqual(gaze, translated)
        let far = CharacterGaze.target(pointer: CGPoint(x: -1e10, y: 1e10), face: face, size: 60)
        XCTAssertEqual(far.width, -2.4, accuracy: 1e-10)
        XCTAssertEqual(far.height, -4.5, accuracy: 1e-10)
    }

    func testVerticalGazeRespondsAboveAndBelowWithNoticeableFaceTravel() {
        let face = CGRect(x: 500, y: 300, width: 100, height: 84)
        let above = CharacterGaze.target(pointer: CGPoint(x: face.midX, y: face.midY + 150), face: face, size: 100)
        let below = CharacterGaze.target(pointer: CGPoint(x: face.midX, y: face.midY - 150), face: face, size: 100)
        XCTAssertEqual(above.width, 0)
        XCTAssertEqual(below.width, 0)
        XCTAssertEqual(above.height, -7.5, accuracy: 1e-10)
        XCTAssertEqual(below.height, 7.5, accuracy: 1e-10)
        XCTAssertEqual(above.height, -below.height)
    }

    func testGazeEasesIntoItsLimitWithoutAVisibleHardStop() {
        let face = CGRect(x: 0, y: 0, width: 100, height: 84)
        func gaze(_ distance: CGFloat) -> CGFloat {
            CharacterGaze.target(pointer: CGPoint(x: face.midX + distance, y: face.midY), face: face, size: 100).width
        }
        let nearCenterStep = gaze(5) - gaze(0)
        let nearEdgeStep = gaze(250) - gaze(245)
        XCTAssertGreaterThan(nearCenterStep, 0)
        XCTAssertGreaterThan(nearEdgeStep, 0)
        XCTAssertLessThan(nearEdgeStep, nearCenterStep * 0.1)
        XCTAssertEqual(gaze(250), gaze(260))
        XCTAssertEqual(gaze(-100), -gaze(100), accuracy: 1e-10)
    }

    func testGazeRejectsInvalidInput() {
        let face = CGRect(x: 0, y: 0, width: 40, height: 40)
        for size: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertEqual(CharacterGaze.target(pointer: .zero, face: face, size: size), .zero)
        }
        XCTAssertEqual(CharacterGaze.target(pointer: CGPoint(x: CGFloat.nan, y: 0), face: face, size: 40), .zero)
        XCTAssertEqual(CharacterGaze.target(pointer: .zero, face: CGRect(x: CGFloat.infinity, y: 0, width: 40, height: 40), size: 40), .zero)
    }

    private func values(_ p: CharacterPose) -> [Double] {
        [p.scaleX, p.scaleY, p.rotation, p.bob, p.eyeOpen, p.mouthOpen, p.smile, p.gazeX, p.gazeY]
    }
}
