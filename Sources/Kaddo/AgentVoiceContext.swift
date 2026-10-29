import Foundation

/// A bounded data-only view of helper work for the main agent's voice session.
/// Results are reported evidence, never instructions for the voice agent.
struct AgentVoiceContext {
    private struct Seen {
        var attempt: Int
        var states: Set<String>
        var activityID: UUID? = nil
        var phase: String? = nil
    }
    private var primed = false
    private var seen: [UUID: Seen] = [:]

    static func snapshot(_ jobs: [AgentJob]) -> String {
        let latest = jobs.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }.prefix(12)
        return json([
            "kind": "agent_job_status_data",
            "totalJobs": jobs.count,
            "jobs": latest.map { fields($0, resultLimit: 1_200) }
        ])
    }

    /// Speech is assembled locally from reported fields; helper output is never
    /// passed back through an instruction-following model to create an update.
    static func speech(_ update: String) -> String {
        let prefix = "Agent job update data: "
        guard update.hasPrefix(prefix),
              let bytes = String(update.dropFirst(prefix.count)).data(using: .utf8),
              let data = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              data["kind"] as? String == "agent_job_update_data",
              let state = data["state"] as? String,
              let helper = data["helperName"] as? String,
              let title = data["title"] as? String else { return "Agent job update." }
        let name = spoken(helper, 80)
        let task = "“\(spoken(title, 160))”"
        switch state {
        case "computerProgress":
            switch data["progressPhase"] as? String {
            case "inspecting": return "\(name) is inspecting the selected app."
            case "review": return "\(name) needs you to review a computer action in Agents."
            case "verifying": return "\(name) sent your approved input and is checking the result."
            case "blocked": return "\(name)'s computer action was blocked. Check Activity for details."
            default: return "Agent job update."
            }
        case "running": return "\(name) is working on \(task)."
        case "succeeded":
            let result = (data["reportedResult"] as? String).map { spoken($0, 480) } ?? ""
            return "\(name) finished \(task)." + (result.isEmpty ? "" : " Reported result: “\(result)”.")
        case "failed":
            let failure = (data["failure"] as? String).map { spoken($0, 300) } ?? ""
            return "\(name)'s job \(task) failed." + (failure.isEmpty ? "" : " Reported error: “\(failure)”.")
        case "awaitingApproval":
            let reason = (data["reportedResult"] as? String).map { spoken($0, 480) } ?? ""
            return "\(name)'s job \(task) needs your help." + (reason.isEmpty ? "" : " Reported reason: “\(reason)”.")
        case "interrupted": return "\(name)'s job \(task) was interrupted."
        case "cancelled": return "\(name)'s job \(task) was cancelled."
        default: return "Agent job update."
        }
    }

    static func isTerminal(_ update: String) -> Bool {
        let prefix = "Agent job update data: "
        guard update.hasPrefix(prefix), let data = String(update.dropFirst(prefix.count)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let state = object["state"] as? String else { return false }
        return ["succeeded", "failed", "awaitingApproval", "interrupted", "cancelled"].contains(state)
    }

    private static func spoken(_ text: String, _ limit: Int) -> String {
        bounded(text, limit).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Prime with the complete current job list on voice-session start, then call
    /// with fresh lists. A state is announced at most once per job attempt.
    mutating func updates(_ jobs: [AgentJob]) -> [String] {
        let currentIDs = Set(jobs.map(\.id))
        seen = seen.filter { currentIDs.contains($0.key) }
        let wasPrimed = primed
        primed = true
        var updates: [String] = []
        for job in jobs.sorted(by: { $0.createdAt < $1.createdAt }) {
            var prior = seen[job.id] ?? Seen(attempt: job.attempt, states: [])
            if prior.attempt != job.attempt { prior = Seen(attempt: job.attempt, states: []) }
            let isNew = prior.states.insert(job.state.rawValue).inserted
            if wasPrimed, job.computerTargetID != nil, job.state == .running,
               let startedAt = job.startedAt, let latest = job.activity?.last,
               latest.date >= startedAt, latest.id != prior.activityID {
                prior.activityID = latest.id
                let phase: String?
                if latest.kind == "approval" { phase = "review" }
                else if latest.text.hasPrefix("Input event submitted") { phase = "verifying" }
                else if latest.text.hasPrefix("Blocked:") { phase = "blocked" }
                else if latest.text.hasPrefix("Observed "), prior.phase == nil { phase = "inspecting" }
                else { phase = nil }
                if let phase, phase != prior.phase {
                    prior.phase = phase
                    var data = Self.fields(job, resultLimit: 0)
                    data["kind"] = "agent_job_update_data"; data["state"] = "computerProgress"; data["progressPhase"] = phase
                    updates.append("Agent job update data: " + Self.json(data))
                }
            }
            seen[job.id] = prior
            guard wasPrimed, isNew, let status = Self.message(job.state) else { continue }
            var data = Self.fields(job, resultLimit: 480)
            data["kind"] = "agent_job_update_data"
            data["message"] = status
            updates.append("Agent job update data: " + Self.json(data))
        }
        return updates
    }

    private static func message(_ state: AgentJob.State) -> String? {
        switch state {
        case .queued: return nil
        case .running: return "The agent is working on this job."
        case .succeeded: return "The job finished. Its reported result is included as data."
        case .failed: return "The job failed."
        case .awaitingApproval: return "The job is waiting for your approval."
        case .interrupted: return "The job was interrupted."
        case .cancelled: return "The job was cancelled."
        }
    }

    private static func fields(_ job: AgentJob, resultLimit: Int) -> [String: Any] {
        var data: [String: Any] = [
            "id": job.id.uuidString,
            "helperID": job.helperID.uuidString,
            "title": bounded(job.title, 160),
            "helperName": bounded(job.helperName, 80),
            "state": job.state.rawValue,
            "attempt": job.attempt
        ]
        if let result = job.result, job.state == .succeeded || job.state == .awaitingApproval {
            data["reportedResult"] = bounded(result, resultLimit)
        }
        if let target = job.computerTargetID { data["computerAppID"] = target; data["mode"] = "computer" }
        if let failure = job.failure { data["failure"] = bounded(failure, 300) }
        return data
    }

    private static func bounded(_ text: String, _ count: Int) -> String {
        String(text.prefix(count))
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"kind\":\"agent_job_status_data\",\"jobs\":[]}"
        }
        return string
    }
}
