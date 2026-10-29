import Foundation

enum CodexExecutionStatus: String, Codable, Equatable, Sendable {
    case preparing, connecting, ready, working

    var label: String {
        switch self {
        case .preparing: return "Preparing agent"
        case .connecting: return "Starting agent"
        case .ready: return "Connected · Waiting for first activity"
        case .working: return "Working"
        }
    }
}

/// Public Codex execution updates. Private reasoning is never included.
struct AgentActivity: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var kind: String
    var text: String
    var verification: AgentVerificationVerdict? = nil
    var status: CodexExecutionStatus? = nil
}

/// Incremental JSONL decoder with bounded storage, including malformed/oversized lines.
struct AgentActivityParser {
    private var pending = Data()
    private var discardingLine = false
    private var emitted = 0
    private var publishedReady = false
    let maximumEvents: Int
    let maximumLineBytes: Int

    init(maximumEvents: Int = 200, maximumLineBytes: Int = 1_048_576) {
        self.maximumEvents = max(0, maximumEvents)
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    mutating func append(_ data: Data, final: Bool = false) -> [AgentActivity] {
        var result: [AgentActivity] = []
        for byte in data {
            if byte == 10 {
                if !discardingLine, let event = decode(pending), emitted < maximumEvents || event.kind == "mcp_tool_call" {
                    result.append(event); emitted += 1
                }
                pending.removeAll(keepingCapacity: true); discardingLine = false
            } else if !discardingLine {
                if pending.count < maximumLineBytes { pending.append(byte) }
                else { pending.removeAll(keepingCapacity: true); discardingLine = true }
            }
        }
        if final {
            if !discardingLine, !pending.isEmpty, let event = decode(pending), emitted < maximumEvents || event.kind == "mcp_tool_call" {
                result.append(event); emitted += 1
            }
            pending.removeAll(keepingCapacity: false); discardingLine = false
        }
        return result
    }

    private mutating func decode(_ data: Data) -> AgentActivity? {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let eventType = event["type"] as? String else { return nil }
        if ["thread.started", "turn.started"].contains(eventType) {
            guard !publishedReady else { return nil }
            publishedReady = true
            // Do not publish the thread identifier or any private event payload.
            return AgentActivity(kind: "status", text: CodexExecutionStatus.ready.label, status: .ready)
        }
        guard ["item.started", "item.completed"].contains(eventType),
              let item = event["item"] as? [String: Any], let type = item["type"] as? String else { return nil }
        let completed = eventType == "item.completed"
        let text: String
        var verification: AgentVerificationVerdict?
        switch type {
        case "command_execution":
            guard let command = item["command"] as? String else { return nil }
            var description = (completed ? "Finished: " : "Running: ") + String(command.prefix(1200))
            if completed, let code = item["exit_code"] as? Int { description += "\nExit status: \(code)" }
            if completed, let output = item["aggregated_output"] as? String, !output.isEmpty {
                description += "\n" + String(output.prefix(700))
            }
            text = description
        case "agent_message":
            guard completed, let message = item["text"] as? String else { return nil }
            text = message
        case "file_change":
            guard completed else { return nil }
            let changes = item["changes"] as? [[String: Any]] ?? []
            text = changes.prefix(12).compactMap { change in
                guard let path = change["path"] as? String else { return nil }
                return "\(change["kind"] as? String ?? "changed"): \(path)"
            }.joined(separator: "\n")
        case "mcp_tool_call":
            guard item["server"] as? String == "kaddo_verifier", item["tool"] as? String == "verify_task" else { return nil }
            if completed {
                let result = item["result"] as? [String: Any]
                let content = result?["content"] as? [[String: Any]] ?? []
                let verdict = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                verification = verdict.data(using: .utf8).flatMap { try? JSONDecoder().decode(AgentVerificationVerdict.self, from: $0) }
                text = "Local completion gate: " + (verdict.isEmpty ? "No verification verdict returned" : verdict)
            } else { text = "Running local completion gate…" }
        case "web_search":
            let action = item["action"] as? [String: Any] ?? [:]
            switch action["type"] as? String {
            case "open_page":
                guard let url = action["url"] as? String else { return nil }
                text = (completed ? "Read: " : "Reading: ") + url
            case "find_in_page":
                guard let pattern = action["pattern"] as? String else { return nil }
                text = (completed ? "Found in page: " : "Finding in page: ") + pattern
            default:
                let queries = action["queries"] as? [String] ?? []
                guard let query = [item["query"] as? String, action["query"] as? String, queries.isEmpty ? nil : queries.joined(separator: "; ")].compactMap({ $0 }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
                text = (completed ? "Searched: " : "Searching: ") + query
            }
        default: return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentActivity(kind: type, text: String(text.prefix(2000)), verification: verification, status: .working)
    }
}

/// Pure presentation model: a live process is not evidence that a session is ready.
enum AgentExecutionPresentation {
    static func status(for activities: [AgentActivity]) -> CodexExecutionStatus {
        activities.last?.status ?? (activities.isEmpty ? .preparing : .working)
    }
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
