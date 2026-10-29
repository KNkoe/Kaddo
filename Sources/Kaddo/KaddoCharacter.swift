import SwiftUI
import AppKit

/// Kaddo's expressions are shared by the notch, pointer companion, and chat.
enum CharacterMood: String, CaseIterable {
    case idle, listening, thinking, happy, sleeping
}

enum SculptedMascotLayout {
    static let bodyHeight: CGFloat = 0.94
    static let eyeWidth: CGFloat = 0.085
    static let eyeSpacing: CGFloat = 0.18
    static let eyeCenterY: CGFloat = 0.38
    static let mouthCenterY: CGFloat = 0.62
    static let lensWidth: CGFloat = 0.23
    static let lensSpacing: CGFloat = 0.035
    static let lensHeight: CGFloat = 0.25
    static var eyeCenters: [CGFloat] { [0.5 - (eyeWidth + eyeSpacing) / 2, 0.5 + (eyeWidth + eyeSpacing) / 2] }
    static var lensCenters: [CGFloat] { [0.5 - (lensWidth + lensSpacing) / 2, 0.5 + (lensWidth + lensSpacing) / 2] }
}

private struct MainCompanionSuppressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var mainCompanionSuppressed: Bool {
        get { self[MainCompanionSuppressedKey.self] }
        set { self[MainCompanionSuppressedKey.self] = newValue }
    }
}

struct KaddoCharacter: View {
    @Environment(\.mainCompanionSuppressed) private var suppressed
    var size: CGFloat = 72
    var mood: CharacterMood = .idle
    var followsPointer: Bool = false
    var gazeOverride: CGSize? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var tracking = CharacterTracking()
    // Keep blinking continuous when switching between Home, compact and preview.
    private let phaseOffset = 0.0
    @State private var hovered = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let pose = CharacterPose.sample(time: time, mood: mood, reducedMotion: reduceMotion, phaseOffset: phaseOffset)
            let sleeping = mood == .sleeping
            let gaze = reduceMotion || sleeping ? .zero : gazeOverride ?? tracking.gaze(size: size, time: time, enabled: followsPointer)
            let mouthOffset = mood == .listening
                ? CGSize(width: gaze.width * 0.35, height: size * (SculptedMascotLayout.mouthCenterY - SculptedMascotLayout.bodyHeight / 2) + gaze.height * 0.25)
                : CGSize(width: gaze.width * 0.35 + size * pose.gazeX * 0.5,
                         height: size * (SculptedMascotLayout.mouthCenterY - SculptedMascotLayout.bodyHeight / 2) + gaze.height * 0.25 + size * pose.gazeY * 0.25)
            ZStack {
                SculptedMascotBody(size: size, palette: .kaddo)
                SculptedMascotFace(size: size, mood: mood, eyeOpen: pose.eyeOpen, mouthOpen: pose.mouthOpen,
                                   smileDepth: pose.smile,
                                   gaze: CGSize(width: gaze.width + size * pose.gazeX,
                                                height: gaze.height + size * pose.gazeY),
                                   mouthOffset: mouthOffset)
            }
            .frame(width: size, height: size * SculptedMascotLayout.bodyHeight)
            .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
            .rotation3DEffect(.degrees(-Double(gaze.height / size) * 90), axis: (x: 1, y: 0, z: 0), perspective: 0.25)
            .rotation3DEffect(.degrees(Double(gaze.width / size) * 85), axis: (x: 0, y: 1, z: 0), perspective: 0.25)
            .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
            .offset(y: size * pose.bob + gaze.height * 0.20)
            .animation(reduceMotion ? nil : KaddoMotion.content, value: mood)
        }
        .frame(width: size, height: size)
        .background(CharacterTrackingAnchor(tracking: tracking))
        .scaleEffect(hovered && followsPointer && !reduceMotion ? 1.035 : 1, anchor: .bottom)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .opacity(suppressed ? 0 : 1)
        .accessibilityHidden(suppressed)
        .accessibilityLabel("Kaddo, \(mood.rawValue)")
    }

}

/// The shared glossy body material for Kaddo and every helper portrait.
/// Helpers change the hue while retaining the exact body, highlights, shading,
/// and outline that define Kaddo's mascot style.
struct SculptedMascotPalette {
    var top: Color
    var upper: Color
    var middle: Color
    var lower: Color
    var bottom: Color
    var innerShadow: Color
    var edgeShadow: Color
    var accent: Color

