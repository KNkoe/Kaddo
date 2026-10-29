import XCTest
@testable import Kaddo

@MainActor final class AgentDesignShutdownTests: XCTestCase {
    func testShutdownCancelsPendingDesignWithoutOverwritingProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageURL: root.appendingPathComponent("state.json"), useKeychain: false) { name, instructions, seed in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return AgentIdentity.provisional(name: name, instructions: instructions, seed: seed)
        }
        model.enableCharacterDesign()
        XCTAssertEqual(model.helpers.first?.characterDesignState, "designing")
        model.stopCharacterDesigns()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(model.helpers.first?.identity)
        XCTAssertNil(model.helpers.first?.characterDesignState)
        XCTAssertNil(model.helpers.first?.characterDesignError)
    }
}
