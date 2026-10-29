import XCTest
@testable import Kaddo

@MainActor final class AgentIdentityTests: XCTestCase {
    func testEffectiveInstructionsAreStableForPreparedVoiceReuse() {
        let helper = HelperProfile(name: "Kaddo", instructions: "Be warm and clear")
        XCTAssertEqual(Set((0..<50).map { _ in helper.effectiveInstructions }).count, 1)
    }
    func testLegacyDecodeAndStableProvisionalIdentity() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"Research\",\"instructions\":\"Study evidence\"}".utf8)
        let helper = try JSONDecoder().decode(HelperProfile.self, from: data)
        XCTAssertNil(helper.identity)
        XCTAssertEqual(helper.characterIdentity, helper.characterIdentity)
        XCTAssertEqual(try JSONDecoder().decode(HelperProfile.self, from: JSONEncoder().encode(helper)), helper)
        XCTAssertTrue(helper.characterIdentity.traits.contains("methodical"))
    }
    func testUniqueSeedsAndInstructionsPriority() {
        let first = HelperProfile(name: "Research", instructions: "Always answer briefly")
        let second = HelperProfile(name: "Research", instructions: "Always answer briefly")
        XCTAssertNotEqual(first.characterIdentity.appearance.seed, second.characterIdentity.appearance.seed)
        XCTAssertTrue(first.effectiveInstructions.hasSuffix("User agent instructions:\nAlways answer briefly"))
        XCTAssertTrue(first.effectiveInstructions.contains("cannot alter permissions"))
    }
    func testStrictDesignValidation() throws {
        var identity = AgentIdentity.provisional(name: "Writer", instructions: "Write stories", seed: 1)
        identity.appearance.accessory = .headphones
        func parse() throws -> AgentIdentity { try AgentIdentity.parse(String(decoding: JSONEncoder().encode(identity), as: UTF8.self), seed: 27) }
        XCTAssertEqual(try parse().appearance.seed, 27)
        let normalized = try parse()
        XCTAssertEqual(normalized.appearance.silhouette, .squircle)
        XCTAssertEqual(normalized.appearance.feature, .none)
        XCTAssertEqual(normalized.appearance.eyeStyle, .round)
        XCTAssertEqual(normalized.appearance.accessory, .glasses)
        identity.appearance.primary = "red"
        XCTAssertThrowsError(try parse())
        XCTAssertThrowsError(try AgentIdentity.parse("```json\n{}\n```", seed: 1))
        XCTAssertThrowsError(try AgentIdentity.parse(String(repeating: "x", count: 12001), seed: 1))
    }

    func testNewAgentsUseOneMascotStyleAndBrightDistinctColors() throws {
        let identities = (1...6).map { AgentIdentity.provisional(name: "Helper \($0)", instructions: "Assist", seed: UInt64($0) * 7919) }
        XCTAssertTrue(identities.allSatisfy { $0.appearance.silhouette == .squircle && $0.appearance.feature == .none && $0.appearance.eyeStyle == .round })
        let hues = try identities.map { identity -> CGFloat in
            let color = try XCTUnwrap(AgentPalette(appearance: identity.appearance).primary.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThanOrEqual(color.saturationComponent, 0.68)
            XCTAssertGreaterThanOrEqual(color.brightnessComponent, 0.96)
            XCTAssertFalse((0.19...0.37).contains(color.hueComponent), "Helper colors must stay distinct from Kaddo green")
            return color.hueComponent
        }
        XCTAssertEqual(Set(hues.map { Int(($0 * 100).rounded()) }).count, identities.count)
    }

    func testSavedLegacyAppearanceDecodesUnchangedAndShowsOnlyOneDecoration() throws {
        var identity = AgentIdentity.provisional(name: "Legacy", instructions: "Help", seed: 47)
        identity.appearance.silhouette = .cloud
        identity.appearance.feature = .antenna
        identity.appearance.eyeStyle = .visor
        identity.appearance.accessory = .goggles
        let decoded = try JSONDecoder().decode(AgentIdentity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(decoded, identity, "Existing saved identity fields remain Codable-compatible")
        XCTAssertEqual(decoded.appearance.mascotAccessory, .goggles, "An existing accessory takes priority over legacy features")
        identity.appearance.accessory = .none
        identity.appearance.feature = .leaves
        XCTAssertEqual(identity.appearance.mascotAccessory, .leaf)
    }

    func testExplicitEnableAutomaticCreationAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let file = root.appendingPathComponent("conversations.json")
        let model = AppModel(storageURL: file, useKeychain: false, characterDesigner: { name, instructions, seed in
            calls += 1
            return .provisional(name: name, instructions: instructions, seed: seed)
        })
        model.addHelper(name: "Research", instructions: "Analyze evidence")
        await Task.yield()
        XCTAssertEqual(calls, 0)
        model.enableCharacterDesign()
        model.enableCharacterDesign()
        for _ in 0..<100 { if model.helpers.allSatisfy({ $0.characterDesignState == "ready" }) { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.helpers.allSatisfy { $0.identity != nil })
        let restored = AppModel(storageURL: file, useKeychain: false)
        XCTAssertEqual(restored.helpers, model.helpers)
        model.addHelper(name: "Artist", instructions: "Design art")
        for _ in 0..<100 { if model.selectedHelper?.identity != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(calls, 3)
        XCTAssertNotNil(model.selectedHelper?.identity)
    }
    func testFailedRedesignPreservesIdentityAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = false
        let model = AppModel(storageURL: root.appendingPathComponent("state.json"), useKeychain: false, characterDesigner: { name, instructions, seed in
            if fail { throw AgentIdentityError.message("Test design failure") }
            return .provisional(name: name, instructions: instructions, seed: seed)
        })
        model.enableCharacterDesign()
        for _ in 0..<100 { if model.helpers[0].identity != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let initial = model.helpers[0].identity
        fail = true
        model.regenerateIdentity(id: model.helpers[0].id)
        for _ in 0..<100 { if model.helpers[0].characterDesignState == "failed" { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(model.helpers[0].identity, initial)
        XCTAssertNotNil(model.helpers[0].characterDesignError)
        fail = false
        model.regenerateIdentity(id: model.helpers[0].id)
        for _ in 0..<100 { if model.helpers[0].characterDesignState == "ready" { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(model.helpers[0].characterDesignState, "ready")
    }
    func testRemovedAgentDoesNotReappearAfterDesign() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageURL: root.appendingPathComponent("state.json"), useKeychain: false, characterDesigner: { name, instructions, seed in
            try await Task.sleep(nanoseconds: 20_000_000)
            return .provisional(name: name, instructions: instructions, seed: seed)
        })
        model.enableCharacterDesign()
        model.helpers = []
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.helpers.isEmpty)
    }
}
