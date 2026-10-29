import XCTest
@testable import Kaddo

final class VoiceSessionTests: XCTestCase {
    func testExplicitStartRequired() {
        var state = VoiceSessionState()
        let token = state.generation
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(state.accepts(token))
        XCTAssertFalse(state.beginListening(token: token))
        XCTAssertFalse(state.canSubmit(token: token))
        XCTAssertFalse(state.beginSpeaking(token: token))
        XCTAssertFalse(state.finishedSpeaking(token: token))
        state.waitForReply()
        XCTAssertEqual(state.phase, .off)
    }
    func testFullConversationLifecycle() {
        var state = VoiceSessionState()
        state.start()
        let token = state.generation
        XCTAssertEqual(state.phase, .authorizing)
        XCTAssertTrue(state.enabled)
        XCTAssertFalse(state.canSubmit(token: token))
        XCTAssertTrue(state.beginListening(token: token))
        XCTAssertTrue(state.canSubmit(token: token))
        state.waitForReply()
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertFalse(state.canSubmit(token: token))
        XCTAssertTrue(state.beginSpeaking(token: token))
        XCTAssertFalse(state.canSubmit(token: token))
        XCTAssertFalse(state.beginListening(token: token))
        XCTAssertTrue(state.finishedSpeaking(token: token))
        XCTAssertEqual(state.phase, .authorizing)
        XCTAssertTrue(state.beginListening(token: token))
    }
    func testStopInvalidatesPendingPermissionAndSilenceCallbacks() {
        var state = VoiceSessionState()
        state.start(); let old = state.generation
        state.stop()
        XCTAssertFalse(state.accepts(old))
        XCTAssertFalse(state.beginListening(token: old))
        XCTAssertFalse(state.canSubmit(token: old))
        XCTAssertEqual(state.phase, .off)
    }
    func testOldPlaybackCannotRestartStoppedOrNewSession() {
        var state = VoiceSessionState()
        state.start(); let old = state.generation
        XCTAssertTrue(state.beginListening(token: old))
        state.waitForReply()
        XCTAssertTrue(state.beginSpeaking(token: old))
        state.stop()
        XCTAssertFalse(state.finishedSpeaking(token: old))
        state.start(); let current = state.generation
        XCTAssertNotEqual(current, old)
        XCTAssertFalse(state.finishedSpeaking(token: old))
        XCTAssertFalse(state.beginListening(token: old))
        XCTAssertEqual(state.phase, .authorizing)
        XCTAssertTrue(state.beginListening(token: current))
    }
    func testReplyMayOnlySpeakOnceAndNeverListenDuringPlayback() {
        var state = VoiceSessionState()
        state.start(); let token = state.generation
        XCTAssertFalse(state.beginSpeaking(token: token))
        XCTAssertTrue(state.beginListening(token: token))
        state.waitForReply()
        XCTAssertTrue(state.beginSpeaking(token: token))
        XCTAssertFalse(state.beginSpeaking(token: token))
        XCTAssertFalse(state.beginListening(token: token))
        XCTAssertFalse(state.canSubmit(token: token))
        XCTAssertTrue(state.finishedSpeaking(token: token))
        XCTAssertFalse(state.finishedSpeaking(token: token))
    }
    func testStatusReflectsLifecycle() {
        var state = VoiceSessionState()
        XCTAssertEqual(state.status, "")
        state.start(); XCTAssertEqual(state.status, "Preparing microphone…")
        let token = state.generation
        _ = state.beginListening(token: token); XCTAssertEqual(state.status, "Listening…")
        state.waitForReply(); XCTAssertEqual(state.status, "Thinking…")
        _ = state.beginSpeaking(token: token); XCTAssertEqual(state.status, "Speaking…")
        state.stop(); XCTAssertEqual(state.status, "")
    }
}
