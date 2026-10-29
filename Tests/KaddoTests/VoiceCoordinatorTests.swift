import XCTest
@testable import Kaddo

@MainActor final class VoiceCoordinatorTests: XCTestCase {
    func testCodexV3TranscriptEventsReleaseTheTurnWithoutV1ResponseEvents() {
        var turn = CodexVoiceTurn()
        turn.receiveTranscript(role: "user", done: false)
        XCTAssertFalse(turn.canAnnounce)
        turn.receiveTranscript(role: "user", done: true)
        XCTAssertFalse(turn.userSpeaking)
        XCTAssertFalse(turn.canAnnounce)
        turn.outputPlaying = true
        turn.receiveTranscript(role: "assistant", done: true)
        XCTAssertFalse(turn.responsePending)
        XCTAssertFalse(turn.canAnnounce)
        turn.outputPlaying = false
        XCTAssertTrue(turn.canAnnounce)
    }
    func testToolOnlyResponseDoesNotStrandAnnouncementsAndAudioWaitsForPlayout() {
        var turn = CodexVoiceTurn()
        turn.receive("input_audio_buffer.speech_started")
        XCTAssertFalse(turn.canAnnounce)
        turn.receive("input_audio_buffer.speech_stopped")
        turn.receive("response.created")
        turn.receive("response.done")
        XCTAssertTrue(turn.canAnnounce, "A tool-only response has no audio-buffer stopped event")
        turn.receive("response.created")
        turn.receive("output_audio_buffer.started")
        turn.receive("response.done")
        XCTAssertFalse(turn.canAnnounce, "Response generation can finish before speaker playback")
        turn.receive("output_audio_buffer.stopped")
        XCTAssertTrue(turn.canAnnounce)
        turn.receive("input_audio_buffer.speech_started")
        turn.receive("output_audio_buffer.cleared")
        XCTAssertFalse(turn.canAnnounce, "An interruption must preserve the human's active turn")
    }
    func testMutedLateSpeechCannotStrandTypedReply() {
        var turn = CodexVoiceTurn()
        turn.receiveTranscript(role: "user", done: false)
        turn.inputMuted = true
        turn.receive("input_audio_buffer.speech_started")
        turn.receiveTranscript(role: "user", done: false)
        XCTAssertFalse(turn.userSpeaking)
        turn.receiveTranscript(role: "user", done: true)
        XCTAssertTrue(turn.responsePending, "Final transcripts still reach the backing agent")
        turn.completeTypedReply()
        XCTAssertTrue(turn.canAnnounce)
        turn.inputMuted = false
        turn.receiveTranscript(role: "user", done: false)
        XCTAssertTrue(turn.userSpeaking)
        XCTAssertFalse(turn.canAnnounce)
    }
    func testSubmitBeforeConnectionPreservesInputContract() {
        let voice = CodexVoiceSession()
        XCTAssertFalse(voice.submit("Do not lose this request"))
        voice.stop()
        XCTAssertFalse(voice.submit("Stopped"))
    }
    func testPrimaryAgentSurvivesRenameAndReloadAndHomeRoutesBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.json")
        let model = AppModel(storageURL: url, useKeychain: false)
        let primary = try XCTUnwrap(model.primaryHelperID)
        model.updateHelper(id: primary, name: "My companion", instructions: "Be clear")
        model.addHelper(name: "Research", instructions: "Research facts")
        model.newConversation()
        let helperConversation = model.selectedID
        XCTAssertFalse(model.isMainAgentSelected)
        model.startVoiceConversation()
        XCTAssertFalse(model.voiceConversationEnabled)
        XCTAssertNotNil(model.error)
        model.selectMainCompanion()
        XCTAssertTrue(model.isMainAgentSelected)
        XCTAssertNotEqual(model.selectedID, helperConversation)
        XCTAssertEqual(model.selectedConversation?.helperID, primary)
        let loaded = AppModel(storageURL: url, useKeychain: false)
        XCTAssertEqual(loaded.primaryHelperID, primary)
        XCTAssertEqual(loaded.selectedHelper?.name, "My companion")
    }
    func testVoiceControlSchemasOfferOnlyBoundedCoordinatorActions() {
        let names = Set(CodexVoiceSession.tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["kaddo_agents_status", "kaddo_start_agent_task", "kaddo_screen_context", "kaddo_computer_apps", "kaddo_start_computer_task", "kaddo_start_browser_task", "kaddo_stop_computer_tasks"])
        XCTAssertTrue(CodexVoiceSession.mediaHTML.contains("echoCancellation:true"))
        XCTAssertTrue(CodexVoiceSession.mediaHTML.contains("stream.getTracks().forEach(t=>t.stop())"))
    }
}
