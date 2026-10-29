import XCTest
import AppKit
@testable import Kaddo

final class VoiceShortcutTests: XCTestCase {
    func testChordNeedsBothModifiersAndRearmsOnRelease() {
        var gate = VoiceShortcutGate()
        XCTAssertFalse(gate.update(.control))
        XCTAssertTrue(gate.update([.control, .option]))
        XCTAssertTrue(gate.update([.control, .option, .capsLock]))
        XCTAssertFalse(gate.update(.option))
        XCTAssertTrue(gate.update([.control, .option]))
    }
    func testOtherShortcutsSuppressedUntilChordReleased() {
        var gate = VoiceShortcutGate()
        XCTAssertFalse(gate.update([.control, .option, .command]))
        XCTAssertFalse(gate.update([.control, .option, .shift]))
        XCTAssertFalse(gate.update([.control, .option], keyDown: true))
        XCTAssertFalse(gate.update([.control, .option]))
        XCTAssertFalse(gate.update([]))
        XCTAssertTrue(gate.update([.control, .option]))
    }
    func testReleasingThirdModifierCannotTurnAnotherShortcutIntoVoice() {
        var gate = VoiceShortcutGate()
        XCTAssertFalse(gate.update([.control, .option, .command]))
        XCTAssertFalse(gate.update([.control, .option]))
        XCTAssertFalse(gate.update([.control, .option, .shift]))
        XCTAssertFalse(gate.update([.control, .option]))
        XCTAssertFalse(gate.update(.control))
        XCTAssertTrue(gate.update([.control, .option]))
    }
}

@MainActor final class VoiceShortcutInteractionTests: XCTestCase {
    func testReleaseBeforeHoldDelayNeverStartsVoice() async throws {
        let shortcut = VoiceShortcut(holdDelay: 20_000_000)
        var began = 0
        shortcut.onBegin = { began += 1; return true }
        shortcut.receive(flags: [.control, .option])
        shortcut.receive(flags: [])
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(began, 0)
        shortcut.stop()
    }
    func testHeldChordBeginsOnceAndReleaseOrMonitorStopEndsItOnce() async throws {
        let shortcut = VoiceShortcut(holdDelay: 0)
        var began = 0, released = 0
        shortcut.onBegin = { began += 1; return true }
        shortcut.onRelease = { released += 1 }
        shortcut.receive(flags: [.control, .option])
        try await Task.sleep(nanoseconds: 5_000_000)
        shortcut.receive(flags: [.control, .option])
        XCTAssertEqual(began, 1)
        shortcut.receive(flags: [])
        shortcut.receive(flags: [])
        XCTAssertEqual(released, 1)
        shortcut.receive(flags: [.control, .option])
        try await Task.sleep(nanoseconds: 5_000_000)
        shortcut.stop()
        XCTAssertEqual(began, 2)
        XCTAssertEqual(released, 2)
    }
    func testBusyShortcutFeedbackAndAgentCyclingPreserveDraftAndSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("model.json"), useKeychain: false)
        model.addHelper(name: "Research", instructions: "Research")
        let selected = model.selectedHelperID
        let runtime = AppRuntime(model: model, jobs: AgentJobStore(storageDirectory: directory.appendingPathComponent("jobs"), autoStart: false))
        model.busy = true
        XCTAssertFalse(runtime.beginVoiceShortcut())
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.selectedHelperID, selected)
        XCTAssertFalse(model.voiceConversationEnabled)
        model.busy = false
        model.input = "Keep this draft"
        XCTAssertFalse(runtime.beginVoiceShortcut())
        XCTAssertFalse(model.voiceConversationEnabled)
        XCTAssertEqual(model.selectedHelperID, selected)
        runtime.moveToAgent(1)
        XCTAssertEqual(model.input, "Keep this draft")
        XCTAssertEqual(model.selectedHelperID, selected)
        XCTAssertNotNil(runtime.composerFocusRequest)
        model.input = ""
        runtime.moveToAgent(1)
        XCTAssertNotEqual(model.selectedHelperID, selected)
        XCTAssertEqual(runtime.selectedTab, "Chat")
        XCTAssertFalse(runtime.showsHome)
    }
}