    static let kaddo = SculptedMascotPalette(
        top: Color(red: 0.90, green: 1, blue: 0.70),
        upper: Color(red: 0.78, green: 0.96, blue: 0.55),
        middle: Color(red: 0.69, green: 0.89, blue: 0.43),
        lower: Color(red: 0.43, green: 0.65, blue: 0.28),
        bottom: Color(red: 0.26, green: 0.48, blue: 0.30),
        innerShadow: Color(red: 0.13, green: 0.30, blue: 0.12),
        edgeShadow: Color(red: 0.20, green: 0.40, blue: 0.18),
        accent: Color(red: 0.94, green: 1, blue: 0.70)
    )

    static func helper(appearance: AgentAppearance) -> Self {
        let colors = AgentPalette(appearance: appearance)
        let base = colors.primary
        let shade = colors.shadow
        var hue = base.hueComponent
        // Keep the helper visually distinct from Kaddo's signature green,
        // including old saved identities that happen to use a similar hue.
        if hue >= 0.19 && hue <= 0.37 { hue = (hue + 0.36).truncatingRemainder(dividingBy: 1) }
        let family = NSColor(hue: hue, saturation: base.saturationComponent, brightness: base.brightnessComponent, alpha: 1).usingColorSpace(.sRGB) ?? base
        let darker = NSColor(hue: hue, saturation: shade.saturationComponent, brightness: shade.brightnessComponent, alpha: 1).usingColorSpace(.sRGB) ?? shade
        func mix(_ first: NSColor, _ second: NSColor, _ amount: CGFloat) -> Color {
            Color(nsColor: NSColor(srgbRed: first.redComponent + (second.redComponent - first.redComponent) * amount,
                                   green: first.greenComponent + (second.greenComponent - first.greenComponent) * amount,
                                   blue: first.blueComponent + (second.blueComponent - first.blueComponent) * amount,
                                   alpha: 1))
        }
        let white = NSColor.white.usingColorSpace(.sRGB) ?? .white
        let black = NSColor.black.usingColorSpace(.sRGB) ?? .black
        return Self(top: mix(family, white, 0.34),
                    upper: mix(family, white, 0.16),
                    middle: Color(nsColor: family),
                    lower: mix(family, darker, 0.48),
                    bottom: mix(darker, black, 0.27),
                    innerShadow: mix(darker, black, 0.42),
                    edgeShadow: mix(darker, black, 0.16),
                    accent: mix(family, white, 0.48))
    }
}

struct SculptedMascotBody: View {
    var size: CGFloat
    var palette: SculptedMascotPalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.38)
        let material = LinearGradient(stops: [
            .init(color: palette.top, location: 0),
            .init(color: palette.upper, location: 0.27),
            .init(color: palette.middle, location: 0.53),
            .init(color: palette.lower, location: 0.83),
            .init(color: palette.bottom, location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        shape.fill(material.shadow(.inner(color: palette.innerShadow.opacity(0.30), radius: size * 0.045, x: size * 0.025, y: size * 0.035))
                .shadow(.inner(color: .white.opacity(0.55), radius: size * 0.025, x: -size * 0.012, y: -size * 0.018)))
        .overlay {
            RadialGradient(colors: [.white.opacity(0.56), palette.accent.opacity(0.20), .clear], center: UnitPoint(x: 0.25, y: 0.16), startRadius: 0, endRadius: size * 0.65)
                .clipShape(shape)
        }
        .overlay {
            Ellipse().fill(.white.opacity(0.43)).frame(width: size * 0.48, height: size * 0.13)
                .blur(radius: size * 0.042).rotationEffect(.degrees(-18)).offset(x: -size * 0.17, y: -size * 0.25).frame(width: size, height: size * SculptedMascotLayout.bodyHeight).clipShape(shape)
        }
        .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.74), .white.opacity(0.10), palette.edgeShadow.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(0.35, size * 0.008)) }
        .shadow(color: palette.innerShadow.opacity(0.22), radius: size * 0.025, y: size * 0.022)
        .frame(width: size, height: size * SculptedMascotLayout.bodyHeight)
    }
}

struct SculptedMascotFace: View {
    var size: CGFloat
    var mood: CharacterMood = .idle
    var eyeOpen: Double = 1
    var mouthOpen: Double = 0
    var smileDepth: Double = 0.025
    var gaze: CGSize = .zero
    var mouthOffset: CGSize? = nil
    var faceMovesTogether = false
    var accessory: AgentAppearance.Accessory = .none
    var accessoryAccent: Color = .white

    private var eyeHeight: CGFloat {
        size * (mood == .sleeping ? 0.025 : max(0.012, 0.19 * eyeOpen))
    }

