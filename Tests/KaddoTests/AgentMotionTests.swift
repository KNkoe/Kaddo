import XCTest
@testable import Kaddo

final class AgentMotionTests: XCTestCase {
    func testGazeAndAnimationStayWithinCleanFaceBounds() {
        for seed in 0..<20 {
            let identity = AgentIdentity.provisional(name: "Agent", instructions: "Research", seed: UInt64(seed) * 7919)
            let motion = AgentMotion(identity: identity)
            for frame in 0..<600 {
                let pose = motion.pose(time: Double(frame) / 30, pointer: CGSize(width: frame.isMultiple(of: 2) ? -100 : 100, height: frame.isMultiple(of: 3) ? -100 : 100))
                XCTAssertLessThanOrEqual(abs(pose.face.width), 1.8)
                XCTAssertLessThanOrEqual(abs(pose.face.height), 1.8)
                XCTAssertTrue((0...1).contains(pose.openness))
                XCTAssertLessThan(abs(pose.tilt), 1.6)
            }
        }
    }

    func testSharedEyesAndShadesUseMatchingFaceAnchors() {
        XCTAssertEqual(SculptedMascotLayout.eyeCenters, SculptedMascotLayout.lensCenters)
        XCTAssertEqual(SculptedMascotLayout.eyeCenterY, 0.38, accuracy: 0.0001)
        XCTAssertEqual(SculptedMascotLayout.mouthCenterY, 0.62, accuracy: 0.0001)
        let lensBottom = SculptedMascotLayout.eyeCenterY + SculptedMascotLayout.lensHeight / 2
        let smileTop = SculptedMascotLayout.mouthCenterY - 0.06
        XCTAssertGreaterThan(smileTop - lensBottom, 0.05, "Shades stay above the smile with a clean gap")
    }
    func testBlinkClosesAndReopensSmoothlyAndPersonalityIsStable() {
        let identity = AgentIdentity.provisional(name: "Research", instructions: "Research", seed: 871769)
        let motion = AgentMotion(identity: identity)
        let start = motion.blinkInterval - motion.phase.truncatingRemainder(dividingBy: motion.blinkInterval)
        XCTAssertEqual(motion.pose(time: start + 0.11, pointer: .zero).openness, 0, accuracy: 0.001)
        XCTAssertEqual(motion.pose(time: start + 0.23, pointer: .zero).openness, 1, accuracy: 0.001)
        var previous = motion.pose(time: start, pointer: .zero).openness
        for step in 1...230 {
            let next = motion.pose(time: start + Double(step) / 1000, pointer: .zero).openness
            XCTAssertLessThan(abs(next - previous), 0.02)
            previous = next
        }
        XCTAssertEqual(motion.pose(time: 2, pointer: .zero), AgentMotion(identity: identity).pose(time: 2, pointer: .zero))
        XCTAssertEqual(motion.pose(time: 2, pointer: CGSize(width: 9, height: -9), enabled: false), AgentMotion.Pose())
        XCTAssertGreaterThan(motion.pose(time: 2, pointer: CGSize(width: 4, height: 7)).face.height, 0)
        XCTAssertLessThan(motion.pose(time: 2, pointer: CGSize(width: -4, height: -7)).face.width, 0)
    }
}
