import AppKit
import Combine
import ApplicationServices
import ScreenCaptureKit
import Vision

struct ScreenSnapshot: Codable, Equatable {
    var text: String
    var appName: String
    var windowTitle: String
    var capturedAt: Date
    var imagePath: String?
    var warning: String?

    var chatContext: String {
        "Screen context captured at \(capturedAt.formatted(date: .abbreviated, time: .standard))\nApp: \(appName)\nWindow: \(windowTitle)\n\(warning.map { "Capture warning: \($0)\n" } ?? "")\n\(text)"
    }
}

struct DesktopAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case click, typeText, key, scroll, openApp }
    var type: Kind
    var x: Double? = nil
    var y: Double? = nil
    var text: String? = nil
    var key: String? = nil
    var appID: String? = nil
    var scrollDelta: Int? = nil
    /// Short line suitable for the approval header. Typing content is shown
    /// separately and in full so the preview cannot hide the executed tail.
    var approvalSummary: String {
        if type == .typeText { return "Type exactly \(text?.count ?? 0) characters" }
        return preview
    }
    var approvalPayload: String? { type == .typeText ? text : nil }
    var preview: String {
        switch type {
        case .click: return "Click screen coordinate (\(x.map { String(format: "%.0f", $0) } ?? "?"), \(y.map { String(format: "%.0f", $0) } ?? "?"))"
        case .typeText: return "Type \(text?.count ?? 0) characters: \(String((text ?? "").prefix(160)))"
        case .key: return "Press \(key ?? "?")"
        case .scroll: return "Scroll \((scrollDelta ?? 0) < 0 ? "down" : "up") \((scrollDelta ?? 0).magnitude) lines at (\(x ?? 0), \(y ?? 0))"
        case .openApp: return "Open application \(appID ?? "?")"
        }
    }
    func validate(in bounds: [CGRect]) throws {
        switch type {
        case .click, .scroll:
            guard let x, let y, x.isFinite, y.isFinite, bounds.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) else { throw DesktopError.invalid("Coordinates must be inside a connected display.") }
            if type == .scroll, !(scrollDelta.map { $0 != 0 && abs(Double($0)) <= 100 } ?? false) { throw DesktopError.invalid("Scroll must be between -100 and 100 lines, excluding zero.") }
        case .typeText:
            guard let text, !text.isEmpty, text.count <= 10_000, !text.contains("\0") else { throw DesktopError.invalid("Enter 1–10,000 characters without null bytes.") }
        case .key:
            guard Self.keyCodes[key?.lowercased() ?? ""] != nil else { throw DesktopError.invalid("Supported keys: return, tab, escape, space, delete, left, right, up, down.") }
        case .openApp:
            guard let appID, appID.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { throw DesktopError.invalid("Enter a valid application bundle identifier.") }
        }
    }
    static let keyCodes: [String: CGKeyCode] = ["return":36, "tab":48, "escape":53, "space":49, "delete":51, "left":123, "right":124, "down":125, "up":126]
    static func typingChunks(_ text: String, maximumUnits: Int = 20) -> [[UniChar]] {
        let units = Array(text.utf16), limit = max(2, maximumUnits)
        var chunks = [[UniChar]](), start = 0
        while start < units.count {
            var end = min(start + limit, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]), (0xDC00...0xDFFF).contains(units[end]) { end -= 1 }
            chunks.append(Array(units[start..<end])); start = end
        }
        return chunks
    }
    func scrollEvents(source: CGEventSource?) throws -> [CGEvent] {
        guard type == .scroll, let x, let y, x.isFinite, y.isFinite,
              let scrollDelta, scrollDelta != 0, abs(Double(scrollDelta)) <= 100 else { throw DesktopError.invalid("Invalid scroll event.") }
        let point = CGPoint(x: x, y: y)
        // macOS routes wheel input using the actual cursor hit target. Setting
        // only the wheel event's location can leave it over Kaddo's review UI.
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let wheel = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: Int32(scrollDelta), wheel2: 0, wheel3: 0) else { throw DesktopError.invalid("Could not create scroll events.") }
        wheel.location = point
        return [move, wheel]
    }
}

enum DesktopError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

