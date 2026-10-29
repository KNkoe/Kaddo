import XCTest
import CoreGraphics
@testable import Kaddo

@MainActor final class VoiceScreenContextTests: XCTestCase {
    private func window(_ id: UInt32, pid: Int32, frame: CGRect, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer), kCGWindowBounds as String: frame.dictionaryRepresentation]
    }
    func testProactiveCaptureUsesChosenAppWindowOnAnotherDisplayInsteadOfPointerDisplay() throws {
        let external = CGRect(x: 2400, y: -300, width: 1400, height: 900)
        let windows = [window(1, pid: 10, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                       window(2, pid: 20, frame: external), window(3, pid: 20, frame: .init(x: 0, y: 0, width: 400, height: 300))]
        let target = try XCTUnwrap(VoiceScreenContext.proactiveWindow(pid: 20, windows: windows, availableIDs: [1,2,3]))
        XCTAssertEqual(target.id, 2)
        XCTAssertEqual(target.frame, external)
    }
    func testProactiveWindowUnavailableNeverSubstitutesAnotherApp() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let windows = [window(1, pid: 10, frame: frame), window(2, pid: 20, frame: frame, layer: 20),
                       window(3, pid: 20, frame: .zero), window(4, pid: 20, frame: frame)]
        XCTAssertNil(VoiceScreenContext.proactiveWindow(pid: 20, windows: windows, availableIDs: [1,2,3]))
        XCTAssertNil(VoiceScreenContext.proactiveWindow(pid: 99, windows: windows, availableIDs: [1,2,3,4]))
        XCTAssertEqual(VoiceScreenContext.proactiveWindow(pid: 20, windows: windows, availableIDs: [1,2,3,4])?.id, 4)
    }
    func testCaptureKitFallbackOnlySelectsOneUnambiguousAppWindow() {
        let frame = CGRect(x: 100, y: 100, width: 1200, height: 800)
        XCTAssertEqual(VoiceScreenContext.singleAppWindow([(id: 42, frame: frame)])?.id, 42)
        XCTAssertNil(VoiceScreenContext.singleAppWindow([]))
        XCTAssertNil(VoiceScreenContext.singleAppWindow([(id: 42, frame: frame), (id: 43, frame: frame)]))
        XCTAssertNil(ProactiveAgentsPolicy.usableScreenText("Screen context unavailable: The active app has no unambiguous visible window."))
    }

    func testSelectedSourcePersistsAndMissingAppNeverFallsBackToAnotherApp() async throws {
        let name = "Kaddo-ScreenSource-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = ProactiveScreenSource(defaults: defaults)
        XCTAssertEqual(source.selectedAppID, "")
        source.selectedAppID = "test.kaddo.not-running.\(UUID().uuidString)"
        let restored = ProactiveScreenSource(defaults: defaults)
        XCTAssertEqual(restored.selectedAppID, source.selectedAppID)
        XCTAssertTrue(restored.sourceOptions.contains { $0.0 == source.selectedAppID })
        let text = await restored.text()
        XCTAssertTrue(text.contains("selected app is not running"))
        XCTAssertNil(ProactiveAgentsPolicy.usableScreenText(text))
    }

    func testPayloadBoundsAndAspectRatio() {
        let snapshot = VoiceScreenSnapshot(text: String(repeating: "x", count: 10_000), imageURL: nil)
        XCTAssertEqual(snapshot.text.count, 8_000)
        let localOCR = VoiceScreenContext.fittedSize(width: 3840, height: 2160, maximumDimension: 2880)
        XCTAssertEqual(localOCR.0, 2880)
        XCTAssertEqual(localOCR.1, 1620)
        let landscape = VoiceScreenContext.fittedSize(width: 3840, height: 2160)
        XCTAssertEqual(landscape.width, 1440)
        XCTAssertEqual(landscape.height, 810)
        let portrait = VoiceScreenContext.fittedSize(width: 1000, height: 2000)
        XCTAssertEqual(portrait.height, 1440)
        XCTAssertEqual(portrait.width, 720)
    }

    func testStartCapturesImmediatelyAndStopClearsMemory() async {
        var captures = 0
        let context = VoiceScreenContext(interval: 60) {
            captures += 1
            return VoiceScreenSnapshot(text: "screen", imageURL: "data:image/jpeg;base64,abc")
        }
        context.start()
        for _ in 0..<20 where context.latest == nil { await Task.yield() }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(context.latest?.text, "screen")
        context.stop()
        XCTAssertNil(context.latest)
        let afterStop = await context.refresh()
        XCTAssertNil(afterStop)
        XCTAssertEqual(captures, 1)
    }

    func testInFlightCaptureIsNotOverlappedAndStaleResultIsDiscarded() async {
        var continuation: CheckedContinuation<VoiceScreenSnapshot, Error>?
        var captures = 0
        let context = VoiceScreenContext(interval: 60) {
            captures += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        context.start()
        for _ in 0..<20 where continuation == nil { await Task.yield() }
        let overlapping = await context.refresh()
        XCTAssertNil(overlapping)
        XCTAssertEqual(captures, 1)
        context.stop()
        continuation?.resume(returning: VoiceScreenSnapshot(text: "old screen", imageURL: "old image"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(context.latest)
    }

    func testFailureReplacesPriorScreenRatherThanRetainingStaleImage() async {
        var fail = false
        let context = VoiceScreenContext(interval: 60) {
            if fail { throw NSError(domain: "Permission denied", code: 1) }
            return VoiceScreenSnapshot(text: "screen", imageURL: "image")
        }
        context.start()
        for _ in 0..<20 where context.latest == nil { await Task.yield() }
        fail = true
        let unavailable = await context.refresh()
        XCTAssertNil(unavailable?.imageURL)
        XCTAssertTrue(unavailable?.text.hasPrefix("Screen context unavailable:") == true)
        context.stop()
    }
}
