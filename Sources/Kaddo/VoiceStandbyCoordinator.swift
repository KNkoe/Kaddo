import Foundation

@MainActor protocol VoiceStandbyEngine: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func prepareStandby(instructions: String)
    func matchesStandby(_ instructions: String) -> Bool
    func stop()
}

extension CodexVoiceSession: VoiceStandbyEngine {
    func prepareStandby(instructions: String) { start(instructions: instructions, history: [], standby: true) }
}

/// Owns only silent standby. Taking an engine transfers ownership to the active
/// voice session; expiry, retries and settings must never stop that active engine.
@MainActor final class VoiceStandbyCoordinator {
    private var enabled: Bool
    private var activeVoice = false
    private var terminated = false
    private var token = UUID()
    private var engine: (any VoiceStandbyEngine)?
    private var task: Task<Void, Never>?
    private var failures = 0
    private let allowed: () -> Bool
    private let instructions: () -> String
    private let makeEngine: @MainActor () -> any VoiceStandbyEngine
    private let initialDelay: TimeInterval
    private let lifetime: TimeInterval
    private let retryDelays: [TimeInterval]
    var isPreparing: Bool { task != nil || engine != nil }

    init(enabled: Bool, allowed: @escaping () -> Bool, instructions: @escaping () -> String,
         initialDelay: TimeInterval = 1, lifetime: TimeInterval = 900,
         retryDelays: [TimeInterval] = [5, 15, 30, 60, 300],
         makeEngine: (@MainActor () -> any VoiceStandbyEngine)? = nil) {
        self.enabled = enabled; self.allowed = allowed; self.instructions = instructions
        self.initialDelay = initialDelay; self.lifetime = lifetime
        self.retryDelays = retryDelays.isEmpty ? [300] : retryDelays
        self.makeEngine = makeEngine ?? { CodexVoiceSession() }
        schedule(after: initialDelay)
    }
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { invalidate() }
        else if task == nil && engine == nil { schedule(after: initialDelay) }
    }
    func take(instructions: String) -> (any VoiceStandbyEngine)? {
        activeVoice = true
        let candidate = engine
        let matches = candidate?.matchesStandby(instructions) == true
        task?.cancel(); task = nil; engine = nil; token = UUID()
        candidate?.onFailure = nil
        if !matches { candidate?.stop(); return nil }
        failures = 0
        return candidate
    }
    func resumeAfterVoice() {
        guard activeVoice else { return }
        activeVoice = false
        schedule(after: initialDelay)
    }
    func shutdown() {
        terminated = true; enabled = false
        invalidate()
    }
    private func invalidate() {
        token = UUID(); task?.cancel(); task = nil
        engine?.onFailure = nil; engine?.stop(); engine = nil
    }
    private func schedule(after delay: TimeInterval) {
        invalidate()
        guard enabled, !terminated, !activeVoice, allowed() else { return }
        let request = token
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled, self.token == request,
                  self.enabled, !self.terminated, !self.activeVoice else { return }
            guard self.allowed() else { self.task = nil; return }
            let candidate = self.makeEngine()
            self.engine = candidate
            candidate.onFailure = { [weak self] _ in
                guard let self, self.token == request else { return }
                let delay = self.retryDelays[min(self.failures, self.retryDelays.count - 1)]
                self.failures += 1
                self.schedule(after: delay)
            }
            candidate.prepareStandby(instructions: self.instructions())
            do { try await Task.sleep(nanoseconds: UInt64(max(0, self.lifetime) * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled, self.token == request, !self.activeVoice else { return }
            self.failures = 0
            self.schedule(after: self.initialDelay)
        }
    }
}
