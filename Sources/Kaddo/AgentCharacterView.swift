import SwiftUI
import AppKit

/// A helper keeps Kaddo's sculpted proportions and expressions. Its saved
/// identity supplies only a color and one small accessory.
struct AgentCharacterView: View {
    let identity: AgentIdentity
    var size: CGFloat
    var animated = true
    var previewTime: Double? = nil
    var previewPointer: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var tracking = CharacterTracking()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || reduceMotion)) { timeline in
            let time = previewTime ?? (animated && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0)
            let moving = !reduceMotion && (animated || previewTime != nil)
            let trackedPointer = tracking.gaze(size: size, time: time, enabled: moving)
            // `previewPointer` is part of the existing preview API and already
            // uses AgentMotion's normalized 100-unit coordinate space.
            let pointer = previewTime != nil
                ? previewPointer
                : CGSize(width: trackedPointer.width / max(size, 1) * 100,
                         height: trackedPointer.height / max(size, 1) * 100)
            let pose = AgentMotion(identity: identity).pose(
                time: time,
                pointer: pointer,
                enabled: moving
            )
            let palette = SculptedMascotPalette.helper(appearance: identity.appearance)

            ZStack {
                SculptedMascotBody(size: size, palette: palette)
                SculptedMascotFace(
                    size: size,
                    eyeOpen: pose.openness,
                    smileDepth: pose.smileDepth * 0.005,
                    gaze: CGSize(width: pose.face.width * size / 100,
                                 height: pose.face.height * size / 100),
                    faceMovesTogether: true,
                    accessory: identity.appearance.mascotAccessory,
                    accessoryAccent: palette.accent
                )
            }
            .frame(width: size, height: size * SculptedMascotLayout.bodyHeight)
            .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
            .offset(y: pose.lift * size / 100)
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .background { if animated { CharacterTrackingAnchor(tracking: tracking).allowsHitTesting(false) } }
        .accessibilityLabel("\(identity.personalityName) agent character")
    }
}
