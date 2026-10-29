import XCTest
@testable import Kaddo

final class CharacterPresenceTests: XCTestCase {
    func testFollowerOnlyAppearsWhenItIsTheSoleCharacterSurface() {
        for enabled in [false, true] {
            for panel in [false, true] {
                for workspace in [false, true] {
                    let shown = CharacterPresence.showsFollower(enabled: enabled, panelPresented: panel, workspacePresented: workspace)
                    XCTAssertEqual(shown, enabled && !panel && !workspace)
                }
            }
        }
    }
}
