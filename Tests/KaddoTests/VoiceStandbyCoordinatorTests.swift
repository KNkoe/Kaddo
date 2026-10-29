import XCTest
@testable import Kaddo

@MainActor final class VoiceStandbyCoordinatorTests: XCTestCase {
    final class Engine: VoiceStandbyEngine {
        var onFailure: ((String) -> Void)?
        var instructions = ""
        var stopCount = 0
        var started: (() -> Void)?
        func prepareStandby(instructions: String) { self.instructions = instructions; started?() }
        func matchesStandby(_ instructions: String) -> Bool { self.instructions == instructions && stopCount == 0 }
        func stop() { stopCount += 1 }
    }
    func testEndVoiceReplenishesAndOldExpiryCannotStopTransferredEngine() async {
        let firstReady = expectation(description: "first ready")
        let renewed = expectation(description: "after End Voice")
        var engines: [Engine] = []
        let coordinator = VoiceStandbyCoordinator(enabled: true, allowed: { true }, instructions: { "current" }, initialDelay: 0, lifetime: 0.03, makeEngine: {
            let engine = Engine(); engines.append(engine)
            engine.started = { engines.count == 1 ? firstReady.fulfill() : renewed.fulfill() }
            return engine
        })
        defer { coordinator.shutdown() }
        await fulfillment(of: [firstReady], timeout: 5)
        let active = coordinator.take(instructions: "current")
        XCTAssertTrue(active === engines[0])
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(engines[0].stopCount, 0, "Old standby expiry must not stop active voice")
        active?.stop()
        coordinator.resumeAfterVoice()
        await fulfillment(of: [renewed], timeout: 5)
        XCTAssertEqual(engines.count, 2)
    }
    func testExpiryRenewsSilentEngineAndUsesLatestInstructions() async {
        let first = expectation(description: "first")
        let second = expectation(description: "renewed after expiry")
        var style = "old", engines: [Engine] = []
        let coordinator = VoiceStandbyCoordinator(enabled: true, allowed: { true }, instructions: { style }, initialDelay: 0, lifetime: 0.05, makeEngine: {
            let e = Engine(); engines.append(e)
            e.started = { engines.count == 1 ? first.fulfill() : second.fulfill() }
            return e
        })
        defer { coordinator.shutdown() }
        await fulfillment(of: [first], timeout: 5)
        style = "new"
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(engines[0].stopCount, 1)
        XCTAssertEqual(engines[1].instructions, "new")
    }
    func testDisabledPermissionAndShutdownPreventPreparation() async {
        var allowed = false, engines: [Engine] = []
        let ready = expectation(description: "permission and setting enabled")
        let coordinator = VoiceStandbyCoordinator(enabled: false, allowed: { allowed }, instructions: { "style" }, initialDelay: 0, makeEngine: {
            let e = Engine(); engines.append(e); e.started = { ready.fulfill() }; return e
        })
        XCTAssertFalse(coordinator.isPreparing)
        coordinator.setEnabled(true)
        XCTAssertFalse(coordinator.isPreparing)
        allowed = true; coordinator.setEnabled(true)
        await fulfillment(of: [ready], timeout: 5)
        coordinator.setEnabled(false)
        XCTAssertEqual(engines[0].stopCount, 1)
        XCTAssertFalse(coordinator.isPreparing)
        coordinator.shutdown(); coordinator.setEnabled(true); coordinator.resumeAfterVoice()
        XCTAssertFalse(coordinator.isPreparing)
    }
    func testFailureRetriesAndChangedPersonaNeverReusesOldEngine() async {
        let first = expectation(description: "first")
        let retry = expectation(description: "retry")
        var engines: [Engine] = []
        let coordinator = VoiceStandbyCoordinator(enabled: true, allowed: { true }, instructions: { "style" }, initialDelay: 0, retryDelays: [0.01], makeEngine: {
            let e = Engine(); engines.append(e)
            e.started = { engines.count == 1 ? first.fulfill() : retry.fulfill() }; return e
        })
        defer { coordinator.shutdown() }
        await fulfillment(of: [first], timeout: 5)
        engines[0].onFailure?("network unavailable")
        await fulfillment(of: [retry], timeout: 5)
        XCTAssertEqual(engines[0].stopCount, 1)
        XCTAssertNil(coordinator.take(instructions: "changed style"))
        XCTAssertEqual(engines[1].stopCount, 1)
    }
    func testFastStartupSettingPersistsWithoutLaunchingTestStandby() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("model.json")
        let model = AppModel(storageURL: url, useKeychain: false)
        XCTAssertTrue(model.fastVoiceStartup)
        model.fastVoiceStartup = false
        let restored = AppModel(storageURL: url, useKeychain: false)
        XCTAssertFalse(restored.fastVoiceStartup)
    }
}
