import Foundation

/// Procedural personality shared by every rendering of Kaddo. Distances are
/// fractions of character size; rotation is in degrees. These are original
/// motion choices rather than recovered animation curves from another app.
struct CharacterPose: Equatable {
    var scaleX = 1.0
    var scaleY = 1.0
    var rotation = 0.0
    var bob = 0.0
    var eyeOpen = 1.0
    var mouthOpen = 0.0
    var smile = 0.025
    var gazeX = 0.0
    var gazeY = 0.0

    static func sample(time: Double, mood: CharacterMood, reducedMotion: Bool, phaseOffset: Double = 0) -> CharacterPose {
        var pose = CharacterPose()
        switch mood {
        case .idle: break
        case .listening:
            pose.scaleX = 0.99; pose.scaleY = 1.015
            pose.mouthOpen = 0.08
        case .thinking:
            pose.rotation = 4; pose.gazeX = 0.018; pose.gazeY = -0.025
        case .happy:
            pose.eyeOpen = 0.68; pose.smile = 0.095
        case .sleeping:
            pose.eyeOpen = 0; pose.smile = 0
        }
        guard !reducedMotion else { return pose }

        // Bound each operand before adding so even very large finite timestamps
        // and offsets cannot overflow. The long cycle is seamless for all waves.
        let period = 120.0
        let rawTime = time.isFinite ? time.truncatingRemainder(dividingBy: period) : 0
        let offset = phaseOffset.isFinite ? phaseOffset.truncatingRemainder(dividingBy: period) : 0
        let t = rawTime + offset
        let wave = sin(t * .pi / 2)
        let slow = sin(t * .pi / 6)
        switch mood {
        case .idle:
            pose.scaleX += wave * 0.006
            pose.scaleY -= wave * 0.009
            pose.rotation = -1.5 + slow * 1.8
            pose.bob = wave * 0.004
            pose.gazeX = sin(t * .pi / 10) * 0.008
        case .listening:
            pose.scaleX += wave * 0.004
            pose.scaleY -= wave * 0.005
            pose.rotation = sin(t * .pi) * 0.9
            pose.bob = sin(t * .pi) * 0.003
            pose.mouthOpen += (wave + 1) * 0.006
        case .thinking:
            pose.rotation += slow * 3.2
            pose.scaleX += wave * 0.004
            pose.scaleY -= wave * 0.006
            pose.bob = slow * 0.003
            pose.gazeX += slow * 0.006
        case .happy:
            let bounce = sin(t * .pi)
            pose.scaleX += bounce * 0.014
            pose.scaleY -= bounce * 0.018
            pose.rotation = sin(t * .pi / 3) * 3.2
            pose.bob = -bounce * 0.012
        case .sleeping:
            let breath = sin(t * .pi / 3)
            pose.scaleX += breath * 0.008
            pose.scaleY -= breath * 0.012
            pose.rotation = -3 + slow * 0.5
            pose.bob = breath * 0.004
        }
        if mood != .sleeping { pose.eyeOpen *= blink(at: t) }
        return pose
    }

    private static func blink(at time: Double) -> Double {
        let cycle = (time.truncatingRemainder(dividingBy: 8) + 8).truncatingRemainder(dividingBy: 8)
        // A deliberate blink followed by a quicker echo, with long quiet pauses.
        for (start, duration) in [(5.15, 0.25), (5.59, 0.18)] {
            let phase = (cycle - start) / duration
            if phase > 0 && phase < 1 {
                let closure = sin(phase * .pi)
                return 1 - closure * closure
            }
        }
        return 1
    }
}