    var body: some View {
        ZStack {
            HStack(spacing: size * SculptedMascotLayout.eyeSpacing) {
                eye
                eye
            }
            .offset(x: gaze.width, y: size * (SculptedMascotLayout.eyeCenterY - SculptedMascotLayout.bodyHeight / 2) + gaze.height)
            if mood == .listening {
                Ellipse().fill(Color.black.opacity(0.75))
                    .frame(width: size * 0.075, height: size * mouthOpen)
                    .offset(mouthOffset ?? CGSize(width: gaze.width * (faceMovesTogether ? 1 : 0.35),
                                                  height: size * 0.19 + gaze.height * (faceMovesTogether ? 1 : 0.25)))
            } else {
                CharacterSmile(depth: CGFloat(smileDepth))
                    .stroke(Color(red: 0.10, green: 0.18, blue: 0.075), style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                    .shadow(color: Color(red: 0.90, green: 1, blue: 0.68).opacity(0.8), radius: size * 0.003, y: size * 0.012)
                    .frame(width: size * (mood == .happy ? 0.22 : 0.16), height: size * 0.12)
                    .offset(mouthOffset ?? CGSize(width: gaze.width * (faceMovesTogether ? 1 : 0.35),
                                                  height: size * (SculptedMascotLayout.mouthCenterY - SculptedMascotLayout.bodyHeight / 2) + gaze.height * (faceMovesTogether ? 1 : 0.25)))
            }
            accessoryView
        }
        .frame(width: size, height: size * SculptedMascotLayout.bodyHeight)
    }

    private var eye: some View {
        Capsule().fill(LinearGradient(colors: [Color(red: 0.065, green: 0.12, blue: 0.045), Color(red: 0.15, green: 0.23, blue: 0.09)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .topLeading) {
                if eyeHeight > size * 0.05 {
                    Capsule().fill(.white.opacity(0.32)).frame(width: size * 0.022, height: eyeHeight * 0.23).padding(.leading, size * 0.012).padding(.top, eyeHeight * 0.12)
                }
            }
            .frame(width: size * SculptedMascotLayout.eyeWidth, height: eyeHeight)
            .shadow(color: Color(red: 0.92, green: 1, blue: 0.71).opacity(0.8), radius: size * 0.003, x: size * 0.006, y: size * 0.009)
    }

    @ViewBuilder private var accessoryView: some View {
        switch accessory {
        case .glasses, .goggles:
            HStack(spacing: size * SculptedMascotLayout.lensSpacing) {
                lens
                lens
            }
            .overlay(alignment: .center) {
                Capsule().fill(accessoryAccent.opacity(0.92)).frame(width: size * (SculptedMascotLayout.lensSpacing + 0.025), height: max(1, size * 0.022))
            }
            .offset(x: gaze.width, y: size * (SculptedMascotLayout.eyeCenterY - SculptedMascotLayout.bodyHeight / 2) + gaze.height)
        case .headphones:
            headphones
        case .bow:
            HStack(spacing: 0) {
                Ellipse().fill(accessoryAccent.gradient).frame(width: size * 0.07, height: size * 0.045).rotationEffect(.degrees(-20))
                Ellipse().fill(accessoryAccent.gradient).frame(width: size * 0.07, height: size * 0.045).rotationEffect(.degrees(20))
            }
            .overlay(Circle().fill(.white.opacity(0.8)).frame(width: size * 0.025))
            .offset(x: size * 0.19, y: -size * 0.24)
        case .star:
            Image(systemName: "star.fill").font(.system(size: size * 0.13, weight: .semibold)).foregroundStyle(accessoryAccent.gradient)
                .shadow(color: .white.opacity(0.55), radius: size * 0.018, y: -size * 0.01)
                .offset(x: size * 0.29, y: -size * 0.19)
        case .leaf:
            Ellipse().fill(accessoryAccent.gradient).frame(width: size * 0.15, height: size * 0.075)
                .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.7)).frame(width: size * 0.07, height: max(0.7, size * 0.008)).rotationEffect(.degrees(-25)) }
                .rotationEffect(.degrees(-34)).offset(x: size * 0.27, y: -size * 0.18)
        case .none:
            EmptyView()
        }
    }

