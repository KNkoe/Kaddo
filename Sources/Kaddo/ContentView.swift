import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let accent = Color(red: 0.64, green: 0.78, blue: 1)
struct Mascot: View {
    var size: CGFloat = 72
    var mood: CharacterMood = .idle
    var body: some View { KaddoCharacter(size: size, mood: mood) }
}

/// Conversation body. The companion workspace owns navigation and the shared sidebar.
struct ContentView: View {
    var embedded = false
    var startsTyping = false
    var focusRequest: UUID?
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var typingMode = false
    @State private var thinkingSince = Date()
    @State private var celebrationID: UUID?
    @State private var replyBaseline: UUID?
    @State private var replyConversation: UUID?
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var characterMood: CharacterMood {
        model.isListening ? .listening : model.selectedConversationIsBusy ? .thinking : celebrationID != nil ? .happy : .idle
    }
    private var lastAssistantID: UUID? {
        model.selectedConversation?.messages.last(where: { $0.role == "assistant" })?.id
    }
    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack {
                    Mascot(size: 28, mood: characterMood)
                    Text(model.selectedConversation?.title ?? "Kaddo").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(KaddoControlStyle())
                }.padding(18)
            }
            if let messages = model.selectedConversation?.messages, !messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(messages) { message in
                                messageRow(message).id(message.id).modifier(KaddoMessageArrival(reduceMotion: reduceMotion))
                            }
                            if model.selectedConversationIsBusy {
                                thinkingIndicator.padding(.vertical, 8).id("thinking")
                            }
                        }.padding(.leading, 50).padding(.trailing, 22).padding(.vertical, 20)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let id = messages.last?.id { withAnimation(reduceMotion ? nil : KaddoMotion.content) { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                    .onChange(of: model.busy) { _, busy in
                        if busy { withAnimation(reduceMotion ? nil : KaddoMotion.content) { proxy.scrollTo("thinking", anchor: .bottom) } }
                    }
                }
            } else {
                Spacer()
                VStack(spacing: 14) {
                    if embedded { Image(systemName: "bubble.left").font(.system(size: 32)).foregroundStyle(.tertiary) }
                    Text("What’s on your mind?").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("Start with a question, an idea, or something you’d like a hand with.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(30)
                Spacer()
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if case .failed = model.voiceReadiness {
                        Button("Try voice again") { model.selectMainCompanion(); model.startVoiceConversation() }
                            .buttonStyle(.plain)
                    }
                    Button("Dismiss") { model.error = nil }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 24).padding(.bottom, 10)
            }
            composer
        }
        .background(embedded ? Color.clear : Color(white: 0.118))
        .onAppear { typingMode = startsTyping || !model.input.isEmpty || !model.attachments.isEmpty }
        .onChange(of: model.busy) { _, busy in
            if busy { thinkingSince = Date(); celebrationID = nil; replyBaseline = lastAssistantID; replyConversation = model.selectedID }
            else if replyConversation == model.selectedID, let latest = lastAssistantID, latest != replyBaseline, model.error == nil { celebrationID = latest }
        }
        .onChange(of: model.selectedID) { _, _ in celebrationID = nil }
        .task(id: focusRequest) {
            guard focusRequest != nil else { return }
            typingMode = true
            await Task.yield()
            guard !Task.isCancelled else { return }
            composerFocused = true
        }
        .onExitCommand {
            if model.voiceIsStarting { model.stopVoiceConversation() }
            else if model.busy { model.cancel() }
            else if model.isListening && !model.voiceConversationEnabled { model.stopListening() }
        }
        .task(id: celebrationID) {
            guard celebrationID != nil else { return }
            do { try await Task.sleep(nanoseconds: KaddoMotion.celebrationDuration) } catch { return }
            celebrationID = nil
        }
        .sheet(isPresented: $showSettings) { ConnectionView().environmentObject(model).frame(width: 540) }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(.init(message.content)).textSelection(.enabled).font(.system(size: 15, design: .rounded)).lineSpacing(6)
                    .padding(message.role == "user" ? 13 : 0)
                    .foregroundStyle(message.role == "user" ? Color(white: 0.13) : .white)
                    .background { if message.role == "user" { MessageBubble().fill(LinearGradient(colors: [Color(red: 0.77, green: 0.87, blue: 1), accent], startPoint: .top, endPoint: .bottom)).overlay(MessageBubble().stroke(.white.opacity(0.35), lineWidth: 0.6)) } }
                if message.role == "assistant" {
                    HStack(spacing: 12) {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy response")
                        if model.isMainAgentSelected { Button { model.speak(message.content) } label: { Image(systemName: "speaker.wave.2") }.help("Read aloud") }
                    }.font(.system(size: 10)).buttonStyle(KaddoControlStyle()).foregroundStyle(.tertiary).padding(.top, 3)
                }
            }
            if message.role != "user" { Spacer(minLength: 0) }
        }
    }

    private var thinkingIndicator: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
                        HStack(spacing: 5) {
                            ForEach(0..<3) { index in
                                Circle().fill(.white.opacity(reduceMotion ? 0.65 : 0.35 + (sin(context.date.timeIntervalSinceReferenceDate * 3 - Double(index)) + 1) * 0.28)).frame(width: 5, height: 5)
                            }
                        }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 11).background(Color(white: 0.27), in: Capsule())
                Circle().fill(Color(white: 0.27)).frame(width: 6, height: 6).offset(x: 8)
                Circle().fill(Color(white: 0.27)).frame(width: 3, height: 3).offset(x: 4)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.codexExecutionTitle) · \(max(0, Int(context.date.timeIntervalSince(thinkingSince))))s")
                    if !model.codexExecutionDetail.isEmpty { Text(model.codexExecutionDetail).lineLimit(2) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if model.voiceConversationEnabled { voiceConnectionPanel }
            if model.busy && !model.selectedConversationIsBusy {
                Text("\(model.replyingAgentName) is replying in another conversation. You can keep drafting here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.attachments) { item in
                            HStack(spacing: 5) {
                                Image(systemName: item.imagePath == nil ? "doc.text" : "viewfinder")
                                Text(item.title).lineLimit(1)
                                Button { model.removeContext(item.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                            }.font(.system(size: 11)).padding(7).background(.white.opacity(0.07), in: Capsule())
                        }
                    }
                }
                Text("Attached context is sent with your next message.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: typingMode ? 14 : 10) {
                if !model.isMainAgentSelected && model.voiceConversationEnabled {
                    Button { model.stopVoiceConversation() } label: { Image(systemName: "phone.down.fill") }
                        .help("End Kaddo voice").accessibilityLabel("End Kaddo voice")
                }
                if model.voiceConversationEnabled {
                    Button { model.toggleVoiceInputMute() } label: { Image(systemName: model.voiceInputMuted ? "mic.slash.fill" : "mic.fill").foregroundStyle(model.voiceInputMuted ? Color.orange : Color.secondary) }
                        .help(model.voiceInputMuted ? "Unmute Kaddo microphone" : "Mute Kaddo microphone")
                        .accessibilityLabel(model.voiceInputMuted ? "Unmute Kaddo microphone" : "Mute Kaddo microphone")
                }
                if model.isMainAgentSelected { VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if model.voiceConversationEnabled { model.stopVoiceConversation() }
                        else { model.startVoiceConversation() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.voiceConversationEnabled ? "phone.down.fill" : "mic.fill").font(.system(size: 15))
                            if !typingMode { Text(model.voiceIsStarting ? "Cancel connection" : model.voiceConversationEnabled ? "End voice conversation" : "Start voice conversation").font(.system(size: 13, weight: .semibold, design: .rounded)) }
                        }.foregroundStyle(Color(white: 0.13)).frame(width: typingMode ? 60 : 300, height: 42)
                            .background(LinearGradient(colors: [Color(red: 0.77, green: 0.87, blue: 1), accent], startPoint: .top, endPoint: .bottom), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 0.7))
                    }.buttonStyle(KaddoControlStyle()).help(model.voiceConversationEnabled ? "End voice conversation" : "Speak, then pause to send")
                        .accessibilityLabel(model.voiceIsStarting ? "Cancel voice connection" : model.voiceConversationEnabled ? "End voice conversation" : "Start voice conversation")
                        .disabled(model.busy && !model.voiceConversationEnabled)
                } }
                if typingMode || !model.isMainAgentSelected {
                    HStack(alignment: .bottom, spacing: 10) {
                        Button { importDocument() } label: { Image(systemName: "paperclip").font(.system(size: 16)) }.help("Attach a document or image")
                        TextField("Message \(model.selectedHelper?.name ?? "Kaddo")…", text: $model.input, axis: .vertical)
                            .lineLimit(1...6).textFieldStyle(.plain).font(.system(size: 13, design: .rounded)).focused($composerFocused).onSubmit { model.send() }
                        if !model.voiceConversationEnabled { Button { model.isListening ? model.stopListening() : model.startListening() } label: {
                            Image(systemName: model.isListening ? "stop.circle.fill" : "mic").foregroundStyle(model.isListening ? Color.red : Color.secondary)
                        }.help("Dictate with your microphone") }
                        Button { model.busy ? model.cancel() : model.send() } label: {
                            Image(systemName: model.busy ? "stop.fill" : "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(white: 0.13))
                                .frame(width: 26, height: 26).background(accent, in: Circle())
                        }.disabled(!model.busy && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty)
                            .keyboardShortcut(.return, modifiers: .command).accessibilityLabel(model.busy ? "Stop \(model.replyingAgentName)’s response" : "Send message")
                    }.buttonStyle(KaddoControlStyle()).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 42)
                        .background(Color(white: 0.155), in: RoundedRectangle(cornerRadius: 23))
                        .overlay(RoundedRectangle(cornerRadius: 23).stroke(LinearGradient(colors: [Color(red: 0.73, green: 0.81, blue: 1), Color(red: 0.62, green: 0.63, blue: 0.88)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
                        .overlay(RoundedRectangle(cornerRadius: 22).inset(by: 2).stroke(.white.opacity(0.12), lineWidth: 0.5))
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    Button { withAnimation(reduceMotion ? nil : KaddoMotion.content) { typingMode = true }; composerFocused = true } label: {
                        HStack { Text("Type…"); Spacer(); Image(systemName: "keyboard") }.font(.system(size: 12)).padding(.horizontal, 17).frame(width: 148, height: 42)
                            .background(Color(white: 0.155), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.8))
                    }.buttonStyle(KaddoControlStyle()).foregroundStyle(.secondary).accessibilityLabel("Type a message")
                    Spacer(minLength: 0)
                }
            }
            Text(model.voiceConversationEnabled ? "⌃⌥ Hold to talk · Release to mute · Replies keep playing" : model.isListening ? "Listening… tap the microphone to stop" : model.busy ? "Keep drafting · Esc stops this response" : "⌃⌥ Talk to Kaddo · ⌘⇧Space type to this agent · ⌘ Return send")
                .font(.system(size: 10)).foregroundStyle(.tertiary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.leading, typingMode ? -2 : 15).padding(.trailing, typingMode ? 28 : 15).padding(.bottom, 12)
    }

    private var voiceConnectionPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.voiceIsStarting { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
            else { Image(systemName: model.voiceInputMuted ? "mic.slash" : "waveform").foregroundStyle(model.voiceInputMuted ? Color.secondary : accent).frame(width: 18, height: 18) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.voiceIsStarting ? model.voiceStartupTitle : model.voiceInputMuted ? "Ready when you are" : model.voiceStatus.replacingOccurrences(of: " · Codex voice", with: ""))
                    .font(.system(size: 12, weight: .semibold))
                Text(model.voiceIsStarting ? model.voiceStartupDetail + (model.voiceInputMuted ? " Microphone will stay muted when ready." : " Wait for Listening before speaking.") : model.voiceScreenStatus)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.voiceIsStarting { Button("Cancel") { model.stopVoiceConversation() }.controlSize(.small).accessibilityLabel("Cancel voice connection") }
        }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 0.5))
            .accessibilityElement(children: .contain)
    }

    func importDocument() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .pdf, .rtf, .image, .json, .html, .sourceCode]
        if panel.runModal() == .OK, let url = panel.url {
            do { let item = try DocumentContext.load(url); model.addContext(title: item.title, text: item.text, imagePath: item.imagePath) }
            catch { model.error = error.localizedDescription }
        }
    }
}
private struct MessageBubble: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(19.0, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius), control: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 10))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + 3, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY - 2))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 13, y: rect.maxY - 1), control: CGPoint(x: rect.maxX - 6, y: rect.maxY + 1))
        path.addLine(to: CGPoint(x: radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - radius), control: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        return path
    }
}

