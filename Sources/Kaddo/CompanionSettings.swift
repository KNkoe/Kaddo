import SwiftUI
import AppKit
import AVFoundation
import Speech

/// Settings stays inside the companion panel and uses the app's real capabilities.
struct CompanionSettingsView: View {
    var controller: NotchController? = nil
    var onBack: () -> Void
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var sounds = SoundEffects.shared
    @State private var selected = "General"
    @State private var startedDictationHere = false
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()

    private let background = Color(white: 0.118)
    private let blue = Color(red: 0.65, green: 0.79, blue: 1)
    private let personal = ["General", "AI Connection", "Voice", "Screen Access", "Microphone", "Dictation", "Shortcuts", "Cursor"]
    private let work = ["Agents", "Integrations"]

    var body: some View {
        HStack(spacing: 0) {
            navigation.frame(width: 201)
            ZStack(alignment: .topTrailing) {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: background, location: 0.30), .init(color: background, location: 1)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                windowControls.padding(.top, 30).padding(.trailing, 32)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 13, design: .rounded)).buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).background(background).preferredColorScheme(.dark)
        .onAppear { refreshPermissions() }
        .onChange(of: selected) { _, category in if category != "Dictation" { stopSettingsDictation() } }
        .onDisappear { stopSettingsDictation() }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.055), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.09), lineWidth: 0.6)) }
                    .buttonStyle(KaddoControlStyle())
                Text("Settings").font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }.frame(height: 76).padding(.horizontal, 17)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("KADDO")
                    ForEach(personal, id: \.self) { category in categoryButton(category) }
                    sectionLabel("WORK").padding(.top, 19)
                    ForEach(work, id: \.self) { category in categoryButton(category) }
                }.padding(.horizontal, 12).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 0)
        }.background(background).overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.bottom, 8)
    }
    private func categoryButton(_ category: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : KaddoMotion.content) { selected = category }
            if category == "Microphone" { refreshPermissions() }
        } label: {
            HStack(spacing: 10) { Image(systemName: icon(category)).font(.system(size: 14)).frame(width: 17); Text(category).font(.system(size: 13, weight: .medium, design: .rounded)); Spacer() }
                .foregroundStyle(selected == category ? .white : .white.opacity(0.56)).padding(.horizontal, 12).frame(height: KaddoUI.controlHeight)
                .background(selected == category ? .white.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius)).contentShape(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
        }.buttonStyle(.plain)
    }
    private func icon(_ category: String) -> String {
        ["General": "slider.horizontal.3", "AI Connection": "circle.hexagongrid", "Voice": "waveform", "Screen Access": "rectangle.inset.filled", "Microphone": "mic", "Dictation": "text.bubble", "Shortcuts": "keyboard", "Cursor": "cursorarrow", "Agents": "sparkles", "Integrations": "square.grid.2x2"][category] ?? "circle"
    }

    @ViewBuilder private var detail: some View {
        switch selected {
        case "Agents":
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let proactive = runtime.proactive { ProactiveAgentSettingsView(controller: proactive, screenSource: runtime.proactiveScreenSource) }
                    Button("Open agent workspace") { runtime.showsSettings = false; runtime.selectedTab = "Agents"; runtime.showWorkspace() }
                }.padding(26).padding(.top, 38).frame(maxWidth: .infinity, alignment: .leading)
            }
        case "Integrations":
            IntegrationsView(store: runtime.integrations) { result in runtime.addIntegration(result); onBack() }.padding(.horizontal, 2).padding(.top, 65)
        case "AI Connection":
            ScrollView { ConnectionView(onDone: { selected = "General" }).environmentObject(model).padding(.horizontal, 2).padding(.top, 62) }
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    switch selected {
                    case "Screen Access": ScreenAccessSettingsView(controller: runtime.desktop)
                    case "Voice": voice
                    case "Microphone": microphone
                    case "Dictation": dictation
                    case "Shortcuts": shortcuts
                    case "Cursor": cursor
                    default: general
                    }
                }.padding(.leading, 26).padding(.trailing, 35).padding(.top, 86).padding(.bottom, 26).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(selected).font(.system(size: 19, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 2).padding(.trailing, 65)
    }
    private var subtitle: String {
        switch selected {
        case "Screen Access": return "Let Kaddo see your screen during voice and explicit captures."
        case "Voice": return "Give your conversations a voice."
        case "Microphone": return "Manage microphone and speech recognition access."
        case "Dictation": return "Speak into your message draft."
        case "Shortcuts": return "A few quick ways to get to Kaddo."
        case "Cursor": return "A little companion for your pointer."
        default: return "Make Kaddo feel at home on your Mac."
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                settingToggle("Show in Dock", description: "Keep Kaddo in the Dock and app switcher.", value: $runtime.showInDock)
                rowDivider
                settingToggle("Show in screen recordings", description: "Include the Kaddo panel and pointer companion in recordings.", value: $runtime.showInScreenRecordings)
                rowDivider
                settingToggle("Quick peek on notch hover", description: "Hovering the notch shows your Kaddos and their latest conversations. Turn off to open Home straight away.", value: $runtime.quickPeekOnHover)
            }.padding(.top, 6).overlay(alignment: .topLeading) {
                Text("BEHAVIOR").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.tertiary).padding(.leading, 4).offset(y: -12)
            }
            Text("SOUND").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.tertiary)
            card {
                settingToggle("Sound effects", description: "Little sounds for the things Kaddo does.", value: $sounds.enabled)
                rowDivider
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Volume"); Spacer(); Text("\(Int(sounds.volume * 100))%").foregroundStyle(.secondary).monospacedDigit() }
                    HStack(spacing: 14) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $sounds.volume, in: 0...1).tint(blue).accessibilityLabel("Sound effect volume")
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                        Button("Preview") { sounds.play(.question) }.buttonStyle(KaddoButtonStyle()).controlSize(.small).disabled(!sounds.enabled)
                    }
                    if let error = sounds.lastError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                }.padding(14)
            }
        }
    }

    private var voice: some View {
        card {
            settingToggle("Fast voice startup", description: "Keep a silent connection ready. Microphone and screen stay off until you start voice. Turn off to connect only on demand.", value: $model.fastVoiceStartup)
            rowDivider
            informationRow("Codex voice", description: "Speak with Kaddo through your signed-in Codex voice session. Microphone audio streams to Codex while voice is active, and replies play through your speakers. Kaddo can report helper progress and results; helpers stay text-only. End voice to stop microphone capture.")
            informationRow("Read aloud & dictation", description: "Manual read aloud uses macOS speech. Dictation uses on-device speech recognition and sends text through your selected AI connection.")
            rowDivider
            HStack(spacing: 10) {
                Button("Read aloud test") { model.speak("Hello, I am Kaddo.") }.buttonStyle(KaddoButtonStyle(prominent: true)).tint(blue)
                Button("Stop speaking") { model.stopSpeaking() }.buttonStyle(KaddoButtonStyle())
                Spacer()
            }.controlSize(.small).padding(14)
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                permissionRow("Microphone", status: microphoneLabel, action: { openPrivacy("Microphone") })
                rowDivider
                permissionRow("Speech Recognition", status: speechLabel, action: { openPrivacy("SpeechRecognition") })
            }
            Text("Kaddo listens only after you start dictation or voice. Codex voice streams microphone audio using your Codex sign-in; End voice stops capture. Dictation runs on device and sends its transcript with your message. Helper agents do not have voice sessions.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Refresh permission status") { refreshPermissions() }.buttonStyle(KaddoButtonStyle()).controlSize(.small)
        }
    }

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                informationRow("On-device dictation", description: "Speak to add text to your draft. Dictation does not send the message; review and send it from your conversation.")
                rowDivider
                VStack(alignment: .leading, spacing: 13) {
                    Button(model.isListening ? "Stop dictation" : "Start dictation") {
                        if model.isListening { model.stopListening(); startedDictationHere = false }
                        else { startedDictationHere = true; model.startListening() }
                    }
                        .buttonStyle(KaddoButtonStyle(prominent: true)).tint(model.isListening ? .red : blue).disabled(model.busy)
                    TextField("Your message draft…", text: $model.input, axis: .vertical).lineLimit(3...7).textFieldStyle(KaddoTextFieldStyle())
                    if model.isListening { Label("Listening… stop dictation when you’re finished.", systemImage: "mic.fill").font(.system(size: 11)).foregroundStyle(blue) }
                }.padding(14)
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    private var shortcuts: some View {
        card {
            shortcutRow("Open or close Kaddo", keys: "⌘ ⇧ Space")
            Text("Opens the selected agent’s conversation with the message field ready to type. Press again to close the focused notch.").font(.caption).foregroundStyle(.secondary)
            rowDivider
            shortcutRow("Hold to talk to Kaddo", keys: "⌃ ⌥")
            Text("Wait for Listening, then speak. Release to mute; replies keep playing. Hold again to continue. Voice always belongs to your main companion.").font(.caption).foregroundStyle(.secondary)
            rowDivider
            shortcutRow("Cancel connection or response", keys: "Esc")
            rowDivider
            shortcutRow("Open Kaddo notch", keys: "⌘ ⇧ K")
            rowDivider
            shortcutRow("Chat · Desktop · Apps · Agents", keys: "⌘ ⌥ 1–4")
            rowDivider
            shortcutRow("Previous or next agent", keys: "⌘ ⌥ [ / ]")
            rowDivider
            shortcutRow("Send message", keys: "⌘ Return")
            rowDivider
            shortcutRow("New helper", keys: "⌘ N")
        }
    }

    private var cursor: some View {
        card {
            settingToggle("Pointer companion", description: "Let your Kaddo follow the pointer around your desktop.", value: $runtime.companionEnabled)
            rowDivider
            informationRow("Motion follows your Mac", description: "Kaddo respects the Reduce Motion setting in System Settings → Accessibility → Display.")
        }
    }

    private var windowControls: some View {
        HStack(spacing: 15) {
            if controller != nil {
                Button { runtime.showWorkspace() } label: { Image(systemName: "pip.enter") }.help("Open as window")
            }
            if let controller {
                Button { controller.collapse() } label: { Image(systemName: "xmark") }.help("Close Kaddo")
            }
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.225), lineWidth: 0.8))
    }
    private var rowDivider: some View { Rectangle().fill(.white.opacity(0.075)).frame(height: 0.6).padding(.horizontal, 14) }
    private func settingToggle(_ title: String, description: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .medium)); Text(description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(KaddoGlossySwitch()).accessibilityLabel(title)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
    private func informationRow(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 13, weight: .medium)); Text(description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.padding(14)
    }
    private func permissionRow(_ title: String, status: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .medium)); Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            Button("Open Settings", action: action).buttonStyle(KaddoButtonStyle()).controlSize(.small)
        }.padding(14)
    }
    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack { Text(title).font(.system(size: 12)); Spacer(); Text(keys).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 6).background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 6)) }.padding(14)
    }
    private var microphoneLabel: String {
        switch microphoneStatus { case .authorized: return "Allowed"; case .denied: return "Not allowed"; case .restricted: return "Restricted by this Mac"; case .notDetermined: return "Not requested"; @unknown default: return "Unknown" }
    }
    private var speechLabel: String {
        switch speechStatus { case .authorized: return "Allowed"; case .denied: return "Not allowed"; case .restricted: return "Restricted by this Mac"; case .notDetermined: return "Not requested"; @unknown default: return "Unknown" }
    }
    private func stopSettingsDictation() {
        guard startedDictationHere else { return }
        model.stopListening(); startedDictationHere = false
    }
    private func refreshPermissions() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
    }
}

private struct KaddoGlossySwitch: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(reduceMotion ? nil : KaddoMotion.control) { configuration.isOn.toggle() } } label: {
            Capsule().fill(configuration.isOn ? LinearGradient(colors: [Color(red: 0.83, green: 0.90, blue: 1), Color(red: 0.52, green: 0.72, blue: 1)], startPoint: .top, endPoint: .bottom) : LinearGradient(colors: [Color(white: 0.36), Color(white: 0.29)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(configuration.isOn ? Color(red: 0.54, green: 0.53, blue: 1) : .white.opacity(0.18), lineWidth: 1))
                .overlay(Capsule().inset(by: 2).stroke(.white.opacity(configuration.isOn ? 0.6 : 0.08), lineWidth: 0.6))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? .black : Color(white: 0.78)).frame(width: 19, height: 19).padding(2.5)
                }.frame(width: 46, height: 24)
        }.buttonStyle(.plain)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}
