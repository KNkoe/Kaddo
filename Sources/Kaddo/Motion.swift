import SwiftUI

/// Shared pacing. The reference app's private spring coefficients are unknown.
enum KaddoMotion {
    static let panelDuration: Double = 0.38
    static let reveal = Animation.spring(response: panelDuration, dampingFraction: 0.88)
    static let content = Animation.easeOut(duration: 0.22)
    static let control = Animation.easeOut(duration: 0.14)
    static let celebrationDuration: UInt64 = 1_200_000_000

    static func arrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8))
    }
}

/// A small press/hover response, without changing the control's hit target.
struct KaddoControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        ControlBody(configuration: configuration, reduceMotion: reduceMotion)
    }
    private struct ControlBody: View {
        let configuration: ButtonStyleConfiguration
        let reduceMotion: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .brightness(hovered ? 0.05 : 0)
                .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.97 : hovered ? 1.015 : 1)
                .animation(reduceMotion ? nil : KaddoMotion.control, value: hovered)
                .animation(reduceMotion ? nil : KaddoMotion.control, value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

/// Listening is a synthetic activity waveform, not measured audio amplitude.
/// Thinking uses staggered opacity dots rather than an unrelated spinning loader.
struct KaddoActivityIndicator: View {
    var isListening: Bool = false
    var isThinking: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if isListening || isThinking {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 8) {
                    HStack(alignment: .center, spacing: isListening ? 3 : 4) {
                        ForEach(0..<(isListening ? 5 : 3), id: \.self) { index in
                            let pulse = (sin(time * (isListening ? 5 : 3) - Double(index) * 0.8) + 1) / 2
                            Capsule()
                                .fill(Color(red: 0.72, green: 0.91, blue: 0.46))
                                .frame(width: isListening ? 3 : 5,
                                       height: isListening ? (reduceMotion ? 8 : 4 + pulse * 11) : 5)
                                .opacity(reduceMotion ? 0.8 : 0.35 + pulse * 0.65)
                        }
                    }.frame(width: 27, height: 16)
                    Text(isListening ? "Listening…" : "Thinking…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isListening ? "Kaddo is listening" : "Kaddo is thinking")
        }
    }
}

/// Minimal once-per-appearance staggering for the three welcome suggestions.
struct KaddoSuggestionEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible || reduceMotion ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(reduceMotion ? nil : KaddoMotion.content.delay(Double(index) * 0.045)) { visible = true }
            }
    }
}

/// Arrival animates pixels without interpolating the list's layout and scroll twice.
struct KaddoMessageArrival: ViewModifier {
    var reduceMotion: Bool
    @State private var arrived = false
    func body(content: Content) -> some View {
        content.opacity(arrived || reduceMotion ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 6)
            .onAppear { withAnimation(reduceMotion ? nil : KaddoMotion.content) { arrived = true } }
    }
}
