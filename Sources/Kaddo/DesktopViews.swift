import SwiftUI
import AppKit

/// A suggested action is bound to the exact target captured for its plan.
/// Rechecking the selected bundle alone is not enough: the app can switch
/// windows or the focused control while the planner is still responding.
struct DesktopPlanningRequest: Equatable {
    let id: UUID
    let targetID: String
    let target: DesktopTargetIdentity
    let goal: String

    func isCurrent(generation: UUID, selectedTargetID: String, identity: DesktopTargetIdentity?) -> Bool {
        id == generation && targetID == selectedTargetID && identity == target
    }

    func matches(_ approval: DesktopApproval) -> Bool {
        approval.pid == target.pid && approval.appID == target.appID && approval.windowTitle == target.title &&
            approval.windowID == target.windowID && approval.windowFrame == target.frame && approval.focusedElement == target.focus && approval.focusIdentity == target.focusIdentity
    }
}

/// Standard controls and shallow sections keep the pane usable by macOS Accessibility clients.
struct DesktopToolsView: View {
    @ObservedObject var controller: DesktopController
    var onAttach: (ScreenSnapshot) -> Void
    var planner: ((String, ScreenSnapshot) async throws -> [DesktopAction])? = nil
    @State private var pane = "Screen"
    @State private var goal = ""
    @State private var planning = false
    @State private var planningGeneration = UUID()
    @State private var planError: String?
    @State private var proposed: [DesktopAction] = []
    @State private var proposedRequest: DesktopPlanningRequest?
    @State private var kind: DesktopAction.Kind = .click
    @State private var x = "100"
    @State private var y = "100"
    @State private var value = ""
    @State private var scroll = "-3"
    private var targetName: String { controller.targetApplications.first(where: { $0.bundleIdentifier == controller.selectedTargetID })?.localizedName ?? "Choose a target app" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Desktop").font(.title2.bold())
                Spacer()
                ForEach(["Screen", "Actions", "History"], id: \.self) { tab in
                    Button(tab) { pane = tab }.buttonStyle(KaddoButtonStyle(prominent: pane == tab))
                }
            }
            HStack(spacing: 12) {
                KaddoMenuPicker(title: "Target application", selection: $controller.selectedTargetID,
                    options: [("", "Choose a target app")] + controller.targetApplications.map { ($0.bundleIdentifier ?? "", $0.localizedName ?? "Application") }).frame(maxWidth: 280)
                Button("Refresh apps") { controller.refreshTargets() }
                Spacer()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if pane == "Screen" { screenPane }
                    else if pane == "Actions" { actionsPane }
                    else { historyPane }
                    if let error = controller.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }.buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: controller.selectedTargetID) { _, _ in invalidatePlan(clearError: true); controller.cancelPending() }
            .onChange(of: goal) { _, _ in
                if planning || proposedRequest != nil { invalidatePlan(clearError: true); controller.cancelPending() }
            }
            .onChange(of: [x, y, value, scroll]) { _, _ in controller.cancelPending() }
            .onAppear { controller.refreshPermissions() }
            .onDisappear { invalidatePlan(clearError: true); controller.cancelPending() }
    }

    private func invalidatePlan(clearError: Bool) {
        planningGeneration = UUID()
        planning = false
        proposed = []
        proposedRequest = nil
        if clearError { planError = nil }
    }
    private var screenPane: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Screen awareness").font(.headline)
            Text("Capture the chosen window, review it, then attach it to your next message. Text recognition stays on this Mac.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(controller.screenAllowed ? "Screen Recording: allowed" : "Screen Recording: not granted")
                Spacer()
                if !controller.screenAllowed { Button("Enable Screen Recording") { controller.requestScreenPermission() } }
            }
            HStack {
                Text(controller.accessibilityAllowed ? "Accessibility: allowed" : "Accessibility: not granted")
                Spacer()
                if !controller.accessibilityAllowed { Button("Enable Accessibility") { controller.requestAccessibilityPermission() } }
            }
            HStack {
                Button("Refresh permissions") { controller.refreshPermissions() }
                Button("Open Privacy settings") { controller.openPrivacySettings() }
            }
            Text("macOS may require you to quit and reopen Kaddo after granting access. Desktop captures run when you choose; active voice also refreshes screen context automatically.").font(.caption).foregroundStyle(.secondary)
            Button(controller.busy ? "Capturing window…" : "Capture selected window") { Task { await controller.capture() } }.buttonStyle(KaddoButtonStyle(prominent: true)).disabled(controller.busy || controller.selectedTargetID.isEmpty)
            if controller.busy { ProgressView().controlSize(.small) }
            if let snapshot = controller.snapshot {
                Divider()
                Text(snapshot.appName + " · " + snapshot.windowTitle).font(.headline)
                Text(snapshot.capturedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                if let warning = snapshot.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if let path = snapshot.imagePath, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel("Captured window preview") }
                Text(snapshot.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(18)
                HStack {
                    Button("Add screen context to chat") { onAttach(snapshot) }.buttonStyle(KaddoButtonStyle(prominent: true))
                    Button("Copy screen text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snapshot.chatContext, forType: .string) }
                }
                Text("The image and displayed text go to your selected AI only when you send the attached message.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var actionsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Desktop actions").font(.headline)
            Text("Kaddo shows a concrete action and its target before applying it. Review one step at a time.").foregroundStyle(.secondary)
            if let planner {
                TextField("What should Kaddo do in the selected app?", text: $goal, axis: .vertical).lineLimit(2...4).textFieldStyle(KaddoTextFieldStyle())
                Text("Planning sends the captured window and goal to your configured AI. Applying any action still needs your approval.").font(.caption).foregroundStyle(.secondary)
                Button(planning ? "Planning next action…" : "Capture and plan next action") {
                    let requestID = UUID()
                    let requestedTargetID = controller.selectedTargetID
                    let requestedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                    planningGeneration = requestID
                    Task {
                        planning = true; planError = nil; proposed = []; proposedRequest = nil; controller.cancelPending()
                        defer { if planningGeneration == requestID { planning = false } }
                        await controller.capture()
                        guard planningGeneration == requestID else { return }
                        guard controller.selectedTargetID == requestedTargetID else {
                            planError = "The target application changed. Capture and plan again."
                            return
                        }
                        guard let snapshot = controller.snapshot else { planError = controller.error ?? "Capture a window first."; return }
                        guard let identity = controller.capturedTargetIdentity, identity.appID == requestedTargetID,
                              controller.targetIdentity() == identity else {
                            planError = "The captured window or focused control changed. Capture and plan again."
                            return
                        }
                        let request = DesktopPlanningRequest(id: requestID, targetID: requestedTargetID, target: identity, goal: requestedGoal)
                        do {
                            let actions = try await planner(requestedGoal, snapshot)
                            guard request.isCurrent(generation: planningGeneration, selectedTargetID: controller.selectedTargetID, identity: controller.targetIdentity()),
                                  controller.capturedTargetIdentity == identity else {
                                if planningGeneration == requestID { planError = "The target changed while planning. Capture and plan again." }
                                return
                            }
                            proposed = actions
                            proposedRequest = request
                            if actions.isEmpty { planError = "No safe action was proposed. Add more detail or use a manual action." }
                        } catch {
                            if planningGeneration == requestID { planError = error.localizedDescription }
                        }
                    }
                }.disabled(planning || controller.busy || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let planError { Text(planError).font(.caption).foregroundStyle(.orange) }
                if let next = proposed.first {
                    Text("Suggested: " + next.approvalSummary).font(.callout)
                    Button("Review suggested action") { reviewSuggestedAction(next) }
                }
                Divider()
            }
            HStack {
                Text("Manual action")
                KaddoMenuPicker(title: "Manual action", selection: $kind,
                    options: DesktopAction.Kind.allCases.map { ($0, $0.rawValue) }).frame(width: 190)
                    .onChange(of: kind) { _, _ in controller.cancelPending() }
                Spacer()
            }
            if kind == .click || kind == .scroll {
                HStack { TextField("Screen X", text: $x); TextField("Screen Y", text: $y) }.textFieldStyle(KaddoTextFieldStyle())
                Text("Absolute screen points with origin at the top left. Preview must be inside the selected window.").font(.caption).foregroundStyle(.secondary)
            }
            if kind == .scroll { TextField("Lines: -3 down, +3 up", text: $scroll).textFieldStyle(KaddoTextFieldStyle()) }
            if kind == .typeText { TextField("Text to type", text: $value, axis: .vertical).lineLimit(2...5).textFieldStyle(KaddoTextFieldStyle()) }
            if kind == .key { TextField("Key: return, tab, escape, space, delete, left, right, up, down", text: $value).textFieldStyle(KaddoTextFieldStyle()) }
            if kind == .openApp { TextField("Application bundle ID, e.g. com.apple.TextEdit", text: $value).textFieldStyle(KaddoTextFieldStyle()) }
            Button("Review manual action") { controller.prepare(DesktopAction(type: kind, x: Double(x), y: Double(y), text: kind == .typeText ? value : nil, key: kind == .key ? value : nil, appID: kind == .openApp ? value : nil, scrollDelta: Int(scroll))) }
            if let pending = controller.pending {
                Divider()
                Text("Review this exact action").font(.headline).foregroundStyle(.orange)
                Text(pending.action.approvalSummary).textSelection(.enabled)
                if let payload = pending.action.approvalPayload {
                    ScrollView(.vertical) {
                        Text(payload)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(nil)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 150)
                    .padding(9)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
                    .accessibilityLabel("Full text to type, \(payload.count) characters")
                }
                Text("Target: \(pending.appName) · \(pending.windowTitle)").font(.caption)
                Text("Focused control: \(pending.focusedElement)").font(.caption)
                HStack {
                    Button("Approve this action") {
                        Task {
                            await controller.executeApproved(id: pending.id)
                            if controller.error == nil {
                                if proposed.first == pending.action { proposed.removeFirst() }
                                if pending.action.type == .openApp, let id = pending.action.appID { controller.refreshTargets(); controller.selectedTargetID = id }
                                await controller.capture()
                            }
                        }
                    }.buttonStyle(KaddoButtonStyle(prominent: true))
                    Button("Cancel action") { controller.cancelPending() }
                }
            }
        }
    }

    private func reviewSuggestedAction(_ action: DesktopAction) {
        guard let request = proposedRequest,
              request.isCurrent(generation: planningGeneration, selectedTargetID: controller.selectedTargetID, identity: controller.targetIdentity()),
              controller.capturedTargetIdentity == request.target else {
            controller.cancelPending()
            planError = "The target window or focused control changed. Capture and plan again."
            proposed = []
            proposedRequest = nil
            return
        }
        controller.prepare(action)
        if let pending = controller.pending, !request.matches(pending) {
            controller.cancelPending()
            planError = "The approval target differs from the captured plan. Capture and plan again."
            proposed = []
            proposedRequest = nil
        }
    }
    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Action history").font(.headline)
            if controller.audit.isEmpty { Text("No desktop actions applied yet.").foregroundStyle(.secondary) }
            ForEach(controller.audit) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.action).font(.headline)
                    Text(entry.target).font(.caption).foregroundStyle(.secondary)
                    Text(entry.result).font(.caption)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
            }
        }
    }
}
