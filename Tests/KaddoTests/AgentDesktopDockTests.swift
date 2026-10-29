import XCTest
@testable import Kaddo

final class AgentDesktopDockTests: XCTestCase {
    func testActiveStatesGroupToOnePortraitAndPreferRunningJob() {
        let helper = profile("Research")
        let running = job(helper, state: .running, createdAt: date(30))
        let queued = job(helper, state: .queued, createdAt: date(40))
        let awaiting = job(helper, state: .awaitingApproval, createdAt: date(50))
        let finished = job(helper, state: .succeeded, createdAt: date(60), finishedAt: date(65))

        let rows = AgentDesktopDockPolicy.presentations(
            jobs: [queued, finished, awaiting, running],
            helpers: [helper],
            now: date(66)
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].helper.id, helper.id)
        XCTAssertEqual(rows[0].job.id, running.id)
        XCTAssertEqual(rows[0].activeJobCount, 3)
        XCTAssertTrue(rows[0].isActive)
        XCTAssertEqual(AgentDesktopDockPolicy.activeJobCount([queued, finished, awaiting, running]), 3)
    }

    func testRecentlyFinishedJobLingersThenExpires() {
        let helper = profile("Planner")
        let finished = job(helper, state: .failed, createdAt: date(1), finishedAt: date(10))

        XCTAssertEqual(
            AgentDesktopDockPolicy.presentations(jobs: [finished], helpers: [helper], now: date(17)).map(\.job.id),
            [finished.id]
        )
        XCTAssertTrue(AgentDesktopDockPolicy.presentations(jobs: [finished], helpers: [helper], now: date(17.01)).isEmpty)
    }

    func testCancelledAndSucceededLingerButInterruptedDoesNot() {
        let stoppedProfile = profile("Stopped")
        let doneProfile = profile("Done")
        let interruptedProfile = profile("Interrupted")
        let stopped = job(stoppedProfile, state: .cancelled, createdAt: date(1), finishedAt: date(9))
        let done = job(doneProfile, state: .succeeded, createdAt: date(1), finishedAt: date(10))
        let interrupted = job(interruptedProfile, state: .interrupted, createdAt: date(10), finishedAt: date(10))

        let rows = AgentDesktopDockPolicy.presentations(
            jobs: [stopped, done, interrupted],
            helpers: [stoppedProfile, doneProfile, interruptedProfile],
            now: date(10)
        )

        XCTAssertEqual(Set(rows.map(\.helper.id)), [stoppedProfile.id, doneProfile.id])
        XCTAssertTrue(rows.allSatisfy { !$0.isActive })
    }

    func testHiddenHelpersAndMaximumPortraitCountAreApplied() {
        let helpers = (0..<5).map { profile("Helper \($0)") }
        let jobs = helpers.enumerated().map { index, helper in
            job(helper, state: .running, createdAt: date(Double(index)))
        }
        let visible = AgentDesktopDockPolicy.presentations(
            jobs: jobs,
            helpers: helpers,
            now: date(20),
            hiddenHelperIDs: [helpers[4].id],
            maximumHelpers: 2
        )

        XCTAssertEqual(visible.count, 2)
        XCTAssertFalse(visible.contains { $0.helper.id == helpers[4].id })
        XCTAssertEqual(AgentDesktopDockPolicy.activeJobCount(jobs, hiddenHelperIDs: [helpers[4].id]), 4)
    }

    func testMissingProfileGetsStableFallbackFromJobIdentity() {
        let helper = profile("Retired helper")
        let running = job(helper, state: .running)
        let row = AgentDesktopDockPolicy.presentations(jobs: [running], helpers: [], now: date(20)).first

        XCTAssertEqual(row?.helper.id, helper.id)
        XCTAssertEqual(row?.helper.name, helper.name)
    }

    func testDockGeometryStaysOnRightEdgeAndCapsToVisibleScreen() {
        let screen = CGRect(x: 100, y: 80, width: 1440, height: 900)
        let expanded = AgentDesktopDockLayout.panelSize(isCollapsed: false, helperCount: 12, visibleScreenHeight: screen.height)
        let frame = AgentDesktopDockLayout.frame(screen: screen, size: expanded)

        XCTAssertEqual(expanded.width, AgentDesktopDockLayout.expandedWidth)
        XCTAssertLessThanOrEqual(expanded.height, AgentDesktopDockLayout.maximumHeight)
        XCTAssertEqual(frame.maxX, screen.maxX - 12, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
        XCTAssertLessThanOrEqual(AgentDesktopDockLayout.panelSize(isCollapsed: false, helperCount: 12, visibleScreenHeight: 240).height, 240)
        XCTAssertEqual(AgentDesktopDockLayout.panelSize(isCollapsed: true, helperCount: 3, visibleScreenHeight: 240).width, AgentDesktopDockLayout.collapsedWidth)
    }

    func testDockStateTransitionsKeepCollapseVisibilityAndSharingIndependent() {
        var state = AgentDesktopDockState(isCollapsed: false)
        state.toggleCollapsed()
        XCTAssertTrue(state.isCollapsed)
        state.setHidden(true)
        state.setVisibleInRecordings(false)

        XCTAssertTrue(state.isHidden)
        XCTAssertFalse(state.visibleInRecordings)
        XCTAssertTrue(state.isCollapsed)

        state.setCollapsed(false)
        state.setHidden(false)
        XCTAssertFalse(state.isCollapsed)
        XCTAssertFalse(state.isHidden)
    }

    func testHoverPreviewUsesLatestPublicActivityAndBoundsText() {
        var task = job(profile("Writer"), state: .running)
        task.activity = [AgentActivity(kind: "command", text: "Reviewing files"), AgentActivity(kind: "message", text: "Writing\n  the report"), AgentActivity(kind: "message", text: "   ")]
        XCTAssertEqual(AgentHeadPreview.text(for: task), "Writing the report")
        task.activity = [AgentActivity(kind: "message", text: String(repeating: "x", count: 400))]
        XCTAssertLessThanOrEqual(AgentHeadPreview.text(for: task).count, 140)
        task.state = .queued
        XCTAssertEqual(AgentHeadPreview.text(for: task), "Waiting to start.")
        task.state = .succeeded
        XCTAssertEqual(AgentHeadPreview.text(for: task), "Task finished. Click to see the result.")
    }

    private func profile(_ name: String) -> HelperProfile {
        HelperProfile(name: name, instructions: "Be clear.")
    }

    private func job(
        _ helper: HelperProfile,
        state: AgentJob.State,
        createdAt: Date = Date(timeIntervalSince1970: 1),
        finishedAt: Date? = nil
    ) -> AgentJob {
        var result = AgentJob(
            title: "Task",
            prompt: "Do a small task",
            helperID: helper.id,
            helperName: helper.name,
            helperInstructions: helper.instructions
        )
        result.state = state
        result.createdAt = createdAt
        result.finishedAt = finishedAt
        if state == .running { result.startedAt = createdAt }
        return result
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
}
