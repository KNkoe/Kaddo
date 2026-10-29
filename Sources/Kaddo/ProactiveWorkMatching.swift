import Foundation

/// Work identity deliberately excludes the assigned helper and proposed output filename.
struct ProactiveWorkRecord: Codable, Equatable {
    var title: String
    var task: String
    init(title: String, task: String) {
        self.title = title
        self.task = ProactiveSuggestion.displayPrompt(task)
    }
    init(_ suggestion: ProactiveSuggestion) { self.init(title: suggestion.title, task: suggestion.task) }
}

enum ProactiveWorkMatching {
    static func blockedWork(jobs: [AgentJob]) -> [ProactiveWorkRecord] {
        jobs.flatMap { job in
            var work = [ProactiveWorkRecord]()
            if [.queued, .running, .awaitingApproval, .succeeded].contains(job.state) {
                work.append(ProactiveWorkRecord(title: job.title, task: job.prompt))
            }
            // A failed follow-up must not erase the successful work from earlier turns.
            work += (job.history ?? []).filter { $0.result != nil && $0.failure == nil }
                .map { ProactiveWorkRecord(title: job.title, task: $0.prompt) }
            return work
        }
    }

    static func unique(_ candidates: [ProactiveSuggestion], excluding: [ProactiveWorkRecord] = []) -> [ProactiveSuggestion] {
        var accepted = [ProactiveSuggestion]()
        for candidate in candidates {
            let work = ProactiveWorkRecord(candidate)
            guard !(excluding + accepted.map(ProactiveWorkRecord.init)).contains(where: { sameWork(work, $0) }) else { continue }
            accepted.append(candidate)
        }
        return accepted
    }

    static func sameWork(_ first: ProactiveWorkRecord, _ second: ProactiveWorkRecord) -> Bool {
        let a = tokens(first.task), b = tokens(second.task)
        // Explicitly different input documents, URLs, dates or versions are separate work.
        let sourcesA = sources(first.task), sourcesB = sources(second.task)
        if !sourcesA.isEmpty && !sourcesB.isEmpty && sourcesA.isDisjoint(with: sourcesB) { return false }
        if !a.isEmpty && a == b { return true }
        let numbersA = a.filter { $0.contains(where: \.isNumber) }, numbersB = b.filter { $0.contains(where: \.isNumber) }
        if !numbersA.isEmpty && !numbersB.isEmpty && numbersA != numbersB { return false }
        let titleA = tokens(first.title), titleB = tokens(second.title)
        let common = a.intersection(b).count
        let taskSimilarity = jaccard(a, b)
        if titleA.count >= 3, titleA == titleB, taskSimilarity >= 0.25 { return true }
        if min(titleA.count, titleB.count) >= 3, jaccard(titleA, titleB) >= 0.8, taskSimilarity >= 0.4 { return true }
        return common >= 6 && (taskSimilarity >= 0.65 || Double(common) / Double(max(1, min(a.count, b.count))) >= 0.88)
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
    }
    private static let ignored = Set("a an the and or to of for from in on at with by as is are be it this that these those my your our their please using use based supplied recent current concise short save output file markdown md txt json csv pdf task create write draft produce generate make include into only exact same new then do not without through".split(separator: " ").map(String.init))
    private static let aliases = ["audit":"review", "assess":"review", "inspect":"review", "check":"review", "checks":"review", "reviewing":"review", "reviewed":"review", "reviews":"review", "remaining":"unfinished", "outstanding":"unfinished", "results":"result", "outcomes":"result", "outcome":"result", "verification":"verify", "verifying":"verify", "checklist":"plan", "planning":"plan", "summary":"report", "summarize":"report", "summarise":"report", "reporting":"report", "gaps":"gap", "claims":"claim", "unsupported":"unverified", "notes":"note"]
    private static func tokens(_ value: String) -> Set<String> {
        let text = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // Output names are arbitrary; renaming a deliverable must not create another task.
        let withoutOutputs = text.replacingOccurrences(of: #"\boutput/[a-z0-9_./-]+"#, with: "", options: .regularExpression)
        return Set(withoutOutputs.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignored.contains($0) }.map { aliases[$0] ?? $0 })
    }
    private static func sources(_ value: String) -> Set<String> {
        let pattern = #"https?://[^\s)\]>\"']+|\b(?:[\w.-]+/)*[\w.-]+\.(?:md|txt|csv|json|pdf|docx|xlsx)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let text = value.lowercased()
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let source = String(text[range])
            let lead = String(text[..<range.lowerBound].suffix(80))
            let isNamedOutput = lead.range(of: #"\b(?:as|named|called|save|export|write|save to|write to)\s*$"#, options: .regularExpression) != nil
            return source.hasPrefix("output/") || isNamedOutput ? nil : source
        })
    }
}
