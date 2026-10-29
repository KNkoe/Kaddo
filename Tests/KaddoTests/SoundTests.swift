import XCTest
import CryptoKit
import AVFoundation
@testable import Kaddo

@MainActor final class SoundTests: XCTestCase {
    func testReleaseDoesNotBundleEventRecordings() {
        for event in SoundEvent.allCases { XCTAssertNil(SoundEffects.resourceURL(for: event)) }
    }
    func testSoundDefaultsAndPersistenceWithoutPlayback() throws {
        let suite = "KaddoSoundTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sounds = SoundEffects(defaults: defaults)
        XCTAssertTrue(sounds.enabled)
        XCTAssertEqual(sounds.volume, 0.35)
        sounds.enabled = false
        sounds.volume = 0.7
        let restored = SoundEffects(defaults: defaults)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.volume, 0.7)
        // Disabled playback must not instantiate a player or emit audio.
        restored.play(.send)
        XCTAssertNil(restored.lastError)
    }
    func testVolumeBounds() {
        XCTAssertEqual(SoundEffects.clampedVolume(-1), 0)
        XCTAssertEqual(SoundEffects.clampedVolume(2), 1)
        XCTAssertEqual(SoundEffects.clampedVolume(.nan), 0.35)
    }
}
