import AppKit
import Combine
import SwiftUI

/// The small amount of view state shared by the native desktop dock and its controls.
struct AgentDesktopDockState: Equatable {
    var isCollapsed: Bool
    var isHidden = false
    var visibleInRecordings = true

    mutating func toggleCollapsed() { isCollapsed.toggle() }
    mutating func setCollapsed(_ value: Bool) { isCollapsed = value }
    mutating func setHidden(_ value: Bool) { isHidden = value }
    mutating func setVisibleInRecordings(_ value: Bool) { visibleInRecordings = value }
}

struct AgentDesktopDockPresentation: Equatable, Identifiable {
    var helper: HelperProfile
    var job: AgentJob
    var activeJobCount: Int
    var isActive: Bool

    var id: UUID { helper.id }
    var status: AgentJob.State { job.state }
}

/// Converts stored jobs into one portrait per helper, with a short and bounded completion tail.
enum AgentDesktopDockPolicy {
    static let completionLinger: TimeInterval = 7
    static let maximumHelpers = 12

    static func presentations(
        jobs: [AgentJob],
        helpers: [HelperProfile],
        now: Date = Date(),
        hiddenHelperIDs: Set<UUID> = [],
        linger: TimeInterval = AgentDesktopDockPolicy.completionLinger,
        maximumHelpers maximumHelperCount: Int = AgentDesktopDockPolicy.maximumHelpers
    ) -> [AgentDesktopDockPresentation] {
        let profiles = Dictionary(uniqueKeysWithValues: helpers.map { ($0.id, $0) })
        let visibleJobs = jobs.filter { job in
            guard !hiddenHelperIDs.contains(job.helperID) else { return false }
            switch job.state {
            case .running, .queued, .awaitingApproval:
                return true
            case .succeeded, .failed, .cancelled:
                return now.timeIntervalSince(job.finishedAt ?? job.createdAt) <= linger
                    && now.timeIntervalSince(job.finishedAt ?? job.createdAt) >= 0
            case .interrupted:
                return false
            }
        }

        let groups = Dictionary(grouping: visibleJobs, by: \.helperID)
        let rows = groups.compactMap { helperID, group -> (AgentDesktopDockPresentation, Date)? in
            let active = group.filter(isActive)
            let sortedActive = active.sorted(by: activePrecedes)
            let finished = group.filter { !isActive($0) }.sorted(by: finishedPrecedes)
            guard let representative = sortedActive.first ?? finished.first else { return nil }
            let profile = profiles[helperID] ?? HelperProfile(
                id: helperID,
                name: representative.helperName,
                instructions: representative.helperInstructions
            )
            let presentation = AgentDesktopDockPresentation(
                helper: profile,
                job: representative,
                activeJobCount: active.count,
                isActive: !active.isEmpty
            )
            return (presentation, representative.startedAt ?? representative.createdAt)
        }

        return rows.sorted { lhs, rhs in
            if lhs.0.isActive != rhs.0.isActive { return lhs.0.isActive }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.helper.name.localizedCaseInsensitiveCompare(rhs.0.helper.name) == .orderedAscending
        }
        .prefix(max(0, maximumHelperCount))
        .map { $0.0 }
    }

    static func activeJobCount(_ jobs: [AgentJob], hiddenHelperIDs: Set<UUID> = []) -> Int {
        jobs.filter { isActive($0) && !hiddenHelperIDs.contains($0.helperID) }.count
    }

    private static func isActive(_ job: AgentJob) -> Bool {
        switch job.state {
        case .running, .queued, .awaitingApproval: return true
        case .succeeded, .failed, .cancelled, .interrupted: return false
        }
    }

    private static func activePrecedes(_ lhs: AgentJob, _ rhs: AgentJob) -> Bool {
        func rank(_ state: AgentJob.State) -> Int {
            switch state {
            case .running: return 0
            case .awaitingApproval: return 1
            case .queued: return 2
            case .succeeded, .failed, .cancelled, .interrupted: return 3
            }
        }
        if rank(lhs.state) != rank(rhs.state) { return rank(lhs.state) < rank(rhs.state) }
        return lhs.createdAt > rhs.createdAt
    }

    private static func finishedPrecedes(_ lhs: AgentJob, _ rhs: AgentJob) -> Bool {
        (lhs.finishedAt ?? lhs.createdAt) > (rhs.finishedAt ?? rhs.createdAt)
    }
}

enum AgentDesktopDockLayout {
    static let expandedWidth: CGFloat = 64
    static let collapsedWidth: CGFloat = 64
    static let collapsedHeight: CGFloat = 94
    static let maximumHeight: CGFloat = 342
    static let panelInset: CGFloat = 4
    static let headerHeight: CGFloat = 24
    static let cardHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 6

