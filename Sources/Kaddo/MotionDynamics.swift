import Foundation

/// Position and velocity for a damped spring moving toward a target.
///
/// `response` is the undamped natural period in seconds. `damping` is the
/// damping ratio: values below one oscillate, one is critically damped, and
/// values above one are overdamped. The state is advanced analytically, so
/// the result does not depend on the display refresh rate.
struct DampedValue {
    var value: CGFloat
    var velocity: CGFloat = 0

    mutating func advance(
        toward target: CGFloat,
        elapsed: TimeInterval,
        response: TimeInterval = 0.32,
        damping: Double = 0.86
    ) {
        guard elapsed.isFinite, elapsed > 0,
              target.isFinite, value.isFinite, velocity.isFinite else { return }

        let safeResponse = response.isFinite ? min(2, max(0.04, response)) : 0.32
        let safeDamping = damping.isFinite ? min(2, max(0, damping)) : 0.86
        let omega = 2 * Double.pi / safeResponse
        let dt = elapsed
        let displacement = Double(value - target)
        let initialVelocity = Double(velocity)
        let nextDisplacement: Double
        let nextVelocity: Double

        if safeDamping < 1 - 1e-7 {
            // Underdamped solution of x'' + 2ζωx' + ω²x = 0.
            let decay = safeDamping * omega
            let frequency = omega * sqrt(1 - safeDamping * safeDamping)
            let sineCoefficient = (initialVelocity + decay * displacement) / frequency
            let cosine = cos(frequency * dt)
            let sine = sin(frequency * dt)
            let envelope = exp(-decay * dt)
            nextDisplacement = envelope * (displacement * cosine + sineCoefficient * sine)
            nextVelocity = envelope * (
                initialVelocity * cosine
                    + (-decay * sineCoefficient - frequency * displacement) * sine
            )
        } else if safeDamping <= 1 + 1e-7 {
            // Critical solution, used near ζ = 1 to avoid cancellation.
            let coefficient = initialVelocity + omega * displacement
            let envelope = exp(-omega * dt)
            nextDisplacement = envelope * (displacement + coefficient * dt)
            nextVelocity = envelope * (initialVelocity - omega * coefficient * dt)
        } else {
            // Overdamped solution using the two real characteristic roots.
            let root = sqrt(safeDamping * safeDamping - 1)
            let slowRoot = -omega * (safeDamping - root)
            let fastRoot = -omega * (safeDamping + root)
            let slowCoefficient = (initialVelocity - fastRoot * displacement) / (slowRoot - fastRoot)
            let fastCoefficient = displacement - slowCoefficient
            let slow = slowCoefficient * exp(slowRoot * dt)
            let fast = fastCoefficient * exp(fastRoot * dt)
            nextDisplacement = slow + fast
            nextVelocity = slowRoot * slow + fastRoot * fast
        }

        let nextValue = Double(target) + nextDisplacement
        guard nextValue.isFinite, nextVelocity.isFinite,
              nextValue <= Double(CGFloat.greatestFiniteMagnitude),
              nextValue >= -Double(CGFloat.greatestFiniteMagnitude),
              abs(nextVelocity) <= Double(CGFloat.greatestFiniteMagnitude) else { return }
        value = CGFloat(nextValue)
        velocity = CGFloat(nextVelocity)
    }
}
