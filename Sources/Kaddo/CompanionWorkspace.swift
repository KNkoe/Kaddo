import SwiftUI
import AppKit

private enum CompanionPalette {
    static let background = Color(white: 0.118)
    static let blue = Color(red: 0.64, green: 0.78, blue: 1)
    static let glossy = LinearGradient(colors: [Color(red: 0.77, green: 0.87, blue: 1), Color(red: 0.60, green: 0.76, blue: 1)], startPoint: .top, endPoint: .bottom)
}

/// One shared layout for the notch and the optional detached workspace.
struct CompanionWorkspaceView: View {
    var controller: NotchController? = nil
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var sounds = SoundEffects.shared
    @State private var search = ""
    @AppStorage("companionSidebarVisible") private var sidebarVisible = true
    @State private var creatingHelper = false
    @State private var helperName = ""
    @State private var helperInstructions = ""
    @State private var namingHelper = false
    @State private var draftBeforeHelperVoice: String?
    @State private var pendingDelete: UUID?
    @State private var showHistory = false
    @State private var prefersTyping = false
    @State private var editingAgent: HelperProfile?

    private var helperForChat: HelperProfile? {
        model.helpers.first { $0.id == model.selectedConversation?.helperID } ?? model.selectedHelper
    }
    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        default: return "Good evening."
        }
    }
    var body: some View {
        Group {
        if runtime.showsSettings {
            CompanionSettingsView(controller: controller, onBack: { runtime.showsSettings = false })
        } else {
        HStack(spacing: 0) {
            if !creatingHelper {
                Group { if sidebarVisible { sidebar.transition(.identity) } else { iconRail.transition(.identity) } }.frame(width: sidebarVisible ? 260 : 90).clipped()
            }
            VStack(spacing: 0) {
                topBar
                Group {
                    if creatingHelper { GeometryReader { geometry in ScrollView { helperCreation.frame(minHeight: geometry.size.height) }.scrollIndicators(.hidden) } }
                    else {
                        switch runtime.selectedTab {
                        case "Desktop": DesktopToolsView(controller: runtime.desktop, onAttach: runtime.attach, planner: runtime.plan)
                        case "Apps": IntegrationsView(store: runtime.integrations, onAddToChat: runtime.addIntegration)
                        case "Agents": AgentJobsView(store: runtime.jobs, helpers: model.helpers, createAgent: beginHelperCreation, showSuggestions: { runtime.proactive?.showSuggestions() }, suggestionCount: runtime.proactive?.pendingCount ?? 0, selectedAgentID: model.selectedHelperID, requestedJobID: runtime.requestedJobID, onInspectionDismiss: { runtime.requestedJobID = nil }, onProfile: { editingAgent = $0 })
                        default:
                            if runtime.showsHome { home }
                            else { ContentView(embedded: true, startsTyping: prefersTyping, focusRequest: runtime.composerFocusRequest) }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = runtime.error { Text(error).font(.caption).foregroundStyle(.orange).padding(8) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: CompanionPalette.background, location: 0.30), .init(color: CompanionPalette.background, location: 1)], startPoint: .top, endPoint: .bottom))
        }
        }
        }
        .environment(\.mainCompanionSuppressed, runtime.proactive?.isPanelPresented == true && runtime.proactive?.isReviewing == false)
        .font(.system(size: 13, design: .rounded))
        .buttonStyle(KaddoButtonStyle())
        .textFieldStyle(KaddoTextFieldStyle())
        .sheet(item: $editingAgent) { helper in AgentProfileView(helperID: helper.id).environmentObject(model) }
        .background(CompanionPalette.background).preferredColorScheme(.dark)
        .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let id = pendingDelete { model.deleteConversation(id) }; pendingDelete = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { goHome() } label: { Image(systemName: "house").font(.system(size: 19)).foregroundStyle(.secondary).frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }.buttonStyle(.plain).accessibilityLabel("Kaddo Home")
                Spacer()

            }.padding(.bottom, 16)
            HStack(spacing: 9) {
                Button { toggleSidebar() } label: { Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }.buttonStyle(.plain).help("Hide sidebar")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                }.padding(.horizontal, 10).frame(height: KaddoUI.controlHeight).background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
                Button { beginHelperCreation() } label: { Image(systemName: "plus.square").font(.system(size: 17)).frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }
                    .buttonStyle(KaddoControlStyle()).help("New agent").accessibilityLabel("New agent").keyboardShortcut("n")
            }.padding(.bottom, 14)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(orderedHelpers.enumerated()), id: \.element.id) { index, helper in
                        if search.isEmpty || helper.name.localizedCaseInsensitiveContains(search) || chats(for: helper).contains(where: { $0.title.localizedCaseInsensitiveContains(search) }) {
                            helperRow(helper, index: index)
                        }
                    }
                    if showHistory || !search.isEmpty {
                        Text("CONVERSATIONS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18).padding(.bottom, 7)
                        ForEach(model.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { chat in
                            Button {
                                model.selectedID = chat.id
                                if let helperID = chat.helperID { model.selectedHelperID = helperID }
                                openChat()
                            } label: {
                                HStack(spacing: 7) { Image(systemName: "bubble.left").font(.system(size: 10)); Text(chat.title).lineLimit(1); Spacer() }
                                    .font(.system(size: 11)).padding(.vertical, 8).padding(.horizontal, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .contextMenu { Button("Delete conversation", role: .destructive) { pendingDelete = chat.id } }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                utilityButton("Apps", icon: "square.grid.2x2", tab: "Apps")
                utilityButton("Desktop", icon: "desktopcomputer", tab: "Desktop")
                utilityButton("Agents", icon: "sparkles", tab: "Agents")
            }.padding(.bottom, 12)
            HStack(spacing: 9) {
                Circle().fill(CompanionPalette.blue.opacity(0.2)).frame(width: 28, height: 28).overlay(Text("K").font(.system(size: 12, weight: .bold)).foregroundStyle(CompanionPalette.blue))
                VStack(alignment: .leading, spacing: 2) { Text("Kaddo").font(.system(size: 12, weight: .semibold)); Text("Personal workspace").font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Button { showHistory.toggle() } label: { Image(systemName: "clock").font(.system(size: 13)) }.buttonStyle(.plain).help("Conversation history")
                    .frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight).accessibilityLabel("Conversation history")
                Menu {
                    Button("Settings & connection") { runtime.showsSettings = true }
                    if let controller { Toggle("Keep notch open", isOn: Binding(get: { controller.pinned }, set: { controller.pinned = $0 })) }
                    Toggle("Pointer companion", isOn: $runtime.companionEnabled)
                    Toggle("Sound effects", isOn: $sounds.enabled)
                } label: { Image(systemName: "gearshape").font(.system(size: 14)) }.menuStyle(.borderlessButton).fixedSize().help("Settings & connection")
            }
        }.padding(.horizontal, 12).padding(.top, 25).padding(.bottom, 12)
        .background(CompanionPalette.background)

    }

    private var iconRail: some View {
        VStack(spacing: 0) {
            Button { goHome() } label: { Image(systemName: "house").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }.buttonStyle(.plain).help("Home").accessibilityLabel("Kaddo Home")
                .padding(.bottom, 12)
            VStack(spacing: 0) {
                Button { toggleSidebar() } label: { Image(systemName: "sidebar.left").frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }.help("Show sidebar").accessibilityLabel("Show sidebar")
                Button { search = ""; showHistory = true; toggleSidebar() } label: { Image(systemName: "magnifyingglass").frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }.help("Search conversations").accessibilityLabel("Search conversations")
                Button { beginHelperCreation() } label: { Image(systemName: "plus").frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }.help("New agent").accessibilityLabel("New agent").keyboardShortcut("n")
            }.font(.system(size: 17)).foregroundStyle(.secondary).buttonStyle(.plain).labelStyle(.iconOnly).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(orderedHelpers.enumerated()), id: \.element.id) { index, helper in
                        Button {
                            model.selectedHelperID = helper.id
                            if let latest = chats(for: helper).first { model.selectedID = latest.id } else { model.newConversation() }
                            openChat()
                        } label: {
                            agentTile(helper)
                                .background { if !runtime.showsHome && runtime.selectedTab == "Chat" && helperForChat?.id == helper.id { RoundedRectangle(cornerRadius: KaddoUI.cornerRadius).fill(CompanionPalette.glossy) } }
                        }.buttonStyle(KaddoControlStyle()).help(helper.name).accessibilityLabel(helper.name)
                            .contextMenu { Button("Agent profile") { editingAgent = helper } }
                    }
                }.frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 10)
            VStack(spacing: 4) {
                railUtility("Apps", icon: "square.grid.2x2")
                railUtility("Desktop", icon: "desktopcomputer")
                railUtility("Agents", icon: "sparkles")
            }.padding(.bottom, 12)
            Menu {
                Button("Settings & connection") { runtime.showsSettings = true }
                Button("Conversation history") { showHistory = true; toggleSidebar() }
                Toggle("Pointer companion", isOn: $runtime.companionEnabled)
                Toggle("Sound effects", isOn: $sounds.enabled)
            } label: { Image(systemName: "gearshape").font(.system(size: 16)).frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }
                .menuStyle(.borderlessButton).fixedSize().help("Settings & connection")
        }.padding(.horizontal, 10).padding(.top, 25).padding(.bottom, 12)
            .frame(maxHeight: .infinity).background(CompanionPalette.background)
    
    }
    private func railUtility(_ title: String, icon: String) -> some View {
        Button { runtime.selectedTab = title; creatingHelper = false } label: { Image(systemName: icon).font(.system(size: 16)).frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight) }
            .buttonStyle(.plain).foregroundStyle(runtime.selectedTab == title ? CompanionPalette.blue : .secondary).help(title).accessibilityLabel(title)
    }
    private func beginHelperCreation() {
        creatingHelper = true; runtime.selectedTab = "Chat"; helperName = ""; helperInstructions = ""; namingHelper = false
    }

    private var orderedHelpers: [HelperProfile] {
        model.helpers.sorted { (chats(for: $0).first?.updatedAt ?? .distantPast) > (chats(for: $1).first?.updatedAt ?? .distantPast) }
    }
    private func chats(for helper: HelperProfile) -> [Conversation] { model.conversations.filter { $0.helperID == helper.id }.sorted { $0.updatedAt > $1.updatedAt } }
    private func helperRow(_ helper: HelperProfile, index: Int) -> some View {
        let latest = chats(for: helper).first
        let selected = !runtime.showsHome && !creatingHelper && runtime.selectedTab == "Chat" && helperForChat?.id == helper.id
        return Button {
            model.selectedHelperID = helper.id
            if let latest { model.selectedID = latest.id } else { model.newConversation() }
            openChat()
        } label: {
            HStack(spacing: 10) {
                agentTile(helper)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) {
                        Text(helper.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                        Spacer(minLength: 2)
                        if let latest { Text(latest.updatedAt, style: .time).font(.system(size: 12)).opacity(0.55).lineLimit(1) }
                    }
                    Text(selected && model.busy ? "Thinking…" : latest?.messages.last?.content ?? "Start a conversation")
                        .font(.system(size: 12)).lineLimit(1).opacity(selected ? 0.72 : 0.5)
                }
            }.padding(.horizontal, 10).frame(height: NotchGeometry.peekRowHeight).contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(selected ? Color(white: 0.14) : .white)
                .background { if selected { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CompanionPalette.glossy).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 0.7)) } }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.buttonStyle(.plain)
        .contextMenu {
            Button("New conversation") { model.selectedHelperID = helper.id; model.newConversation(); openChat() }
            Button("Agent profile") { editingAgent = helper }
            Button("Tasks & routines") { model.selectedHelperID = helper.id; runtime.selectedTab = "Agents"; creatingHelper = false }
            if let latest { Button("Delete latest conversation", role: .destructive) { pendingDelete = latest.id } }
        }
    }

    private func utilityButton(_ title: String, icon: String, tab: String) -> some View {
        Button { runtime.selectedTab = tab; creatingHelper = false } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: KaddoUI.controlHeight)
                .background(runtime.selectedTab == tab ? .white.opacity(0.13) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
        }.buttonStyle(KaddoControlStyle()).foregroundStyle(.secondary)
    }

    private var topBar: some View {
        let chat = runtime.selectedTab == "Chat" && !runtime.showsHome && !creatingHelper
        return ZStack(alignment: .top) {
            HStack(spacing: 10) {
                if creatingHelper || runtime.selectedTab != "Chat" {
                    Button { creatingHelper = false; goHome() } label: { Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.055), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.09), lineWidth: 0.6)) }
                    Text(creatingHelper ? "New agent" : runtime.selectedTab).font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button {
                    runtime.selectedTab = "Agents"; creatingHelper = false
                    runtime.showsSettings = false; runtime.showWorkspace()
                } label: { Label("Activity", systemImage: "list.bullet.rectangle").font(.system(size: 12)) }
                    .help("View all agent tasks, results and follow-ups")
                Button {
                    if controller != nil { runtime.showWorkspace() } else { runtime.show() }
                } label: {
                    Image(systemName: controller != nil ? "pip.enter" : "pip.exit")
                        .frame(width: KaddoUI.controlHeight, height: KaddoUI.controlHeight)
                }.help(controller != nil ? "Open as window" : "Back to the notch")
                    .accessibilityLabel(controller != nil ? "Open as window" : "Back to the notch")
                if let controller {
                    Button { controller.collapse() } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }.help("Close Kaddo")
                        .contextMenu { Toggle("Keep open", isOn: Binding(get: { controller.pinned }, set: { controller.pinned = $0 })) }
                }
            }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.leading, 20).padding(.trailing, 32).padding(.top, 24)
            if chat {
                VStack(spacing: 5) {
                    Menu {
                        if let helper = helperForChat { Button("Agent profile") { editingAgent = helper } }
                        Button("New conversation") { model.newConversation(); openChat() }
                        Button("Home") { goHome() }
                        Button("Conversation history") { showHistory = true; if !sidebarVisible { toggleSidebar() } }
                    } label: { Text(helperForChat?.name ?? "Kaddo").font(.system(size: 13, weight: .semibold, design: .rounded)) }
                        .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8).padding(.vertical, 4).background(.white.opacity(0.075), in: Capsule())
                }.padding(.top, 30)
            }
        }.frame(height: 65, alignment: .top)
    }

    private func agentTile(_ helper: HelperProfile) -> some View {
        // Keep one portrait per agent. Home and profile sheets own the dominant character.
        return Group {
            if editingAgent?.id == helper.id || (runtime.showsHome && runtime.selectedTab == "Chat" && helper.id == model.primaryHelperID) {
                Image(systemName: "bubble.left").font(.system(size: 18)).foregroundStyle(.secondary)
                    .frame(width: KaddoUI.avatarSize, height: KaddoUI.avatarSize)
            } else { AgentAvatar(profile: helper, size: KaddoUI.avatarSize, isMain: helper.id == model.primaryHelperID) }
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 0) {
                KaddoPerchedCharacter(size: 116).padding(.bottom, -2).zIndex(1)
                Button {
                    model.selectMainCompanion()
                    openChat(); model.startVoiceConversation()
                } label: {
                    HStack(spacing: 10) { Image(systemName: "mic.fill").font(.system(size: 14)); Text("Hi, how can I help ^_^?").font(.system(size: 14, weight: .semibold, design: .rounded)) }
                        .foregroundStyle(Color(white: 0.15)).frame(width: 225, height: 44)
                        .background(CompanionPalette.glossy, in: Capsule())
                        .overlay(Capsule().stroke(Color(red: 0.59, green: 0.59, blue: 0.96), lineWidth: 1.4))
                        .overlay(Capsule().inset(by: 2).stroke(.white.opacity(0.65), lineWidth: 0.7))
                        .overlay(alignment: .top) { Capsule().fill(.white.opacity(0.50)).frame(height: 5).padding(.horizontal, 19).padding(.top, 4) }
                        .shadow(color: CompanionPalette.blue.opacity(0.12), radius: 17, y: 4)
                }.buttonStyle(KaddoControlStyle()).accessibilityLabel("Start voice conversation")
                Text(greeting).font(.system(size: 18, weight: .bold, design: .rounded)).padding(.top, 20)
                Text("Start a conversation, or tell me what to take off your plate.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 8)

            }.padding(.horizontal, 25).offset(x: -8, y: 3.5)
            Spacer(minLength: 40)
        }
    }

    private var helperCreation: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                helperBubble(namingHelper ? "What should I call this agent?" : "What would you like this agent to do?")
                helperBubble(namingHelper ? "Give your agent a name you’ll recognize." : "Tell me a job you would like help with.")
                HStack(spacing: 4) { ForEach(0..<3) { index in Circle().fill(Color(red: 1, green: 0.77, blue: 0.56)).frame(width: CGFloat(4 + index * 2), height: CGFloat(4 + index * 2)) } }.offset(x: -12)
            }.frame(width: 360, alignment: .leading).frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 42)
            Mascot(size: 160, mood: model.isListening && draftBeforeHelperVoice != nil ? .listening : .happy)
                .frame(height: 160).shadow(color: .blue.opacity(0.16), radius: 20).offset(x: -37).padding(.top, 14)
            Spacer(minLength: 18)
            Button {
                if draftBeforeHelperVoice != nil { stopHelperVoice() }
                else {
                    model.stopVoiceConversation()
                    draftBeforeHelperVoice = model.input
                    model.input = namingHelper ? helperName : helperInstructions
                    model.startListening()
                }
            } label: {
                Label(draftBeforeHelperVoice != nil && model.isListening ? "Listening… tap to finish" : "Dictate your answer", systemImage: "mic.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.14))
                    .frame(width: 280, height: 50).background(CompanionPalette.glossy, in: Capsule())
                    .overlay(Capsule().stroke(Color(red: 0.59, green: 0.59, blue: 0.96), lineWidth: 1.4))
                    .overlay(Capsule().inset(by: 2).stroke(.white.opacity(0.6), lineWidth: 0.7))
            }.buttonStyle(KaddoControlStyle()).disabled(model.busy)
            HStack(spacing: 10) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                TextField(namingHelper ? "Name your agent…" : "or type your answer", text: namingHelper ? $helperName : $helperInstructions)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .rounded)).onSubmit { advanceHelper() }
                Button(action: advanceHelper) { Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).background(.white.opacity(0.09), in: Circle()) }
                    .buttonStyle(KaddoControlStyle()).disabled((namingHelper ? helperName : helperInstructions).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(namingHelper ? "Create agent" : "Continue agent setup")
            }.padding(.horizontal, 15).frame(width: 360, height: 38).background(.white.opacity(0.025), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.13), lineWidth: 1)).padding(.top, 14).padding(.bottom, 20)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).padding(.bottom, 8) }
        }
        .onChange(of: model.input) { _, text in
            guard draftBeforeHelperVoice != nil else { return }
            if namingHelper { helperName = text } else { helperInstructions = text }
        }
        .onDisappear { stopHelperVoice() }
    }
    private func helperBubble(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color(white: 0.14))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(LinearGradient(colors: [Color(red: 1, green: 0.89, blue: 0.76), Color(red: 1, green: 0.77, blue: 0.57)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.68, green: 0.46, blue: 0.30), lineWidth: 1))
    }
    private func advanceHelper() {
        stopHelperVoice()
        guard !(namingHelper ? helperName : helperInstructions).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if namingHelper {
            model.addHelper(name: helperName.trimmingCharacters(in: .whitespacesAndNewlines), instructions: helperInstructions)
            model.newConversation(); openChat()
        } else { withAnimation(reduceMotion ? nil : KaddoMotion.content) { namingHelper = true } }
    }
    private func stopHelperVoice() {
        guard let previous = draftBeforeHelperVoice else { return }
        model.stopListening(); draftBeforeHelperVoice = nil; model.input = previous
    }
    private func openChat() { runtime.selectedTab = "Chat"; runtime.showsHome = false; creatingHelper = false }
    private func goHome() { runtime.selectedTab = "Chat"; runtime.showsHome = true; creatingHelper = false }
    private func toggleSidebar() { withAnimation(reduceMotion ? nil : KaddoMotion.content) { sidebarVisible.toggle() } }
}
