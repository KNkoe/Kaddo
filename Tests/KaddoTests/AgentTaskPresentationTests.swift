import XCTest
@testable import Kaddo

final class AgentTaskPresentationTests: XCTestCase {
    private func job(_ state: AgentJob.State) -> AgentJob {
        var job = AgentJob(title: "Review", prompt: "Review the report", helperID: UUID(), helperName: "Research", helperInstructions: "Review")
        job.state = state
        return job
    }

    func testStatesNeverPromoteUnverifiedWorkToCompleted() {
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: job(.succeeded)), "Completed")
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: job(.running)), "Working")
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: job(.awaitingApproval)), "Needs approval")
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: job(.cancelled)), "Stopped")
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: job(.interrupted)), "Interrupted")
        var failed = job(.failed)
        failed.result = "Everything is complete!"
        failed.failure = "Connection closed"
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: failed), "Failed")
        failed.failure = AgentVerificationError(response: "Report ready", verdict: "escalate").localizedDescription
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: failed), "Needs review")
        XCTAssertTrue(AgentTaskPresentation.preview(for: failed).contains("verification"))
    }

    func testCurrentVerdictOverridesOldRejectedVerdictOnlyForPresentation() {
        var failed = job(.failed)
        let rejected = AgentVerificationVerdict(action: "escalate", pCompleted: 0.9, confidence: 0.8, deterministicEvidence: true, backend: "laya-mlx-local")
        var accepted = rejected; accepted.action = "accept"; accepted.pCompleted = 0.99; accepted.confidence = 0.95
        failed.activity = [AgentActivity(kind: "verification", text: "Review", verification: rejected)]
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: failed), "Needs review")
        failed.activity?.append(AgentActivity(kind: "verification", text: "Accepted", verification: accepted))
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: failed), "Failed", "An accepted gate does not erase a later task failure")
        failed.activity = [AgentActivity(date: Date(timeIntervalSince1970: 1), kind: "verification", text: "Old review", verification: rejected)]
        failed.startedAt = Date(timeIntervalSince1970: 2)
        XCTAssertEqual(AgentTaskPresentation.statusLabel(for: failed), "Failed", "A prior turn's review does not replace the current turn's failure")
    }

    func testPreviewBoundsLongUnicodeWithoutChangingOriginalResponse() {
        let original = String(repeating: "👩🏽‍💻 Useful result.\n", count: 100)
        let summary = AgentTaskPresentation.resultPreview(original, limit: 70)
        XCTAssertLessThanOrEqual(summary.count, 70)
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertTrue(original.hasPrefix(String(summary.dropLast())))
        XCTAssertEqual(AgentTaskPresentation.resultPreview(original, limit: 0), "")
        XCTAssertEqual(AgentTaskPresentation.resultPreview("short result"), "short result")
    }

    func testDeliverablesRemainPrimaryWhileKnownMachineReceiptsAreGrouped() {
        let names = ["audit-report.md", "verification-report.md", "evidence-summary.md", "customer-receipts.csv", "test-inventory.json", "test-inventory.csv", "audit-validation.json", "report-final-verification.json", "current-evidence.json", "result-attempt-12.md"]
        let urls = names.map { URL(fileURLWithPath: "/output/" + $0) }
        let groups = AgentTaskPresentation.artifacts(urls)
        XCTAssertEqual(groups.primary.map(\.lastPathComponent), Array(names.prefix(6)))
        XCTAssertEqual(groups.supporting.map(\.lastPathComponent), Array(names.suffix(4)))
        XCTAssertEqual(Set(groups.primary + groups.supporting), Set(urls), "Classification may tuck files away, never discard them")
    }
    func testResolvedVerificationHistoryIsSecondaryButOrdinaryHistoryDataStaysPrimary() {
        XCTAssertTrue(AgentTaskPresentation.isSupportingArtifact(URL(fileURLWithPath: "/output/inventory-resolved-history.json")))
        XCTAssertTrue(AgentTaskPresentation.isSupportingArtifact(URL(fileURLWithPath: "/output/checker-resolution-ledger.json")))
        XCTAssertFalse(AgentTaskPresentation.isSupportingArtifact(URL(fileURLWithPath: "/output/customer-history.json")))
        XCTAssertFalse(AgentTaskPresentation.isSupportingArtifact(URL(fileURLWithPath: "/output/history-report.md")))
    }
}
