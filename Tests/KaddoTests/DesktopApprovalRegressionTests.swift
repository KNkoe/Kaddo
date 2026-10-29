import XCTest
@testable import Kaddo

final class DesktopApprovalRegressionTests: XCTestCase {
    func testTypingApprovalPayloadIsExactAndIncludesContentBeyondShortPreview() {
        let payload = String(repeating: "A", count: 175) + "\nsecond line\nFINAL_REVIEWED_TAIL"
        let action = DesktopAction(type: .typeText, text: payload)

        XCTAssertEqual(action.approvalSummary, "Type exactly \(payload.count) characters")
        XCTAssertEqual(action.approvalPayload, payload)
        XCTAssertTrue(action.approvalPayload?.contains("\nsecond line\nFINAL_REVIEWED_TAIL") == true)
        XCTAssertFalse(action.preview.contains("FINAL_REVIEWED_TAIL"))
    }

    func testPlanRequestRejectsChangedGenerationWindowAndFocus() {
        let target = DesktopTargetIdentity(
            pid: 42, appID: "com.example.Editor", title: "Draft",
            windowID: 7, frame: CGRect(x: 10, y: 20, width: 800, height: 600), focus: "AXTextField Title"
        )
        let requestID = UUID()
        let request = DesktopPlanningRequest(id: requestID, targetID: target.appID, target: target, goal: "Save the draft")

        XCTAssertTrue(request.isCurrent(generation: requestID, selectedTargetID: target.appID, identity: target))
        XCTAssertFalse(request.isCurrent(generation: UUID(), selectedTargetID: target.appID, identity: target))
        XCTAssertFalse(request.isCurrent(generation: requestID, selectedTargetID: "com.example.Other", identity: target))
        XCTAssertFalse(request.isCurrent(generation: requestID, selectedTargetID: target.appID, identity: DesktopTargetIdentity(
            pid: target.pid, appID: target.appID, title: target.title, windowID: target.windowID,
            frame: target.frame, focus: "AXButton Save"
        )))
    }

    func testSuggestedApprovalMustMatchCapturedTargetIdentity() {
        let target = DesktopTargetIdentity(
            pid: 42, appID: "com.example.Editor", title: "Draft",
            windowID: 7, frame: CGRect(x: 10, y: 20, width: 800, height: 600), focus: "AXTextField Title"
        )
        let request = DesktopPlanningRequest(id: UUID(), targetID: target.appID, target: target, goal: "Save")
        let approval = DesktopApproval(
            action: DesktopAction(type: .click, x: 30, y: 40), appName: "Editor", appID: target.appID,
            pid: target.pid, windowTitle: target.title, focusedElement: target.focus,
            windowID: target.windowID, windowFrame: target.frame
        )
        XCTAssertTrue(request.matches(approval))

        let staleApproval = DesktopApproval(
            action: approval.action, appName: "Editor", appID: target.appID,
            pid: target.pid, windowTitle: target.title, focusedElement: "AXButton Save",
            windowID: target.windowID, windowFrame: target.frame
        )
        XCTAssertFalse(request.matches(staleApproval))
    }

    func testIndexedObservationShowsActualRoleLabelAndNearbyContextWithoutValues() throws {
        let observation = """
        Window: "Draft", App: Editor
        0 standard window Draft
        \t1 toolbar Main actions
        \t\t2 button Description: Save, Help: Save the current draft
        \t\t3 text field (settable) Value: confidential-entry, Placeholder: Search drafts
        \t4 scroll area
        \t\t5 row Current draft
        """

        let target = try XCTUnwrap(AgentComputerObservedTarget.resolve(index: 2, in: observation))
        XCTAssertEqual(target.role, "button")
        XCTAssertEqual(target.label, "Save")
        XCTAssertEqual(target.summary, "button · Save")
        XCTAssertTrue(target.context.contains("2 button: Save"))
        XCTAssertTrue(target.context.contains("1 toolbar: Main actions"))
        XCTAssertFalse(target.context.contains("5 row: Current draft"))
        XCTAssertFalse(target.context.contains("confidential-entry"))
        XCTAssertTrue(target.isIdentifiable(for: .click))
        let review = AgentComputerReview(
            jobID: UUID(), approval: DesktopApproval(
                action: DesktopAction(type: .click, x: 20, y: 30), appName: "Editor", appID: "com.example.Editor",
                pid: 42, windowTitle: "Draft", focusedElement: "AXButton Save", windowID: nil, windowFrame: nil
            ), reason: "Model-supplied text", elementIndex: 2, observedTarget: target
        )
        XCTAssertEqual(review.actionDescription, "Click button · Save")
        XCTAssertFalse(review.actionDescription.contains("Model-supplied text"))
    }

    func testUnidentifiedOrStaleIndexedTargetsCannotBeApproved() throws {
        let observation = """
        Window: "Settings", App: Editor
        0 standard window Settings
        \t1 button
        \t2 slider Value: 0.5
        """
        let unlabeledButton = try XCTUnwrap(AgentComputerObservedTarget.resolve(index: 1, in: observation))
        XCTAssertFalse(unlabeledButton.isIdentifiable(for: .click))
        XCTAssertNil(AgentComputerObservedTarget.resolve(index: 9, in: observation))
        XCTAssertNil(AgentComputerObservedTarget.resolve(index: 1, in: observation + "\n1 button Duplicate"))
        XCTAssertNil(AgentComputerObservedTarget.resolve(index: 1, in: observation, maximumContextCharacters: 0))

        let scrollObservation = """
        0 standard window Editor
        \t1 scroll area
        \t\t2 row Recent files
        """
        let scroll = try XCTUnwrap(AgentComputerObservedTarget.resolve(index: 1, in: scrollObservation))
        XCTAssertTrue(scroll.isIdentifiable(for: .scroll))
        XCTAssertFalse(scroll.isIdentifiable(for: .click))
    }

    func testIndexedContextIsBounded() throws {
        let rows = (0..<20).map { "\($0) button Description: Item \($0) " + String(repeating: "x", count: 100) }
        let target = try XCTUnwrap(AgentComputerObservedTarget.resolve(index: 10, in: rows.joined(separator: "\n"), contextRadius: 5, maximumContextCharacters: 220))
        XCTAssertLessThanOrEqual(target.context.count, 220)
    }
}
