import Foundation

struct AgentVerificationVerdict: Codable, Equatable, Sendable {
    var action: String
    var pCompleted: Double?
    var confidence: Double?
    var deterministicEvidence: Bool?
    var backend: String?
    enum CodingKeys: String, CodingKey {
        case action, confidence, backend
        case pCompleted = "p_completed", deterministicEvidence = "deterministic_evidence"
    }
    var accepted: Bool {
        action == "accept" && (pCompleted ?? 0) >= 0.95 && (confidence ?? 0) >= 0.80 && deterministicEvidence == true && backend == "laya-mlx-local"
    }
}

/// Tracks the final evidence in JSONL order independently of the bounded UI history.
/// A launched command can write files even when its name looks read-only or it exits 0.
struct AgentFinalVerification {
    private var pending = Data()
    private var discardingLine = false
    private(set) var verdict: AgentVerificationVerdict?
    private var invalidation = "unavailable"
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 1_048_576) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    var accepted: Bool { verdict?.accepted == true }
    var verdictLabel: String { verdict?.action ?? invalidation }

    mutating func markIncompleteStream() {
        verdict = nil; invalidation = "incomplete_execution_log"
    }

    mutating func append(_ data: Data, final: Bool = false) {
        for byte in data {
            if byte == 10 {
                if !discardingLine, !pending.isEmpty { observe(pending) }
                pending.removeAll(keepingCapacity: true); discardingLine = false
            } else if !discardingLine {
                if pending.count < maximumLineBytes { pending.append(byte) }
                else {
                    invalidate()
                    pending.removeAll(keepingCapacity: true); discardingLine = true
                }
            }
        }
        if final {
            if !discardingLine, !pending.isEmpty { observe(pending) }
            pending.removeAll(keepingCapacity: false); discardingLine = false
        }
    }

    private mutating func invalidate() {
        if verdict != nil { invalidation = "evidence_changed_after_verification" }
        verdict = nil
    }

    private mutating func observe(_ data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let eventType = event["type"] as? String else { invalidate(); return }
        if ["error", "turn.failed"].contains(eventType) { invalidate(); return }
        guard eventType.hasPrefix("item.") else { return }
        guard let item = event["item"] as? [String: Any], let type = item["type"] as? String else { invalidate(); return }
        if type == "mcp_tool_call", item["server"] as? String == "kaddo_verifier", item["tool"] as? String == "verify_task" {
            // A new incomplete, rejected or unreadable gate must replace an old acceptance.
            verdict = nil; invalidation = "unavailable"
            guard eventType == "item.completed" else { return }
            let result = item["result"] as? [String: Any]
            guard result?["isError"] as? Bool != true else { return }
            let content = result?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            verdict = text.data(using: .utf8).flatMap { try? JSONDecoder().decode(AgentVerificationVerdict.self, from: $0) }
            return
        }
        // Only final answer text and bookkeeping are safe after the final gate.
        // Unknown tool/work types fail closed; never classify command strings as safe.
        guard ["agent_message", "reasoning", "todo_list"].contains(type) else { invalidate(); return }
    }
}

struct AgentVerificationError: LocalizedError {
    var response: String
    var verdict: String
    var errorDescription: String? { "Local verification requires attention (\(verdict)). Review the result and continue with a follow-up; this task is not verified complete." }
}
