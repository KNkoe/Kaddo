import Foundation
import AVFoundation
import Combine

/// Event identifiers retained for compatibility. This release is silent.
enum SoundEvent: String, CaseIterable, Sendable {
    case open = "clicky-text-open"
    case close = "clicky-text-close"
    case send = "clicky-text-send"
    case receive = "clicky-text-receive"
    case homeReveal = "home-reveal"
    case agentLaunch = "agent-launch"
    case agentDone = "agent-done"
    case needsAttention = "agent-needs-you"
    case agentClose = "agent-close"
    case listenStart = "skill-up"
    case listenStop = "skill-down"
    case connectionQuestion = "connection-question"
    case question = "clicky-question"
    case surprise = "clicky-surprised"
    case boot = "reveal-boot"
    case hatch = "hatching"
    case thumbsUp = "tapback-thumbs-up"
}

@MainActor final class SoundEffects: ObservableObject {
    static let shared = SoundEffects()
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "soundsEnabled"); if !enabled { stopAll() } } }
    @Published var volume: Double { didSet { defaults.set(Self.clampedVolume(volume), forKey: "soundsVolume") } }
    @Published private(set) var lastError: String?
    private let defaults: UserDefaults
    private var players: [UUID: AVAudioPlayer] = [:]
    private var order: [UUID] = []
    private let maximumConcurrentEffects = 4

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
        volume = defaults.object(forKey: "soundsVolume") == nil ? 0.35 : Self.clampedVolume(defaults.double(forKey: "soundsVolume"))
    }

    static func clampedVolume(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.35 }

    nonisolated static func resourceURL(for event: SoundEvent) -> URL? { nil }

    func play(_ event: SoundEvent) {
        // No third-party sound recordings are bundled in this release.
    }

    func stopAll() {
        for player in players.values { player.stop() }
        players.removeAll(); order.removeAll()
    }

    private func release(_ id: UUID, stop: Bool) {
        if stop { players[id]?.stop() }
        players[id] = nil; order.removeAll { $0 == id }
    }
}
