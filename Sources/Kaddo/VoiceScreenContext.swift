import AppKit
import ScreenCaptureKit
import Combine

struct VoiceScreenSnapshot: Equatable {
    let text: String
    let imageURL: String?
    let capturedAt: Date

    init(text: String, imageURL: String?, capturedAt: Date = Date()) {
        self.text = String(text.prefix(8_000))
        self.imageURL = imageURL
        self.capturedAt = capturedAt
    }
}

/// In-memory screen context owned by one explicit voice session.
@MainActor final class VoiceScreenContext {
    typealias Capture = () async throws -> VoiceScreenSnapshot
    private(set) var latest: VoiceScreenSnapshot?
    var onUpdate: ((VoiceScreenSnapshot) -> Void)?
    private let capture: Capture
    private let interval: UInt64
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var running = false
    private var capturing = false
    private var workspaceObserver: NSObjectProtocol?
    var allowedAppIDs: Set<String>?
    private var lastExternalApp: NSRunningApplication?

    init(interval: TimeInterval = 4, capture: Capture? = nil) {
        self.interval = UInt64(max(0.01, interval) * 1_000_000_000)
        self.capture = capture ?? { try await Self.captureVisibleScreen() }
    }

    func start() {
        guard !running else { return }
        running = true
        generation = UUID()
        rememberExternalApp(NSWorkspace.shared.frontmostApplication)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.rememberExternalApp(app) }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.running else { return }
                _ = await self.refresh()
                do { try await Task.sleep(nanoseconds: self.interval) } catch { return }
            }
        }
    }

    func stop() {
        running = false
        generation = UUID()
        loop?.cancel(); loop = nil
        latest = nil
        lastExternalApp = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }

    @discardableResult func refresh() async -> VoiceScreenSnapshot? {
        guard running, !capturing else { return nil }
        capturing = true
        let token = generation
        let app = lastExternalApp
        let snapshot: VoiceScreenSnapshot
        do {
            let result = try await capture()
            // The native capture supplies window/app metadata. Keep the last
            // external application useful even when Kaddo owns keyboard focus.
            if let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                snapshot = VoiceScreenSnapshot(text: "Last active external app: \(app.localizedName ?? "Unknown")\n" + result.text, imageURL: result.imageURL, capturedAt: result.capturedAt)
            } else { snapshot = result }
        } catch {
            snapshot = VoiceScreenSnapshot(text: "Screen context unavailable: \(error.localizedDescription)", imageURL: nil)
        }
        capturing = false
        guard running, generation == token else { return nil }
        latest = snapshot
        onUpdate?(snapshot)
        return snapshot
    }

    private func rememberExternalApp(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApp = app
    }

    /// A one-shot local OCR context for proactive discovery. No screenshot is retained or sent.
    static func proactiveText(preferredApp: NSRunningApplication? = nil, selectedApp: NSRunningApplication? = nil) async -> String {
        let excluded: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.systempreferences", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop"]
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, excluded.contains(front) {
            return "Screen context unavailable: the current app is excluded from screen context."
        }
        let front = NSWorkspace.shared.frontmostApplication
        let target = selectedApp ?? (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? preferredApp : front)
        guard let target, !target.isTerminated, !excluded.contains(target.bundleIdentifier ?? "") else {
            return "Screen context unavailable: no active external app is available."
        }
        do {
            let snapshot = try await captureVisibleScreen(excludedBundleIDs: excluded, maximumDimension: 2880, preferredPID: target.processIdentifier, includeOffscreenWindow: selectedApp != nil)
            try Task.checkCancellation()
            // Omit the capture timestamp so unchanged screens do not cause new discovery calls.
            let parts = snapshot.text.components(separatedBy: "Screen text:\n")
            let recognized = parts.count > 1 ? parts.dropFirst().joined(separator: "Screen text:\n") : ""
            guard !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !recognized.hasPrefix("Local OCR unavailable") else {
                throw ScreenContextError.unavailable(recognized.hasPrefix("Local OCR unavailable") ? String(recognized.prefix(240)) : "No readable text was found in the selected app window.")
            }
            let windows = parts[0].components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            return "Screen text:\nApp: \(target.localizedName ?? "Active app")\n" + String(recognized.prefix(1800)) + "\n" + String(windows.prefix(800))
        } catch {
            let captureError = error.localizedDescription
            // Read only the resolved source app when pixel capture is unavailable.
            // Automatic following needs the same bounded fallback as pinned sources.
            if !target.isTerminated, CGPreflightScreenCaptureAccess(), !Task.isCancelled {
                do {
                    let text = try await DesktopController.focusedAccessibilityTextBounded(pid: target.processIdentifier)
                    try Task.checkCancellation()
                    return "Accessibility text:\nApp: \(target.localizedName ?? "Selected app")\n" + String(text.prefix(1800))
                } catch {
                    return "Screen context unavailable: \(target.localizedName ?? "Selected app"): " + String(captureError.prefix(140)) + "; " + String(error.localizedDescription.prefix(140))
                }
            }
            return "Screen context unavailable: \(target.localizedName ?? "Selected app"): " + String(captureError.prefix(240))
        }
    }

    private static func captureVisibleScreen(excludedBundleIDs: Set<String> = [], maximumDimension: Int = 1440, preferredPID: pid_t? = nil, includeOffscreenWindow: Bool = false) async throws -> VoiceScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenContextError.unavailable("Screen Recording permission is not granted. Enable it in macOS settings to share your screen during voice.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: !includeOffscreenWindow)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw ScreenContextError.unavailable("No visible display is available.")
        }
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier || excludedBundleIDs.contains($0.bundleIdentifier) }
        var preferredWindow: SCWindow?
        var preferredFrame: CGRect?
        if let preferredPID {
            let rows = CGWindowListCopyWindowInfo(includeOffscreenWindow ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == preferredPID && $0.windowLayer == 0 &&
                (includeOffscreenWindow || $0.isOnScreen) && $0.frame.width > 1 && $0.frame.height > 1
            }
            let selected = proactiveWindow(pid: preferredPID, windows: rows, availableIDs: Set(content.windows.map(\.windowID)))
                ?? singleAppWindow(candidates.map { (id: $0.windowID, frame: $0.frame) })
            guard let selected, let window = candidates.first(where: { $0.windowID == selected.id }) else {
                throw ScreenContextError.unavailable("The selected app has no unambiguous capturable window (\(candidates.count) capture candidates). Bring its main window forward.")
            }
            preferredWindow = window; preferredFrame = selected.frame
        }
        let filter = preferredWindow.map { SCContentFilter(desktopIndependentWindow: $0) }
            ?? SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let dimensions = fittedSize(width: preferredFrame.map { Int($0.width * 2) } ?? display.width,
                                    height: preferredFrame.map { Int($0.height * 2) } ?? display.height, maximumDimension: maximumDimension)
        let config = SCStreamConfiguration()
        config.width = dimensions.width; config.height = dimensions.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65])
        let ocr: String
        do { ocr = try await DesktopController.recognizeTextBounded(in: image, timeout: 3) }
        catch { ocr = "Local OCR unavailable: \(error.localizedDescription)" }
        let externalWindows = preferredWindow.map { [$0] } ?? content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && !excludedBundleIDs.contains($0.owningApplication?.bundleIdentifier ?? "") && $0.windowLayer == 0 && $0.frame.intersects(display.frame) }
        let windows = externalWindows.prefix(12).map { "\($0.owningApplication?.applicationName ?? "Unknown app"): \(($0.title ?? "Untitled").prefix(180))" }.joined(separator: "\n")
        let date = Date()
        let source = preferredWindow.map { "Selected app window \($0.windowID)" } ?? "Current visible display \(display.displayID)"
        let text = "\(source), captured \(ISO8601DateFormatter().string(from: date)). Kaddo is excluded.\nVisible windows (not necessarily focused):\n\(windows)\nScreen text:\n\(ocr)"
        return VoiceScreenSnapshot(text: text, imageURL: jpeg.map { "data:image/jpeg;base64," + $0.base64EncodedString() }, capturedAt: date)
    }

    /// CGWindowList is ordered front-to-back. Select only a visible window owned
    /// by the chosen app; never silently substitute another display or app.
    static func proactiveWindow(pid: pid_t, windows: [[String: Any]], availableIDs: Set<UInt32>) -> (id: UInt32, frame: CGRect)? {
        for row in windows {
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, availableIDs.contains(id),
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1 else { continue }
            return (id, frame)
        }
        return nil
    }

    /// ScreenCaptureKit can identify a single app window even when CGWindowList
    /// omits its row. Never choose a different app or guess between its windows.
    static func singleAppWindow(_ candidates: [(id: UInt32, frame: CGRect)]) -> (id: UInt32, frame: CGRect)? {
        candidates.count == 1 ? candidates[0] : nil
    }

    static func fittedSize(width: Int, height: Int, maximumDimension: Int = 1440) -> (width: Int, height: Int) {
        let scale = min(1, Double(max(1, maximumDimension)) / Double(max(1, max(width, height))))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }
}

