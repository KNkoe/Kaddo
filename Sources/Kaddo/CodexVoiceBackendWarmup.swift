import Foundation

/// Prepares only the isolated backend and empty thread. No media, screen capture,
/// history, user turns or tools execute until explicit voice activation.
@MainActor final class CodexVoiceBackendWarmup {
    let bridge: CodexRealtimeBridge
    private let instructions: String
    private var task: Task<String, Error>?
    private let createdAt = Date()
    private var failed = false
    private var expiryTask: Task<Void, Never>?

    init(instructions: String, bridge suppliedBridge: CodexRealtimeBridge? = nil) {
        let bridge = suppliedBridge ?? CodexRealtimeBridge(isolatedConfiguration: true)
        self.instructions = instructions
        self.bridge = bridge
        task = Task { [weak self, bridge] in
            do {
                try await bridge.start()
                try Task.checkCancellation()
                return try await CodexVoiceSession.prepareThread(bridge: bridge, instructions: instructions)
            } catch {
                self?.failed = true
                bridge.stop()
                throw error
            }
        }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 900_000_000_000) } catch { return }
            self?.stop()
        }
    }
    func matches(_ instructions: String) -> Bool {
        !failed && task != nil && self.instructions == instructions && Date().timeIntervalSince(createdAt) < 900
    }
    func ready() async throws -> String {
        expiryTask?.cancel(); expiryTask = nil
        guard let task else { throw CancellationError() }
        return try await task.value
    }
    func stop() {
        expiryTask?.cancel(); expiryTask = nil
        task?.cancel(); task = nil
        bridge.stop()
    }
}
