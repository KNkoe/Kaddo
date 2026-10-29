import Foundation

/// Interruptions may replace progress, but must not erase a task's final result.
struct VoiceAgentAnnouncements {
    struct Entry { let text: String; let durable: Bool }
    private var entries: [Entry] = []
    var terminalTexts: [String] { entries.filter(\.durable).map(\.text) }
    var isEmpty: Bool { entries.isEmpty }
    mutating func append(_ text: String, durable: Bool) {
        entries.append(Entry(text: String(text.prefix(700)), durable: durable))
        while entries.filter({ !$0.durable }).count > 8, let index = entries.firstIndex(where: { !$0.durable }) { entries.remove(at: index) }
    }
    mutating func discardProgress() { entries.removeAll { !$0.durable } }
    mutating func take() -> [String] { defer { entries.removeAll() }; return entries.map(\.text) }
}
