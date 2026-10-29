import XCTest
import ApplicationServices
@testable import Kaddo

final class DesktopFocusIdentityTests: XCTestCase {
    func testFocusIdentityUsesAccessibilityEqualityAndRejectsUnknownFocus() {
        let first = DesktopFocusIdentity(element: AXUIElementCreateApplication(42))
        let equivalent = DesktopFocusIdentity(element: AXUIElementCreateApplication(42))
        let different = DesktopFocusIdentity(element: AXUIElementCreateApplication(43))
        XCTAssertTrue(DesktopFocusIdentity.matches(first, equivalent))
        XCTAssertFalse(DesktopFocusIdentity.matches(first, different))
        XCTAssertFalse(DesktopFocusIdentity.matches(nil, equivalent))
        XCTAssertFalse(DesktopFocusIdentity.matches(first, nil))
        XCTAssertFalse(DesktopFocusIdentity.matches(nil, nil))
    }

    func testIdenticalFocusLabelsDoNotMakeDifferentAccessibilityElementsTheSamePlanTarget() {
        let first = DesktopFocusIdentity(element: AXUIElementCreateApplication(42))
        let different = DesktopFocusIdentity(element: AXUIElementCreateApplication(43))
        let target = DesktopTargetIdentity(pid: 42, appID: "com.example.QA", title: "Draft", windowID: 7,
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), focus: "AXTextField", focusIdentity: first)
        var changed = target; changed.focusIdentity = different
        let id = UUID()
        let request = DesktopPlanningRequest(id: id, targetID: target.appID, target: target, goal: "Type")
        XCTAssertEqual(target.focus, changed.focus)
        XCTAssertFalse(request.isCurrent(generation: id, selectedTargetID: target.appID, identity: changed))
        let approval = DesktopApproval(action: DesktopAction(type: .typeText, text: "Draft"), appName: "QA",
            appID: target.appID, pid: target.pid, windowTitle: target.title, focusedElement: target.focus,
            windowID: target.windowID, windowFrame: target.frame, focusIdentity: different)
        XCTAssertFalse(request.matches(approval))
    }
}