    static func panelSize(isCollapsed: Bool, helperCount: Int, visibleScreenHeight: CGFloat) -> CGSize {
        if isCollapsed {
            return CGSize(width: collapsedWidth, height: min(collapsedHeight, max(1, visibleScreenHeight)))
        }

        let rows = min(max(helperCount, 1), 5)
        let desiredHeight = panelInset * 2 + headerHeight + rowSpacing
            + CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * rowSpacing
        return CGSize(
            width: expandedWidth,
            height: min(maximumHeight, min(max(1, visibleScreenHeight), desiredHeight))
        )
    }

    static func scrollViewportHeight(panelHeight: CGFloat) -> CGFloat {
        max(0, panelHeight - panelInset * 2 - headerHeight - rowSpacing)
    }

    static func frame(screen: CGRect, size: CGSize, margin: CGFloat = 12) -> CGRect {
        let safeWidth = max(0, screen.width - margin * 2)
        let safeHeight = max(0, screen.height - margin * 2)
        let width = min(size.width, safeWidth)
        let height = min(size.height, safeHeight)
        return CGRect(
            x: screen.maxX - margin - width,
            y: screen.midY - height / 2,
            width: width,
            height: height
        )
    }
}

/// A non-activating floating panel that follows the current display and never takes keyboard focus.
@MainActor final class AgentDesktopDockController: ObservableObject {
    let model: AppModel
    let jobs: AgentJobStore
    private let onOpenJob: (UUID) -> Void
    private let panel: AgentDesktopDockPanel
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var expiryTimer: Timer?
    private var hiddenHelperIDs = Set<UUID>()
    private var isStarted = false
    private var isStopped = false

    @Published private(set) var state: AgentDesktopDockState
    @Published private(set) var presentations = [AgentDesktopDockPresentation]()
    @Published private(set) var activeJobCount = 0
    @Published private(set) var panelSize = CGSize(width: AgentDesktopDockLayout.collapsedWidth, height: AgentDesktopDockLayout.collapsedHeight)

    var isCollapsed: Bool { state.isCollapsed }
    var isHidden: Bool { state.isHidden }

    init(model: AppModel, jobs: AgentJobStore, onOpenJob: @escaping (UUID) -> Void) {
        self.model = model
        self.jobs = jobs
        self.onOpenJob = onOpenJob
        self.panel = AgentDesktopDockPanel(
            contentRect: CGRect(x: 0, y: 0, width: AgentDesktopDockLayout.collapsedWidth, height: AgentDesktopDockLayout.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let collapsed = UserDefaults.standard.object(forKey: "agentDesktopDockCollapsed") as? Bool ?? false
        self.state = AgentDesktopDockState(
            isCollapsed: collapsed,
            visibleInRecordings: UserDefaults.standard.object(forKey: "showInScreenRecordings") as? Bool ?? true
        )

        panel.title = "Kaddo agent activity"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.sharingType = state.visibleInRecordings ? .readOnly : .none
        panel.contentView = NSHostingView(rootView: AgentDesktopDockView(controller: self))

        jobs.$jobs.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &cancellables)
        model.$helpers.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &cancellables)
        model.$primaryHelperID.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &cancellables)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Starts observing jobs and shows the panel when visible agent work exists.
    func start() {
        guard !isStopped, !isStarted else { return }
        isStarted = true
        refresh()
    }

    func setSharing(visibleInRecordings: Bool) {
        state.setVisibleInRecordings(visibleInRecordings)
        panel.sharingType = visibleInRecordings ? .readOnly : .none
    }

    func setHiddenHelperIDs(_ ids: Set<UUID>) {
        hiddenHelperIDs = ids
        refresh()
    }

    /// The parent should hide the dock while its workspace already shows these agents.
    func setHidden(_ hidden: Bool) {
        state.setHidden(hidden)
        refresh()
    }

    func setVisible(_ visible: Bool) { setHidden(!visible) }

    func setCollapsed(_ collapsed: Bool) {
        guard state.isCollapsed != collapsed else { return }
        state.setCollapsed(collapsed)
        UserDefaults.standard.set(collapsed, forKey: "agentDesktopDockCollapsed")
        refresh()
    }

    func toggleCollapsed() { setCollapsed(!state.isCollapsed) }

    /// Cancels the actual stored job and its executor; it does not merely dismiss the portrait.
    func stop(_ jobID: UUID) { jobs.cancel(jobID) }

