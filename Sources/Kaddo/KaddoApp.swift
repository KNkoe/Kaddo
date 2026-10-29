import SwiftUI
import AppKit

@main struct KaddoApp: App {
    @NSApplicationDelegateAdaptor(KaddoDelegate.self) var delegate
    var body: some Scene {
        Settings {
            VStack(spacing: 0) {
                HStack { Button("Open Kaddo notch") { delegate.runtime.show() }; Button("Open workspace window") { delegate.runtime.showWorkspace() }; Spacer() }.padding(.horizontal, 28).padding(.top, 20)
                ConnectionView().environmentObject(delegate.runtime.model)
            }.frame(width: 540)
        }.commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.runtime.showSettings() }.keyboardShortcut(",")
            }
            CommandMenu("Workspace") {
                Button("Previous agent") { delegate.runtime.moveToAgent(-1) }.keyboardShortcut("[", modifiers: [.command, .option])
                Button("Next agent") { delegate.runtime.moveToAgent(1) }.keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                ForEach(Array(["Chat", "Desktop", "Apps", "Agents"].enumerated()), id: \.element) { index, tab in
                    Button(tab) {
                        if tab == "Chat" { delegate.runtime.openConversation() }
                        else { delegate.runtime.showsSettings = false; delegate.runtime.showsHome = false; delegate.runtime.selectedTab = tab; delegate.runtime.show() }
                    }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Open or close conversation") { delegate.runtime.notch?.toggleConversation() }
                    .keyboardShortcut(.space, modifiers: [.command, .shift])
                Button("Open Kaddo notch") { delegate.runtime.show() }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Open workspace window") { delegate.runtime.showWorkspace() }
                Button("Proactive suggestions") { delegate.runtime.proactive?.showPopup() }
                Button("Quick peek") { delegate.runtime.notch?.showPeek() }.keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
            }
        }
        MenuBarExtra("Kaddo", systemImage: "sparkle") { KaddoMenu(runtime: delegate.runtime) }
    }
}
@MainActor final class KaddoDelegate: NSObject, NSApplicationDelegate {
    let runtime = AppRuntime()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory); runtime.start()
        // Settings is a utility scene, never the launch surface of the notch app.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                window.isRestorable = false; window.orderOut(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { runtime.shutdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { runtime.show(); return false }
}
struct KaddoMenu: View {
    @ObservedObject var runtime: AppRuntime
    var body: some View {
        // The Carbon registration owns the global shortcut; a second menu shortcut can reopen a just-closed panel.
        Button("Open Kaddo notch") { runtime.show() }
        Button("New conversation") { runtime.model.newConversation(); runtime.selectedTab = "Chat"; runtime.showsHome = false; runtime.showsSettings = false; runtime.show() }
        Button("Quick peek") { runtime.notch?.showPeek() }
        Button("Proactive suggestions") { runtime.proactive?.showPopup() }
        Button("Background agents") { runtime.showsSettings = false; runtime.selectedTab = "Agents"; runtime.show() }
        Button("Open workspace window") { runtime.showWorkspace() }
        Divider()
        Toggle("Pointer companion", isOn: $runtime.companionEnabled)
        Button("Settings…") { runtime.showSettings() }
        Button("Quit Kaddo") { runtime.shutdown(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
