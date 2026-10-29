import SwiftUI
import AppKit

/// Shared geometry for workspace forms, task controls and profile sheets.
enum KaddoUI {
    static let controlHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 12
    static let avatarSize: CGFloat = 48
    static let accent = Color(red: 0.64, green: 0.78, blue: 1)
}

struct KaddoButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .frame(minHeight: KaddoUI.controlHeight)
            .foregroundStyle(prominent ? Color(white: 0.12) : configuration.role == .destructive ? Color(red: 1, green: 0.55, blue: 0.53) : Color.white.opacity(0.88))
            .background(prominent ? KaddoUI.accent : Color.white.opacity(configuration.isPressed ? 0.12 : 0.065), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous).strokeBorder(.white.opacity(prominent ? 0.25 : 0.09)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous))
    }
}

struct KaddoTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .font(.system(size: 13, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minHeight: KaddoUI.controlHeight)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

struct KaddoMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var expanded = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? title).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 12).frame(height: KaddoUI.controlHeight)
                .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.09)))
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.4)
            .help(options.first { $0.0 == selection }?.1 ?? title)
            .accessibilityLabel(title).accessibilityValue(options.first { $0.0 == selection }?.1 ?? title)
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(options.indices, id: \.self) { index in
                            Button { selection = options[index].0; expanded = false } label: {
                                HStack {
                                    Text(options[index].1).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 12)
                                    Image(systemName: "checkmark").opacity(selection == options[index].0 ? 1 : 0)
                                }.font(.system(size: 12, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: KaddoUI.controlHeight)
                                    .background(.white.opacity(selection == options[index].0 ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }.padding(8)
                }.frame(width: 280, height: min(CGFloat(options.count) * 48 + 16, 320))
            }
    }
}

/// Segments and editors share the same outer geometry as single-line fields.
struct KaddoSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                Button { selection = options[index].0 } label: {
                    Text(options[index].1).font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity).frame(minHeight: KaddoUI.controlHeight - 8)
                        .foregroundStyle(selection == options[index].0 ? Color(white: 0.12) : .white.opacity(0.7))
                        .background(selection == options[index].0 ? KaddoUI.accent : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == options[index].0 ? .isSelected : [])
            }
        }.padding(4).background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .opacity(enabled ? 1 : 0.4).accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct KaddoTextEditor: View {
    @Binding var text: String
    var monospaced = false
    var body: some View {
        Group {
            if monospaced { KaddoCodeEditor(text: $text) }
            else { TextEditor(text: $text).font(.system(size: 13, design: .rounded)).scrollContentBackground(.hidden) }
        }.padding(12)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius, style: .continuous))
    }
}

/// JSON must preserve literal quotes, dashes and user-entered characters.
private struct KaddoCodeEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if let editor = scroll.documentView as? NSTextView, editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
