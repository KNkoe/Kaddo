import Foundation
import XCTest
@testable import Kaddo

final class MotionDynamicsTests: XCTestCase {
    func testTrajectoryIsIndependentOfDisplayRefreshRate() {
        let states = [30, 60, 120].map { frameRate -> DampedValue in
            var state = DampedValue(value: 0)
            for _ in 0..<(frameRate * 2) {
                state.advance(toward: 100, elapsed: 1 / Double(frameRate))
            }
            return state
        }

        for state in states.dropFirst() {
            XCTAssertEqual(state.value, states[0].value, accuracy: 1e-9)
            XCTAssertEqual(state.velocity, states[0].velocity, accuracy: 1e-9)
        }
    }

    func testDampedSpringSettlesAtTarget() {
        var state = DampedValue(value: -30)
        for _ in 0..<180 { state.advance(toward: 42, elapsed: 1 / 60) }

        XCTAssertEqual(state.value, 42, accuracy: 0.001)
        XCTAssertEqual(state.velocity, 0, accuracy: 0.01)
    }

    func testReversingTargetRetainsPositionAndMomentum() {
        var state = DampedValue(value: 0)
        for _ in 0..<12 { state.advance(toward: 100, elapsed: 1 / 60) }
        let positionBeforeReversal = state.value
        let velocityBeforeReversal = state.velocity
        XCTAssertGreaterThan(velocityBeforeReversal, 0)

        let elapsed = 1e-5
        state.advance(toward: -100, elapsed: elapsed)

        XCTAssertEqual(state.value, positionBeforeReversal + velocityBeforeReversal * elapsed, accuracy: 1e-5)
        XCTAssertGreaterThan(state.velocity, 0, "Momentum should carry through a target reversal")
        XCTAssertEqual(state.velocity, velocityBeforeReversal, accuracy: 1)
    }

    func testCriticalDampingConvergesWithoutOvershooting() {
        var state = DampedValue(value: 0)
        var previousValue = state.value
        for _ in 0..<240 {
            state.advance(toward: 1, elapsed: 1 / 120, damping: 1)
            XCTAssertGreaterThanOrEqual(state.value, previousValue - 1e-12)
            XCTAssertLessThanOrEqual(state.value, 1 + 1e-12)
            previousValue = state.value
        }
        XCTAssertEqual(state.value, 1, accuracy: 0.001)
    }

    func testZeroAndInvalidElapsedTimeLeaveStateUnchanged() {
        let original = DampedValue(value: 4, velocity: -3)
        for elapsed in [0, -1, .infinity, .nan] {
            var state = original
            state.advance(toward: 100, elapsed: elapsed)
            XCTAssertEqual(state.value, original.value)
            XCTAssertEqual(state.velocity, original.velocity)
        }
    }

    func testInvalidAndExtremeSpringParametersStayFinite() {
        var invalid = DampedValue(value: 0)
        invalid.advance(toward: 10, elapsed: 0.1, response: .nan, damping: .infinity)
        XCTAssertTrue(invalid.value.isFinite)
        XCTAssertTrue(invalid.velocity.isFinite)

        var bounded = DampedValue(value: 0)
        bounded.advance(toward: 10, elapsed: 0.1, response: 0, damping: 20)
        XCTAssertTrue(bounded.value.isFinite)
        XCTAssertTrue(bounded.velocity.isFinite)
        XCTAssertGreaterThan(bounded.value, 0)
    }
}