struct ConnectionView: View {
    var onDone: (() -> Void)? = nil
    @ObservedObject private var sounds = SoundEffects.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.secondary); Text("Make Kaddo yours").font(.system(size: 19, weight: .bold, design: .rounded)); Spacer(); Button("Done") { if let onDone { onDone() } else { dismiss() } } }
            Text("Use your signed-in Codex CLI or connect an OpenAI-compatible model. Codex sends messages through your ChatGPT account; API mode uses only your chosen endpoint.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            KaddoSegmentedPicker(title: "Connection", selection: $model.provider, options: [("codex", "Codex · ChatGPT"), ("api", "API connection")])
            if model.provider == "api" { VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API base URL").font(.callout.weight(.medium))
                    TextField("https://example.com/v1", text: $model.endpoint).accessibilityLabel("API base URL")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model").font(.callout.weight(.medium))
                    TextField("Model identifier", text: $model.model).accessibilityLabel("Model")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("API key").font(.callout.weight(.medium))
                    SecureField("Optional for local models", text: $model.apiKey).accessibilityLabel("API key")
                }
            }.textFieldStyle(KaddoTextFieldStyle()) }
            Text(model.provider == "codex" ? "Uses your installed Codex CLI and existing sign-in. Chat mode runs with a read-only sandbox and a separate temporary working folder." : "For a local server, use a loopback /v1 endpoint. For a remote provider, use HTTPS and its model ID. Keys are stored in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Toggle("Sound effects", isOn: $sounds.enabled); Spacer(); Button("Preview sound") { sounds.play(.question) }.disabled(!sounds.enabled) }
            HStack { Text("Volume").font(.caption); Slider(value: $sounds.volume, in: 0...1).accessibilityLabel("Sound effect volume") }
            if let error = sounds.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            Label("Hold ⌃⌥ to talk. Codex voice shares microphone audio and screen context while active; End voice stops both. Dictation uses on-device recognition.", systemImage: "mic").font(.caption)
            Label("Use Desktop for screen context and reviewed actions, Apps for integrations, and Agents for background work.", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).padding(24).preferredColorScheme(.dark)
    }
}

struct HelperEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var instructions = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A helper for your kind of work").font(.title2.bold())
            Text("Give your helper a name and a focus. Its instructions apply to new conversations with that helper.").foregroundStyle(.secondary)
            TextField("Name, e.g. Writing buddy", text: $name).textFieldStyle(KaddoTextFieldStyle())
            Text("Instructions").font(.headline)
            KaddoTextEditor(text: $instructions).frame(height: 150).accessibilityLabel("Agent instructions")
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Create helper") { model.addHelper(name: name.trimmingCharacters(in: .whitespacesAndNewlines), instructions: instructions); dismiss() }.buttonStyle(KaddoButtonStyle(prominent: true)).tint(accent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).padding(24).frame(width: 480).preferredColorScheme(.dark)
    }
}