/// Keeps the source app stable while Kaddo's own review/settings UI has focus.
@MainActor final class ProactiveScreenSource: ObservableObject {
    private let defaults: UserDefaults
    @Published var selectedAppID: String {
        didSet { if persistsSelection { defaults.set(selectedAppID, forKey: "proactiveScreenSourceApp") } }
    }
    var persistsSelection = true
    @Published private(set) var applications: [(id: String, name: String)] = []
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedAppID = defaults.string(forKey: "proactiveScreenSourceApp") ?? ""
        refreshApplications()
    }
    func refreshApplications() {
        let excluded: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.systempreferences", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop"]
        var seen = Set<String>()
        applications = NSWorkspace.shared.runningApplications.compactMap { app -> (id: String, name: String)? in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = app.bundleIdentifier, !excluded.contains(id), seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? id)
        }.sorted { $0.name < $1.name }
    }
    var sourceOptions: [(String, String)] {
        [("", "Follow the active app")] + applications.map { ($0.id, $0.name) } +
        (!selectedAppID.isEmpty && !applications.contains(where: { $0.id == selectedAppID }) ? [(selectedAppID, "Selected app is not running")] : [])
    }

    var allowedAppIDs: Set<String>?
    private var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?
    func start() {
        guard observer == nil else { return }
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.remember(app) }
        }
    }
    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApp = app
    }
    func text() async -> String {
        if let allowedAppIDs {
            let front = NSWorkspace.shared.frontmostApplication
            let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : front
            let id = selectedAppID.isEmpty ? target?.bundleIdentifier : selectedAppID
            guard let id, allowedAppIDs.contains(id) else {
                return "Screen context unavailable: QA mode only reads TextEdit, Aside, and Finder (current source: \(id ?? "none"))."
            }
        }
        if !selectedAppID.isEmpty {
            guard let selected = NSRunningApplication.runningApplications(withBundleIdentifier: selectedAppID).first(where: { !$0.isTerminated }) else {
                return "Screen context unavailable: the selected app is not running. Choose an open app or follow the active app."
            }
            return await VoiceScreenContext.proactiveText(preferredApp: lastExternalApp, selectedApp: selected)
        }
        return await VoiceScreenContext.proactiveText(preferredApp: lastExternalApp)
    }
    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil; lastExternalApp = nil
    }
}

private enum ScreenContextError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case let .unavailable(message): return message } }
}
