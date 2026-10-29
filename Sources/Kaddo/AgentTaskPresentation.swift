import Foundation

/// Presentation only: task state and verification decisions remain owned by the job store.
enum AgentTaskPresentation {
    static func statusLabel(for job: AgentJob) -> String {
        switch job.state {
        case .queued: return "Queued"
        case .running: return "Working"
        case .succeeded: return "Completed"
        case .awaitingApproval: return "Needs approval"
        case .cancelled: return "Stopped"
        case .interrupted: return "Interrupted"
        case .failed:
            let latestVerdict = job.activity?.last(where: { event in
                event.verification != nil && (job.startedAt.map { event.date >= $0 } ?? true)
            })?.verification
            let verificationFailure = job.failure?.contains("Local verification requires attention") == true
            return verificationFailure || latestVerdict.map({ !$0.accepted }) == true ? "Needs review" : "Failed"
        }
    }

    static func preview(for job: AgentJob, limit: Int = 150) -> String {
        if let failure = job.failure, !failure.isEmpty { return resultPreview(failure, limit: limit) }
        if job.state == .running { return AgentExecutionPresentation.status(for: job.activity ?? []).label }
        if job.state == .queued { return "Waiting for an available agent." }
        if let result = job.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resultPreview(result, limit: limit)
        }
        return job.state == .cancelled ? "This task was stopped." : "Open this task to see its conversation."
    }

    static func resultPreview(_ text: String, limit: Int = 450) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        guard limit > 1 else { return "…" }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Only generated turn transcripts and recognizable machine receipts are secondary.
    /// A user's audit/report deliverable remains prominent, regardless of its subject.
    static func isSupportingArtifact(_ file: URL) -> Bool {
        let name = file.lastPathComponent.lowercased()
        if name.range(of: #"^result-attempt-[0-9]+\.md$"#, options: .regularExpression) != nil { return true }
        guard file.pathExtension.lowercased() == "json" else { return false }
        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        if ["-resolved-history", "-resolution-ledger", "-payload-corroboration"].contains(where: stem.hasSuffix) { return true }
        return stem.range(of: #"(?:^|[-_])(?:verification|validation|coverage|evidence|receipt|receipts|proof)(?:[-_](?:final|current|corrected|v[0-9]+|[0-9]+))?$"#, options: .regularExpression) != nil
    }

    static func artifacts(_ files: [URL]) -> (primary: [URL], supporting: [URL]) {
        (files.filter { !isSupportingArtifact($0) }, files.filter(isSupportingArtifact))
    }
}