struct DesktopApproval: Identifiable {
    let id = UUID()
    let action: DesktopAction
    let appName: String
    let appID: String
    let pid: pid_t
    let windowTitle: String
    let focusedElement: String
    let windowID: UInt32?
    let windowFrame: CGRect?
    var focusIdentity: DesktopFocusIdentity? = nil
    let createdAt = Date()
}
struct DesktopFocusIdentity: Equatable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    static func matches(_ reviewed: Self?, _ current: Self?) -> Bool {
        guard let reviewed, let current else { return false }
        return reviewed == current
    }
}
struct DesktopTargetIdentity: Equatable {
    let pid: pid_t
    let appID: String
    let title: String
    let windowID: UInt32?
    let frame: CGRect?
    let focus: String
    var focusIdentity: DesktopFocusIdentity? = nil
}
struct DesktopAudit: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let action: String
    let target: String
    let result: String
}

private final class OCRResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func finish(_ result: Result<String, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

@MainActor final class DesktopController: ObservableObject {
    @Published var selectedTargetID = ""
    @Published private(set) var targetApplications: [NSRunningApplication] = []
    @Published private(set) var snapshot: ScreenSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var screenAllowed = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var pending: DesktopApproval?
    @Published private(set) var audit: [DesktopAudit] = []
    private var ocrFailure: String?
    private(set) var capturedTargetIdentity: DesktopTargetIdentity?

    init() { refreshPermissions(); refreshTargets() }
    func refreshTargets() {
        var seen = Set<String>()
        targetApplications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleIdentifier != nil && seen.insert($0.bundleIdentifier!).inserted
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if !targetApplications.contains(where: { $0.bundleIdentifier == selectedTargetID }) {
            selectedTargetID = targetApplications.first(where: { $0.isActive })?.bundleIdentifier ?? targetApplications.first?.bundleIdentifier ?? ""
        }
    }
    private var selectedTarget: NSRunningApplication? { targetApplications.first { $0.bundleIdentifier == selectedTargetID && !$0.isTerminated } }
    func targetIdentity() -> DesktopTargetIdentity? {
        guard let app = selectedTarget else { return nil }
        let pid = app.processIdentifier, title = windowTitle(app.processIdentifier)
        return DesktopTargetIdentity(pid: pid, appID: selectedTargetID, title: title, windowID: windowID(pid, title: title), frame: windowBounds(pid), focus: focusDescription(pid), focusIdentity: focusedElement(pid).map { DesktopFocusIdentity(element: $0) })
    }
    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess(), accessibility = AXIsProcessTrusted()
        if screenAllowed != screen { screenAllowed = screen }
        if accessibilityAllowed != accessibility { accessibilityAllowed = accessibility }
    }
    func requestScreenPermission() { _ = CGRequestScreenCaptureAccess(); refreshPermissions() }
    func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        refreshPermissions()
    }
    func openControlSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
    private func windowID(_ pid: pid_t, title: String) -> UInt32? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let matches = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowName as String] as? String) == title || title == "Unknown window") }
        guard matches.count == 1 else { return nil }
        return matches[0][kCGWindowNumber as String] as? UInt32
    }
    private func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = attribute(app, kAXFocusedWindowAttribute as CFString), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func restoreTarget(_ app: NSRunningApplication) async throws {
        NSApp.yieldActivation(to: app)
        guard app.activate(from: .current, options: [.activateAllWindows]) else { throw DesktopError.invalid("Could not activate the selected application.") }
        if accessibilityAllowed, let window = focusedWindow(app.processIdentifier) {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DesktopError.invalid("The selected application did not become active. Activate its intended window and try again.")
    }
    private func windowBounds(_ pid: pid_t) -> CGRect? {
        guard let window = focusedWindow(pid), let position = attribute(window, kAXPositionAttribute as CFString), let size = attribute(window, kAXSizeAttribute as CFString), CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private func validateTargetPoint(_ action: DesktopAction, pid: pid_t) throws {
        if action.type == .click || action.type == .scroll {
            guard let x = action.x, let y = action.y, let bounds = windowBounds(pid), bounds.contains(CGPoint(x: x, y: y)) else { throw DesktopError.invalid("Point is outside the selected app's focused window, or its window bounds are unavailable. Grant Accessibility permission and preview again.") }
        }
    }
    private func validateHitTarget(_ action: DesktopAction, pid: pid_t) throws {
        guard action.type == .click || action.type == .scroll else { return }
        guard let x = action.x, let y = action.y, let expectedWindow = focusedWindow(pid) else {
            throw DesktopError.invalid("The input target could not be identified. No event was sent.")
        }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(y), &element) == .success,
              let element else { throw DesktopError.invalid("The actual pointer target could not be verified. No event was sent.") }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(element, &hitPID) == .success, hitPID == pid else {
            throw DesktopError.invalid("Another app covers the approved point. No event was sent.")
        }
        let hitWindow: AXUIElement?
        if (attribute(element, kAXRoleAttribute as CFString) as? String) == kAXWindowRole {
            hitWindow = element
        } else if let value = attribute(element, kAXWindowAttribute as CFString), CFGetTypeID(value) == AXUIElementGetTypeID() {
            hitWindow = (value as! AXUIElement)
        } else { hitWindow = nil }
        guard let hitWindow, CFEqual(hitWindow, expectedWindow) else {
            throw DesktopError.invalid("The point is covered by a different window. No event was sent.")
        }
    }
    private func windowTitle(_ pid: pid_t) -> String {
        focusedWindow(pid).flatMap { attribute($0, kAXTitleAttribute as CFString) as? String } ?? "Unknown window"
    }
    private func focusedElement(_ pid: pid_t) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func focusDescription(_ pid: pid_t) -> String {
        guard let element = focusedElement(pid) else { return "Focused element unavailable" }
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? "Unknown element"
        let label = attribute(element, kAXTitleAttribute as CFString) as? String ?? attribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute as CFString) as? String ?? ""
        return "\(role) \(subrole) \(label)"
    }
    /// Read only the selected app's focused document. Work and IPC are bounded;
    /// secure fields are omitted and no screenshot or keystroke is involved.
    nonisolated static func focusedAccessibilityTextBounded(pid: pid_t, timeout: Double = 3) async throws -> String {
        guard AXIsProcessTrusted() else { throw DesktopError.invalid("Accessibility permission is not granted.") }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = OCRResultGate(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(timeout)
                func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                    guard Date() < deadline else { return nil }
                    AXUIElementSetMessagingTimeout(element, 0.15)
                    var value: CFTypeRef?
                    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
                }
                func element(_ value: CFTypeRef?) -> AXUIElement? {
                    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                    return (value as! AXUIElement)
                }
                let app = AXUIElementCreateApplication(pid)
                guard let window = element(attribute(app, kAXFocusedWindowAttribute)) else {
                    gate.finish(.failure(DesktopError.invalid("The selected app has no accessible focused window."))); return
                }
                var root = window
                if let focused = element(attribute(app, kAXFocusedUIElementAttribute)),
                   attribute(focused, kAXRoleAttribute) as? String == "AXWebArea" { root = focused }
                var pieces: [String] = [], visited = 0, characters = 0
                func walk(_ node: AXUIElement, depth: Int) {
                    guard Date() < deadline, depth < 16, visited < 600, characters < 8000 else { return }
                    visited += 1
                    guard attribute(node, kAXSubroleAttribute) as? String != "AXSecureTextField" else { return }
                    for field in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                        if let value = attribute(node, field) as? String, !value.isEmpty, pieces.last != value {
                            let text = String(value.prefix(min(2000, 8000 - characters)))
                            pieces.append(text); characters += text.count
                        }
                    }
                    if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                        for child in children where Date() < deadline { walk(child, depth: depth + 1) }
                    }
                }
                walk(root, depth: 0)
                let text = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { gate.finish(.failure(DesktopError.invalid("The selected app exposes no readable document text."))) }
                else { gate.finish(.success(text)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 0.2) {
                gate.finish(.failure(DesktopError.invalid("Reading the selected app's Accessibility text timed out.")))
            }
        }
    }

    nonisolated static func orderedOCRText(_ observations: [VNRecognizedTextObservation]) -> String {
        observations.sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.015 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    nonisolated static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast; request.usesLanguageCorrection = true
        // The accurate backend can stall on this host. Fast CPU recognition is
        // local, bounded, and verified against real window text.
        request.usesCPUOnly = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return orderedOCRText(request.results ?? [])
    }
    nonisolated static func recognizeTextBounded(in image: CGImage, timeout: Double = 8) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OCRResultGate(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                do { gate.finish(.success(try recognizeText(in: image))) }
                catch { gate.finish(.failure(error)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.finish(.failure(DesktopError.invalid("Local OCR timed out. Screenshot retained; Accessibility text used when available.")))
            }
        }
    }
    func capture(forAgent: Bool = false) async {
        guard !busy else { return }
        refreshPermissions(); error = nil; snapshot = nil; capturedTargetIdentity = nil; busy = true
        defer { busy = false }
        guard let app = selectedTarget else { error = "Choose an application to capture."; return }
        let pid = app.processIdentifier
        // Stage Manager reports the sidebar thumbnail's frame until the selected
        // app is restored. Bring that app forward before binding AX and SC windows.
        do { try await restoreTarget(app); try await Task.sleep(nanoseconds: 350_000_000) }
        catch { self.error = error.localizedDescription; return }
        capturedTargetIdentity = targetIdentity()
        if forAgent, capturedTargetIdentity?.focus.contains("AXSecureTextField") != false { error = "Secure or unavailable target focus. Ask the human to leave the secure field first."; return }
        var title = windowTitle(pid), text = "", imagePath: String?, warning: String?
        if accessibilityAllowed {
            do { text = try await Self.focusedAccessibilityTextBounded(pid: pid) }
            catch { warning = "Accessibility text unavailable: \(error.localizedDescription) Screenshot capture will still be attempted." }
        }
        if let bounds = windowBounds(pid) {
            text = "Window frame in absolute screen points (top-left origin): x=\(bounds.minX), y=\(bounds.minY), width=\(bounds.width), height=\(bounds.height). Screenshot pixels use 2 pixels per point.\n" + text
        }
        do {
            guard screenAllowed else { throw DesktopError.invalid("Screen Recording permission has not been granted.") }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            let window: SCWindow
            if accessibilityAllowed {
                guard let bounds = windowBounds(pid), title != "Unknown window" else { throw DesktopError.invalid("The selected app's focused window could not be identified. Activate its intended window and capture again.") }
                let identity = windowID(pid, title: title)
                let matches = candidates.filter { Self.captureWindowMatches(title: $0.title ?? "", frame: $0.frame, expectedTitle: title, expectedFrame: bounds, windowID: $0.windowID, expectedWindowID: identity) }
                guard matches.count == 1, let matched = matches.first else { throw DesktopError.invalid("The screenshot could not be bound to the exact focused window. Activate its intended window and try again. Accessibility text retained without a mismatched image.") }
                window = matched
            } else {
                guard let id = windowID(pid, title: title), let matched = candidates.first(where: { $0.windowID == id }) else { throw DesktopError.invalid("No unambiguous visible window was found. Activate the target window and try again.") }
                window = matched
                text = "Screenshot-only context. Accessibility text and precise control coordinates are unavailable."
            }
            title = window.title ?? title
            let captureSize = accessibilityAllowed ? (windowBounds(pid)?.size ?? window.frame.size) : window.frame.size
            let config = SCStreamConfiguration(); config.width = max(1, Int(captureSize.width * 2)); config.height = max(1, Int(captureSize.height * 2)); config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kaddo/Screens", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(UUID().uuidString + ".png")
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: file); imagePath = file.path }
            if let ocrFailure { warning = [warning, "OCR unavailable this session: \(ocrFailure)"].compactMap { $0 }.joined(separator: " ") }
            else {
                do {
                    let ocr = try await Self.recognizeTextBounded(in: image)
                    if !ocr.isEmpty { text = ocr + (text.isEmpty ? "" : "\n\nAccessibility context:\n" + text) }
                } catch { ocrFailure = error.localizedDescription; warning = [warning, "OCR unavailable: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ") }
            }
        } catch {
            warning = [warning, "Screenshot unavailable: \(error.localizedDescription) Accessibility text only."].compactMap { $0 }.joined(separator: " ")
        }
        if text.isEmpty { text = "No readable text was returned. Try another window or grant Accessibility permission." }
        snapshot = ScreenSnapshot(text: String(text.prefix(40_000)), appName: app.localizedName ?? "Unknown app", windowTitle: title, capturedAt: Date(), imagePath: imagePath, warning: warning)
    }
    nonisolated static func captureWindowMatches(title: String, frame: CGRect, expectedTitle: String, expectedFrame: CGRect, windowID: UInt32? = nil, expectedWindowID: UInt32? = nil) -> Bool {
        guard title == expectedTitle else { return false }
        // Stage Manager can expose thumbnail geometry for the real window. A
        // unique PID/title match in CGWindowList binds its authoritative ID.
        if let expectedWindowID { return windowID == expectedWindowID }
        return abs(frame.minX - expectedFrame.minX) < 2 && abs(frame.minY - expectedFrame.minY) < 2 && abs(frame.width - expectedFrame.width) < 2 && abs(frame.height - expectedFrame.height) < 2
    }
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }
    func prepare(_ action: DesktopAction) {
        error = nil; pending = nil; refreshPermissions()
        do {
            try action.validate(in: Self.displayBounds())
            guard let app = selectedTarget else { throw DesktopError.invalid("Choose a target application first.") }
            try validateTargetPoint(action, pid: app.processIdentifier)
            let focus = focusedElement(app.processIdentifier).map { DesktopFocusIdentity(element: $0) }
            if [.typeText, .key].contains(action.type), focus == nil { throw DesktopError.invalid("The focused control could not be identified. Focus the intended control and review again.") }
            if action.type == .openApp, let id = action.appID, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil { throw DesktopError.invalid("No installed application matches \(id).") }
            pending = DesktopApproval(action: action, appName: app.localizedName ?? "Unknown", appID: app.bundleIdentifier ?? "", pid: app.processIdentifier, windowTitle: windowTitle(app.processIdentifier), focusedElement: focusDescription(app.processIdentifier), windowID: windowID(app.processIdentifier, title: windowTitle(app.processIdentifier)), windowFrame: windowBounds(app.processIdentifier), focusIdentity: focus)
        } catch { self.error = error.localizedDescription }
    }
    func cancelPending() { pending = nil }
    func executeApproved(id: UUID) async {
        guard let approval = pending, approval.id == id else { error = "This action approval is no longer valid."; return }
        pending = nil; error = nil
        do {
            guard Date().timeIntervalSince(approval.createdAt) < 120 else { throw DesktopError.invalid("Preview expired. Preview the action again.") }
            try approval.action.validate(in: Self.displayBounds())
            if approval.action.type == .openApp {
                guard let bundle = approval.action.appID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw DesktopError.invalid("Application is no longer installed.") }
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                refreshPermissions()
                guard accessibilityAllowed else { throw DesktopError.invalid("Grant Accessibility permission before applying desktop actions.") }
                guard let app = NSRunningApplication(processIdentifier: approval.pid), !app.isTerminated else { throw DesktopError.invalid("Target application closed.") }
                // The approval UI is in Kaddo. Restore only the concrete previewed target.
                guard windowTitle(approval.pid) == approval.windowTitle, approval.windowID == nil || windowID(approval.pid, title: approval.windowTitle) == approval.windowID else { throw DesktopError.invalid("Target window changed. Preview the action again.") }
                try await restoreTarget(app)
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == approval.pid, windowTitle(approval.pid) == approval.windowTitle else { throw DesktopError.invalid("Target changed during activation. No event was sent.") }
                if approval.action.type == .click || approval.action.type == .scroll {
                    guard windowBounds(approval.pid) == approval.windowFrame else { throw DesktopError.invalid("Target window moved or resized. Capture and review the action again.") }
                }
                try validateTargetPoint(approval.action, pid: approval.pid)
                try validateHitTarget(approval.action, pid: approval.pid)
                guard approval.focusedElement == focusDescription(approval.pid) else { throw DesktopError.invalid("Focused control changed. Preview the action again.") }
                if [.typeText, .key].contains(approval.action.type) {
                    guard DesktopFocusIdentity.matches(approval.focusIdentity, focusedElement(approval.pid).map { DesktopFocusIdentity(element: $0) }) else {
                        throw DesktopError.invalid("The actual focused control changed or is unavailable. No input was sent. Review again.")
                    }
                }
                if approval.action.type == .typeText, focusDescription(approval.pid).contains("AXSecureTextField") { throw DesktopError.invalid("Typing into secure text fields is blocked.") }
                try Task.checkCancellation()
                try post(approval.action)
            }
            audit.insert(DesktopAudit(timestamp: Date(), action: approval.action.preview, target: approval.appName + " — " + approval.windowTitle, result: "Event submitted. Result is not independently verified; capture the screen to inspect it."), at: 0)
        } catch {
            self.error = error.localizedDescription
            audit.insert(DesktopAudit(timestamp: Date(), action: approval.action.preview, target: approval.appName, result: "Blocked: " + error.localizedDescription), at: 0)
        }
        audit = Array(audit.prefix(50))
    }
    private func post(_ action: DesktopAction) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        func send(_ event: CGEvent?) throws {
            guard let event else { throw DesktopError.invalid("Could not create an input event.") }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        switch action.type {
        case .click:
            let point = CGPoint(x: action.x!, y: action.y!)
            try send(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
            try send(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
        case .typeText:
            // Chunk to fit CGEvent Unicode length limits without pasting via the clipboard.
            for chunk in DesktopAction.typingChunks(action.text!) {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { throw DesktopError.invalid("Could not create typing event.") }
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                try send(event)
            }
        case .key:
            let code = DesktopAction.keyCodes[action.key!.lowercased()]!
            try send(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)); try send(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false))
        case .scroll:
            for event in try action.scrollEvents(source: source) { try send(event) }
        case .openApp: break
        }
    }
}
