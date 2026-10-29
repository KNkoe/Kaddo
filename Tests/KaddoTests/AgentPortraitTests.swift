import XCTest
import SwiftUI
import AppKit
import CryptoKit
@testable import Kaddo

@MainActor final class AgentPortraitTests: XCTestCase {
    func testSquareFacesAndLargerGlassesRenderAtCompanionSizes() throws {
        XCTAssertEqual(SculptedMascotLayout.bodyHeight, 0.94)
        XCTAssertEqual(SculptedMascotLayout.eyeCenters, SculptedMascotLayout.lensCenters)
        for size: CGFloat in [22, 40, 72, 160] {
            let content = HStack(spacing: 12) {
                SculptedMascotBody(size: size, palette: .kaddo)
                    .overlay(SculptedMascotFace(size: size))
                SculptedMascotBody(size: size, palette: .kaddo)
                    .overlay(SculptedMascotFace(size: size, accessory: .glasses))
                SculptedMascotBody(size: size, palette: .kaddo)
                    .overlay(SculptedMascotFace(size: size, accessory: .goggles))
            }.padding(12)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 500)
            if let path = ProcessInfo.processInfo.environment["KADDO_FACE_QA_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("faces-\(Int(size)).png"))
            }
        }
    }

    func testAnimatedPosesRenderWithoutBreakingPortraits() throws {
        let identity = AgentIdentity.provisional(name: "Research", instructions: "Research", seed: 871769)
        let motion = AgentMotion(identity: identity)
        let blinkStart = motion.blinkInterval - motion.phase.truncatingRemainder(dividingBy: motion.blinkInterval)
        var hashes = Set<String>()
        for (index, time) in [0.5, 1.5, blinkStart + 0.11, blinkStart + 0.23].enumerated() {
            let pointer = CGSize(width: index.isMultiple(of: 2) ? -4 : 4, height: index < 2 ? -7.5 : 7.5)
            let renderer = ImageRenderer(content: AgentCharacterView(identity: identity, size: 160, animated: false, previewTime: time, previewPointer: pointer))
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
            hashes.insert(SHA256.hash(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))).description)
        }
        XCTAssertEqual(hashes.count, 4)
        if let path = ProcessInfo.processInfo.environment["KADDO_MOTION_QA_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for frame in 0..<144 {
                let time = Double(frame) / 24
                let pointer = CGSize(width: sin(time * 1.2) * 4, height: cos(time * 1.2) * 7.5)
                let renderer = ImageRenderer(content: AgentCharacterView(identity: identity, size: 240, animated: false, previewTime: time, previewPointer: pointer))
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(String(format: "frame-%03d.png", frame)))
            }
        }
    }

    func testMutedSavedDesignsBecomeVividWithoutChangingIdentity() throws {
        for (index, primary) in ["#397D78", "#344E63", "#537C78", "#777777"].enumerated() {
            var identity = AgentIdentity.provisional(name: "Existing agent", instructions: "Research", seed: UInt64(index + 1) * 7919)
            identity.appearance.primary = primary
            identity.appearance.secondary = "#F3EBDD"
            identity.appearance.accent = "#ECAF58"
            let original = identity
            let palette = AgentPalette(appearance: identity.appearance)
            let base = try XCTUnwrap(palette.primary.usingColorSpace(.deviceRGB))
            let shade = try XCTUnwrap(palette.shadow.usingColorSpace(.deviceRGB))
            let accent = try XCTUnwrap(palette.accent.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThanOrEqual(base.saturationComponent, 0.67)
            XCTAssertGreaterThanOrEqual(base.brightnessComponent, 0.95)
            XCTAssertGreaterThanOrEqual(accent.saturationComponent, 0.74)
            XCTAssertGreaterThanOrEqual(accent.brightnessComponent, 0.97)
            XCTAssertEqual(base.hueComponent, shade.hueComponent, accuracy: 0.01)
            XCTAssertGreaterThan(base.brightnessComponent, shade.brightnessComponent)
            XCTAssertEqual(identity, original)
            if let path = ProcessInfo.processInfo.environment["KADDO_PORTRAIT_QA_DIR"] {
                let renderer = ImageRenderer(content: AgentCharacterView(identity: identity, size: 160, animated: false))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("saved-agent-\(index + 1).png"))
            }
        }
    }

    func testGeneratedDesignsRenderDistinctPortraits() throws {
        let roles = ["Researcher", "Garden guide", "Music coach", "Developer", "Travel planner", "Storyteller", "Study buddy", "Designer", "Organizer", "Language tutor", "Chef", "Astronomer"]
        var hashes = Set<String>()
        for (index, role) in roles.enumerated() {
            let identity = AgentIdentity.provisional(name: role, instructions: role, seed: UInt64(index + 1) * 7919)
            let renderer = ImageRenderer(content: AgentCharacterView(identity: identity, size: 160, animated: false))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01, "Portrait must have a transparent canvas, without renderer placeholders")
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 1000)
            hashes.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            if let path = ProcessInfo.processInfo.environment["KADDO_PORTRAIT_QA_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("portrait-\(index + 1).png"))
            }
        }
        XCTAssertEqual(hashes.count, roles.count)
    }

    func testLegacyBodyAndEyeVariantsRenderInSharedMascotStyle() throws {
        var legacy = AgentIdentity.provisional(name: "Legacy", instructions: "Research", seed: 4581)
        legacy.appearance.silhouette = .cloud
        legacy.appearance.feature = .horns
        legacy.appearance.eyeStyle = .visor
        legacy.appearance.accessory = .goggles
        var unified = legacy
        unified.appearance.silhouette = .squircle
        unified.appearance.feature = .none
        unified.appearance.eyeStyle = .round

        func imageHash(_ identity: AgentIdentity) throws -> String {
            let renderer = ImageRenderer(content: AgentCharacterView(identity: identity, size: 160, animated: false))
            renderer.scale = 2
            let bitmap = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        XCTAssertEqual(try imageHash(legacy), try imageHash(unified), "Legacy silhouette and eye values must not change the shared face style")
    }

    func testLegacyKaddoGreenPaletteIsAdjustedOnlyAtDisplayTime() throws {
        var identity = AgentIdentity.provisional(name: "Old helper", instructions: "Assist", seed: 35791)
        identity.appearance.primary = "#8FCE4F"
        let savedIdentity = identity
        let palette = SculptedMascotPalette.helper(appearance: identity.appearance)
        let displayed = try XCTUnwrap(NSColor(palette.middle).usingColorSpace(.deviceRGB))
        XCTAssertFalse((0.19...0.37).contains(displayed.hueComponent))
        XCTAssertEqual(identity, savedIdentity, "Legacy colors are adjusted in rendering without rewriting saved agent data")
    }
}
