import XCTest
@testable import Kaddo

final class AgentVerificationTests: XCTestCase {
    func testAcceptanceRequiresTheFullLocalGateThresholds() throws {
        let valid = Data(#"{"action":"accept","p_completed":0.99,"confidence":0.95,"deterministic_evidence":true,"backend":"laya-mlx-local"}"#.utf8)
        let verdict = try JSONDecoder().decode(AgentVerificationVerdict.self, from: valid)
        XCTAssertTrue(verdict.accepted)
        var rejected = verdict; rejected.action = "escalate"; XCTAssertFalse(rejected.accepted)
        rejected = verdict; rejected.pCompleted = 0.94; XCTAssertFalse(rejected.accepted)
        rejected = verdict; rejected.confidence = 0.79; XCTAssertFalse(rejected.accepted)
        rejected = verdict; rejected.deterministicEvidence = false; XCTAssertFalse(rejected.accepted)
        rejected = verdict; rejected.backend = nil; XCTAssertFalse(rejected.accepted)
    }
    func testGateResultSurvivesThePublicActivityEventLimit() {
        var parser = AgentActivityParser(maximumEvents: 0)
        let gate = #"{"type":"item.completed","item":{"type":"mcp_tool_call","server":"kaddo_verifier","tool":"verify_task","result":{"content":[{"type":"text","text":"{\"action\":\"accept\",\"p_completed\":0.99,\"confidence\":0.95,\"deterministic_evidence\":true,\"backend\":\"laya-mlx-local\"}"}]}}}"#
        let events = parser.append(Data(gate.utf8), final: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.first?.verification?.accepted == true)
    }
}

@MainActor final class AgentVerificationFailureTests: XCTestCase {
    func testUnacceptedWorkPreservesResponseRequiresAttentionAndStopsRepeats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = AgentJobStore(storageDirectory: root, autoStart: false, executor: { _, _ in
            throw AgentVerificationError(response: "Report saved, verification needs review.", verdict: "escalate")
        })
        defer { jobs.shutdown() }
        let helper = HelperProfile(name: "Verifier", instructions: "Verify local work")
        let id = try XCTUnwrap(jobs.enqueue(title: "Unaccepted report", prompt: "Write report", helper: helper, repeatMinutes: 1))
        for _ in 0..<200 where jobs.jobs.first?.state == .running { try await Task.sleep(nanoseconds: 2_000_000) }
        let job = try XCTUnwrap(jobs.jobs.first)
        XCTAssertEqual(job.id, id)
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(jobs.needsAttention)
        XCTAssertFalse(job.scheduleEnabled)
        XCTAssertNil(job.nextRunAt)
        XCTAssertTrue(job.result?.contains("needs review") == true)
        XCTAssertTrue(job.failure?.contains("not verified complete") == true)
    }
}

