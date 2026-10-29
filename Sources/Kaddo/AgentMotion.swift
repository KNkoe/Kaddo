import Foundation

/// One pose moves the face as a unit; blink only changes eye height inside its frame.
struct AgentMotion {
    struct Pose: Equatable {
        var face: CGSize = .zero
        var lift: Double = 0
        var tilt: Double = 0
        var openness: Double = 1
        var smileDepth: Double = 5
    }
    let seed: UInt64
    let calm: Bool
    let playful: Bool
    init(identity: AgentIdentity) {
        seed = identity.appearance.seed
        let traits = identity.traits.joined(separator: " ").lowercased()
        calm = ["calm", "patient", "methodical", "thoughtful"].contains { traits.contains($0) }
        playful = ["playful", "expressive", "inventive", "curious"].contains { traits.contains($0) }
    }
    var blinkInterval: Double { 4.2 + Double(seed % 180) / 100 + (calm ? 0.8 : 0) }
    var phase: Double { Double(seed % 997) / 997 * .pi * 2 }
    func pose(time: Double, pointer: CGSize, enabled: Bool = true) -> Pose {
        guard enabled, time.isFinite, pointer.width.isFinite, pointer.height.isFinite else { return Pose() }
        let rhythm = (calm ? 1.05 : 1.35) + Double(seed % 17) / 100
        let cycle = (max(0, time) + phase).truncatingRemainder(dividingBy: blinkInterval)
        let blinkDuration = 0.22
        let openness = cycle < blinkDuration ? 1 - pow(sin(.pi * cycle / blinkDuration), 2) : 1
        return Pose(face: CGSize(width: tanh(pointer.width / 3) * 1.8, height: tanh(pointer.height / 4) * 1.8),
                    lift: sin(time * rhythm + phase) * (calm ? 0.35 : 0.55),
                    tilt: sin(time * 0.53 + phase) * (playful ? 0.9 : 0.35) + tanh(pointer.width / 3) * 0.65,
                    openness: openness,
                    smileDepth: 5 + sin(time * 0.65 + phase) * (playful ? 0.55 : 0.2))
    }
}
