import XCTest
@testable import Kaddo

final class VoiceReadinessTests: XCTestCase {
    func testReadinessDoesNotClaimListeningBeforeConnected() {
        var state = VoiceConnectionState()
        XCTAssertFalse(state.active)
        state.start()
        let token = state.generation
        for phase in [VoiceReadiness.authorizingMicrophone, .startingBackend, .preparingConversation, .connectingAudio] {
            XCTAssertTrue(state.advance(phase, token: token))
            XCTAssertTrue(state.readiness.isStarting)
            XCTAssertFalse(state.connected)
            XCTAssertFalse(state.idleStatus.contains("Listening"))
            XCTAssertFalse(state.readiness.title.isEmpty)
            XCTAssertFalse(state.readiness.detail.isEmpty)
        }
        XCTAssertTrue(state.advance(.ready, token: token))
        XCTAssertTrue(state.connected)
        XCTAssertEqual(state.idleStatus, "Listening · Codex voice")
    }

    func testEarlyShortcutReleaseStaysMutedThroughConnection() {
        var state = VoiceConnectionState()
        state.start()
        let token = state.generation
        XCTAssertTrue(state.setInputMuted(true))
        XCTAssertTrue(state.setInputMuted(true)) // duplicate release is idempotent
        XCTAssertFalse(state.idleStatus.contains("Microphone muted")) // still preparing
        for phase in [VoiceReadiness.startingBackend, .preparingConversation, .connectingAudio, .ready] {
            XCTAssertTrue(state.advance(phase, token: token))
            XCTAssertTrue(state.inputMuted)
        }
        XCTAssertEqual(state.idleStatus, "Microphone muted · Codex voice")
        XCTAssertTrue(state.setInputMuted(false))
        XCTAssertEqual(state.idleStatus, "Listening · Codex voice")
    }

    func testCancelledStartupCannotBecomeReadyOrChangeNewSession() {
        var state = VoiceConnectionState()
        state.start(); let old = state.generation
        XCTAssertTrue(state.advance(.startingBackend, token: old))
        state.stop()
        XCTAssertFalse(state.advance(.preparingConversation, token: old))
        XCTAssertFalse(state.setInputMuted(true))
        XCTAssertEqual(state.readiness, .off)
        state.start(); let current = state.generation
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(state.advance(.ready, token: old))
        XCTAssertEqual(state.readiness, .authorizingMicrophone)
        XCTAssertTrue(state.advance(.startingBackend, token: current))
    }

    func testReadinessCannotSkipOrRegressAndOneDeadlineCoversAllBackendPhases() {
        var state = VoiceConnectionState()
        state.start(); let token = state.generation
        XCTAssertFalse(state.requiresStartupDeadline) // system permission is user-paced
        XCTAssertFalse(state.advance(.ready, token: token))
        for phase in [VoiceReadiness.startingBackend, .preparingConversation, .connectingAudio] {
            XCTAssertTrue(state.advance(phase, token: token))
            XCTAssertTrue(state.requiresStartupDeadline)
        }
        XCTAssertFalse(state.advance(.startingBackend, token: token))
        XCTAssertTrue(state.advance(.ready, token: token))
        XCTAssertFalse(state.requiresStartupDeadline)
        XCTAssertFalse(state.advance(.connectingAudio, token: token))
        XCTAssertEqual(VoiceConnectionState.startupTimeout, 45)
    }

    func testFailurePresentationIsRecoverableAndNeverReady() {
        let state = VoiceReadiness.failed("Check your connection, then try again.")
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.isStarting)
        XCTAssertEqual(state.title, "Voice couldn't connect")
        XCTAssertEqual(state.detail, "Check your connection, then try again.")
    }
}

final class VoiceOfferGateTests: XCTestCase {
    func testAudioFirstWaitsForBackendAndStartsOnlyOnce() {
        var gate = VoiceOfferGate()
        gate.receive("sdp")
        XCTAssertEqual(gate.takeWhenBackendReady(), "sdp")
        gate.receive("duplicate")
        XCTAssertNil(gate.takeWhenBackendReady())
    }
    func testBackendFirstWaitsForAudioAndFreshSessionCanStartAgain() {
        var gate = VoiceOfferGate()
        XCTAssertNil(gate.takeWhenBackendReady())
        gate.receive("")
        XCTAssertNil(gate.takeWhenBackendReady())
        gate.receive("sdp")
        XCTAssertEqual(gate.takeWhenBackendReady(), "sdp")
        gate = VoiceOfferGate()
        gate.receive("new session")
        XCTAssertEqual(gate.takeWhenBackendReady(), "new session")
    }
}