final class AgentFinalVerificationTests: XCTestCase {
    private func gate(action: String = "accept", isError: Bool = false) throws -> Data {
        let receipt: [String: Any] = ["action": action, "p_completed": 0.99, "confidence": 0.95,
                                    "deterministic_evidence": true, "backend": "laya-mlx-local"]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self)
        return try line(["type": "item.completed", "item": ["type": "mcp_tool_call", "server": "kaddo_verifier", "tool": "verify_task",
                         "result": ["isError": isError, "content": [["type": "text", "text": text]]]]])
    }
    private func line(_ event: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: event) + Data([10])
    }
    private func work(_ type: String, exitCode: Int = 0, lifecycle: String = "item.completed") throws -> Data {
        try line(["type": lifecycle, "item": ["type": type, "command": "pwd", "exit_code": exitCode]])
    }
    func testAcceptedGateThenSuccessfulOrFailedCommandIsNotFinalEvidence() throws {
        for code in [0, 1] {
            var tracker = AgentFinalVerification()
            tracker.append(try gate())
            XCTAssertTrue(tracker.accepted)
            tracker.append(try work("command_execution", exitCode: code))
            XCTAssertFalse(tracker.accepted)
            XCTAssertEqual(tracker.verdictLabel, "evidence_changed_after_verification")
        }
    }
    func testStartedCommandInvalidatesWithoutWaitingForItsExit() throws {
        var tracker = AgentFinalVerification()
        tracker.append(try gate())
        tracker.append(try work("command_execution", lifecycle: "item.started"))
        XCTAssertFalse(tracker.accepted)
    }
    func testFileSearchOtherToolAndUnknownWorkInvalidate() throws {
        for type in ["file_change", "web_search", "mcp_tool_call", "future_work_type"] {
            var tracker = AgentFinalVerification()
            tracker.append(try gate())
            tracker.append(try work(type))
            XCTAssertFalse(tracker.accepted, type)
        }
    }
    func testFinalTextAndBookkeepingKeepAcceptance() throws {
        var tracker = AgentFinalVerification()
        tracker.append(try gate())
        tracker.append(try line(["type": "item.completed", "item": ["type": "agent_message", "text": "Files saved and verified."]]))
        tracker.append(try line(["type": "item.completed", "item": ["type": "todo_list", "items": []]]))
        tracker.append(try line(["type": "turn.completed"]))
        tracker.append(try line(["type": "status"]))
        XCTAssertTrue(tracker.accepted)
    }
    func testFreshGateAfterWorkRevalidatesInJSONLOrder() throws {
        var tracker = AgentFinalVerification()
        tracker.append(try gate() + work("file_change") + gate())
        XCTAssertTrue(tracker.accepted)
        var reversed = AgentFinalVerification()
        reversed.append(try gate() + gate() + work("file_change"))
        XCTAssertFalse(reversed.accepted)
    }
    func testNewRejectedUnavailableOrIncompleteGateReplacesAcceptance() throws {
        let replacements = [try gate(action: "escalate"), try gate(isError: true),
                            try line(["type": "item.started", "item": ["type": "mcp_tool_call", "server": "kaddo_verifier", "tool": "verify_task"]]),
                            try line(["type": "item.completed", "item": ["type": "mcp_tool_call", "server": "kaddo_verifier", "tool": "verify_task", "result": [:]]])]
        for replacement in replacements {
            var tracker = AgentFinalVerification()
            tracker.append(try gate())
            tracker.append(replacement)
            XCTAssertFalse(tracker.accepted)
        }
    }
    func testMalformedOversizedAndErrorEventsFailClosedAndCanBeReverified() throws {
        let uncertainEvents = [Data("not JSON\n".utf8), Data((String(repeating: "x", count: 600) + "\n").utf8),
                               try line(["type": "error"]), try line(["type": "turn.failed"])]
        for data in uncertainEvents {
            var tracker = AgentFinalVerification(maximumLineBytes: 512)
            tracker.append(try gate())
            XCTAssertTrue(tracker.accepted)
            tracker.append(data)
            XCTAssertFalse(tracker.accepted)
            tracker.append(try gate())
            XCTAssertTrue(tracker.accepted)
        }
    }
    func testWorkPastPublicHistoryLimitStillInvalidates() throws {
        var tracker = AgentFinalVerification()
        var publicHistory = AgentActivityParser(maximumEvents: 1)
        let data = try gate() + Data(String(repeating: String(decoding: work("command_execution"), as: UTF8.self), count: 300).utf8)
        _ = publicHistory.append(data)
        tracker.append(data)
        XCTAssertFalse(tracker.accepted)
    }
    func testChunkedAndUnterminatedFinalWorkCannotReuseAcceptance() throws {
        let data = try gate() + work("file_change").dropLast()
        var tracker = AgentFinalVerification()
        tracker.append(data.prefix(23))
        tracker.append(data.dropFirst(23), final: true)
        XCTAssertFalse(tracker.accepted)
    }
    func testUnreadExecutionTailCannotBeAccepted() throws {
        var tracker = AgentFinalVerification()
        tracker.append(try gate())
        tracker.markIncompleteStream()
        XCTAssertFalse(tracker.accepted)
        XCTAssertEqual(tracker.verdictLabel, "incomplete_execution_log")
    }
}