    private var lens: some View {
        RoundedRectangle(cornerRadius: size * 0.06)
            .fill(accessory == .goggles ? LinearGradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.22).opacity(0.92), Color(red: 0.04, green: 0.08, blue: 0.12).opacity(0.96)], startPoint: .topLeading, endPoint: .bottomTrailing) : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom))
            .overlay {
                if accessory == .goggles {
                    Capsule().fill(.white.opacity(0.40)).frame(width: size * 0.06, height: size * 0.014).rotationEffect(.degrees(-28)).offset(x: -size * 0.025, y: -size * 0.035)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.06).strokeBorder(accessoryAccent.opacity(0.94), lineWidth: max(1, size * 0.019)))
            .frame(width: size * SculptedMascotLayout.lensWidth, height: size * SculptedMascotLayout.lensHeight)
            .shadow(color: .black.opacity(0.14), radius: size * 0.012, y: size * 0.008)
    }

    private var headphones: some View {
        ZStack {
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * 0.92))
                    path.addQuadCurve(to: CGPoint(x: geometry.size.width, y: geometry.size.height * 0.92),
                                      control: CGPoint(x: geometry.size.width * 0.5, y: -geometry.size.height * 0.28))
                }
                .stroke(accessoryAccent.opacity(0.95), style: StrokeStyle(lineWidth: max(1, size * 0.025), lineCap: .round))
            }
            .frame(width: size * 0.56, height: size * 0.38)
            .offset(y: -size * 0.07)
            HStack {
                RoundedRectangle(cornerRadius: size * 0.035).fill(accessoryAccent.gradient).frame(width: size * 0.075, height: size * 0.19)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: size * 0.035).fill(accessoryAccent.gradient).frame(width: size * 0.075, height: size * 0.19)
            }
            .frame(width: size * 0.68)
            .offset(y: -size * 0.015)
        }
    }
}

/// Resolve gaze from the actual face position, including detached windows and other displays.
final class CharacterTracking: ObservableObject {
    weak var view: NSView?
    private var x = DampedValue(value: 0)
    private var y = DampedValue(value: 0)
    private var lastTime: TimeInterval?

    func gaze(size: CGFloat, time: TimeInterval, enabled: Bool) -> CGSize {
        guard enabled, let view, let window = view.window else { return .zero }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let target = CharacterGaze.target(pointer: NSEvent.mouseLocation, face: frame, size: size)
        let elapsed = lastTime.map { min(0.1, max(0, time - $0)) } ?? 0
        if lastTime == nil { x.value = target.width; y.value = target.height }
        lastTime = time
        x.advance(toward: target.width, elapsed: elapsed, response: 0.24, damping: 1)
        y.advance(toward: target.height, elapsed: elapsed, response: 0.24, damping: 1)
        return CGSize(width: x.value, height: y.value)
    }
}

enum CharacterGaze {
    static func target(pointer: CGPoint, face: CGRect, size: CGFloat) -> CGSize {
        guard size.isFinite, size > 0, pointer.x.isFinite, pointer.y.isFinite,
              face.midX.isFinite, face.midY.isFinite else { return .zero }
        let reach = max(60, size * 2.5)
        let verticalReach = max(40, size * 1.5)
        return CGSize(width: sin(.pi / 2 * max(-1, min(1, (pointer.x - face.midX) / reach))) * size * 0.04,
                      height: -sin(.pi / 2 * max(-1, min(1, (pointer.y - face.midY) / verticalReach))) * size * 0.075)
    }
}

struct CharacterTrackingAnchor: NSViewRepresentable {
    let tracking: CharacterTracking
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        tracking.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { tracking.view = view }
}

private struct CharacterSmile: Shape {
    var depth: CGFloat
    var animatableData: CGFloat { get { depth } set { depth = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY + rect.width * depth * 4))
        return path
    }
}

/// Hands stay on the control while the face breathes and looks toward the pointer.
struct KaddoPerchedCharacter: View {
    @Environment(\.mainCompanionSuppressed) private var suppressed
    var size: CGFloat
    var mood: CharacterMood = .idle
    var body: some View {
        KaddoCharacter(size: size, mood: mood, followsPointer: true)
            .frame(height: size, alignment: .bottom)
            .shadow(color: .blue.opacity(0.19), radius: size * 0.15)
            .overlay(alignment: .bottom) {
                HStack(spacing: size * 0.38) {
                    ForEach(0..<2) { _ in
                        Ellipse().fill(LinearGradient(stops: [.init(color: Color(red: 0.92, green: 1, blue: 0.72), location: 0), .init(color: Color(red: 0.72, green: 0.92, blue: 0.46), location: 0.45), .init(color: Color(red: 0.38, green: 0.60, blue: 0.28), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Ellipse().strokeBorder(.white.opacity(0.35), lineWidth: size * 0.004))
                            .shadow(color: .black.opacity(0.32), radius: size * 0.012, y: size * 0.014)
                            .frame(width: size * 0.17, height: size * 0.125)
                    }
                }.offset(y: size * 0.025)
            }
            .opacity(suppressed ? 0 : 1)
    }
}
