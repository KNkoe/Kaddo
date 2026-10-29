import Foundation

/// A typed turn uses normal Codex items; its answer must be relayed to realtime.
struct CodexTypedVoiceReply {
    private(set) var waiting = false
    private var turnID: String?
    private var answer: String?
    private var discardAnswer = false
    mutating func begin() { waiting = true; turnID = nil; answer = nil; discardAnswer = false }
    mutating func discardOutput() { discardAnswer = true; answer = nil }
    mutating func bind(_ id: String?) { if waiting { turnID = id } }
    mutating func receiveItem(_ params: [String: Any]) {
        guard waiting, !discardAnswer, turnID == nil || params["turnId"] as? String == turnID,
              let item = params["item"] as? [String: Any], let text = Self.finalText(item) else { return }
        answer = text
    }
    mutating func finish(_ turn: [String: Any]) -> String? {
        guard waiting, turnID == nil || turn["id"] as? String == turnID else { return nil }
        defer { self = Self() }
        guard !discardAnswer, turn["status"] as? String == "completed" else { return nil }
        let items = turn["items"] as? [[String: Any]] ?? []
        return items.reversed().compactMap(Self.finalText).first ?? answer
    }
    private static func finalText(_ item: [String: Any]) -> String? {
        guard item["type"] as? String == "agentMessage",
              item["phase"] as? String == nil || item["phase"] as? String == "final_answer",
              let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(text.prefix(12000))
    }
}