    func open(_ jobID: UUID) { onOpenJob(jobID) }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        cancellables.removeAll()
        panel.orderOut(nil); panel.contentView = nil; panel.close()
    }

    private func refresh(now: Date = Date()) {
        guard !isStopped, isStarted else { return }
        var excludedHelperIDs = hiddenHelperIDs
        if let primaryHelperID = model.primaryHelperID { excludedHelperIDs.insert(primaryHelperID) }
        presentations = AgentDesktopDockPolicy.presentations(
            jobs: jobs.jobs,
            helpers: model.helpers,
            now: now,
            hiddenHelperIDs: excludedHelperIDs
        )
        activeJobCount = AgentDesktopDockPolicy.activeJobCount(jobs.jobs, hiddenHelperIDs: excludedHelperIDs)
        updatePanelFrame()
        if state.isHidden || presentations.isEmpty {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        scheduleExpiry(now: now)
    }

    private func updatePanelFrame() {
        guard let screen = targetScreen() else { return }
        panelSize = AgentDesktopDockLayout.panelSize(
            isCollapsed: state.isCollapsed,
            helperCount: presentations.count,
            visibleScreenHeight: screen.visibleFrame.height
        )
        let frame = AgentDesktopDockLayout.frame(screen: screen.visibleFrame, size: panelSize)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
    }

    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func scheduleExpiry(now: Date) {
        expiryTimer?.invalidate()
        let terminal = jobs.jobs.filter { job in
            switch job.state {
            case .succeeded, .failed, .cancelled: return true
            case .queued, .running, .awaitingApproval, .interrupted: return false
            }
        }
        guard let deadline = terminal.map({ ($0.finishedAt ?? $0.createdAt).addingTimeInterval(AgentDesktopDockPolicy.completionLinger) }).filter({ $0 > now }).min() else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, deadline.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

@MainActor private final class AgentDesktopDockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct AgentDesktopDockView: View {
    @ObservedObject var controller: AgentDesktopDockController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleAgents: [AgentDesktopDockPresentation] {
        controller.isCollapsed ? Array(controller.presentations.prefix(1)) : controller.presentations
    }

    var body: some View {
        VStack(spacing: AgentDesktopDockLayout.rowSpacing) {
            Button(action: controller.toggleCollapsed) {
                Image(systemName: controller.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .frame(width: 48, height: AgentDesktopDockLayout.headerHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isCollapsed ? "Expand agent activity" : "Collapse agent activity")
            .accessibilityLabel(controller.isCollapsed ? "Expand agent activity" : "Collapse agent activity")

            ScrollView(.vertical) {
                VStack(spacing: AgentDesktopDockLayout.rowSpacing) {
                    ForEach(visibleAgents) { presentation in
                        AgentDesktopHead(presentation: presentation) { controller.open(presentation.job.id) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: AgentDesktopDockLayout.scrollViewportHeight(panelHeight: controller.panelSize.height))
        }
        .padding(AgentDesktopDockLayout.panelInset)
        .frame(width: controller.panelSize.width, height: controller.panelSize.height)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84), value: controller.state.isCollapsed)
    }
}

/// A bounded public activity summary; never shows private reasoning or full command output.
enum AgentHeadPreview {
    static func text(for job: AgentJob) -> String {
        let status: String
        switch job.state {
        case .running: status = job.activity?.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text ?? "Working on this task…"
        case .queued: status = "Waiting to start."
        case .awaitingApproval: status = "Waiting for your review."
        case .succeeded: status = "Task finished. Click to see the result."
        case .failed: status = "Needs attention. Click to review."
        case .cancelled: status = "Task stopped."
        case .interrupted: status = "Task interrupted."
        }
        let clean = status.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return clean.count > 140 ? String(clean.prefix(137)) + "…" : clean
    }
}

private struct AgentDesktopHead: View {
    var presentation: AgentDesktopDockPresentation
    var open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var previewHovered = false
    @State private var showsPreview = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            hoverTask?.cancel(); showsPreview = false; open()
        } label: {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || presentation.status != .running)) { timeline in
                let phase = reduceMotion || presentation.status != .running ? 0 : sin(timeline.date.timeIntervalSinceReferenceDate * 1.8 + Double(presentation.helper.characterIdentity.appearance.seed % 31))
                AgentAvatar(profile: presentation.helper, size: 48)
                    .offset(y: phase * 0.8)
                    .rotationEffect(.degrees(phase * 0.8))
                    .scaleEffect(hovered && !reduceMotion ? 1.035 : 1)
                    .frame(width: 56, height: AgentDesktopDockLayout.cardHeight)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(presentation.helper.name)'s task activity")
        .accessibilityHint(AgentHeadPreview.text(for: presentation.job))
        .onHover { inside in
            hovered = inside
            schedulePreview()
        }
        .popover(isPresented: $showsPreview, arrowEdge: .trailing) {
            AgentHeadPreviewView(job: presentation.job)
                .onHover { inside in previewHovered = inside; schedulePreview() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
        .onDisappear { hoverTask?.cancel(); showsPreview = false }
    }

    private func schedulePreview() {
        hoverTask?.cancel()
        let show = hovered || previewHovered
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: show ? 280_000_000 : 160_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            showsPreview = show
        }
    }
}

struct AgentHeadPreviewView: View {
    var job: AgentJob
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(2)
            Text(AgentHeadPreview.text(for: job))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(12).frame(width: 220, alignment: .leading)
        .preferredColorScheme(.dark)
        .allowsHitTesting(true)
    }
}
