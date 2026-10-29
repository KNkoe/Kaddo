import Foundation

/// Explicitly enabled only in a temporary QA bundle; never stored in user preferences.
/// Uses the real scheduler/capture/generator, an isolated archive, and a bounded request budget.
@MainActor final class ProactiveSuggestionTestMode {
    let directory: URL
    let debounce: TimeInterval
    let cooldown: TimeInterval
    let maximumChecks: Int
    private(set) var checks = 0
    let permitsAgentStart: Bool
    private(set) var agentStarts = 0
    var canStartAgent: Bool { permitsAgentStart && agentStarts == 0 }
    private var events: [[String: Any]] = []
    var storageURL: URL { directory.appendingPathComponent("proactive-agents.json") }
    init(directory: URL, debounce: TimeInterval = 4, cooldown: TimeInterval = 4, maximumChecks: Int = 6, permitsAgentStart: Bool = false) {
        self.directory = directory
        self.permitsAgentStart = permitsAgentStart
        self.debounce = max(0.01, debounce)
        self.cooldown = max(0.01, cooldown)
        self.maximumChecks = min(6, max(1, maximumChecks))
    }
    static func temporaryBundleMode() -> ProactiveSuggestionTestMode? {
        guard Bundle.main.object(forInfoDictionaryKey: "KaddoProactiveTestMode") as? Bool == true,
              Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "proactive-switch-qa" else { return nil }
        return ProactiveSuggestionTestMode(directory: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("session"), permitsAgentStart: Bundle.main.object(forInfoDictionaryKey: "KaddoProactiveTestAgentStart") as? Bool == true)
    }
    func recordAgentStart(_ title: String) {
        agentStarts += 1
        record("agent-started", titles: [title])
    }
    func consume() -> Bool {
        guard checks < maximumChecks else { return false }
        checks += 1
        return true
    }
    func record(_ event: String, token: UUID? = nil, text: String? = nil, titles: [String]? = nil) {
        var row: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970, "checks": checks]
        if let token { row["token"] = token.uuidString }
        if let text { row["text"] = String(text.prefix(2_000)) }
        if let titles { row["titles"] = titles }
        events.append(row); events = Array(events.suffix(100))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("events.json"), options: .atomic)
        } catch { NSLog("Kaddo QA evidence could not be saved: %@", error.localizedDescription) }
    }
}
