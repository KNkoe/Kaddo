import AppKit

/// Modifier-only chords fire once; other shortcuts never become voice requests.
struct VoiceShortcutGate {
    private(set) var held = false
    private var suppressed = false
    mutating func update(_ flags: NSEvent.ModifierFlags, keyDown: Bool = false) -> Bool {
        let chord = flags.contains([.control, .option])
        if !chord { held = false; suppressed = false; return false }
        // A mixed shortcut must stay suppressed until Control or Option is released.
        // Releasing Shift/Command alone must not unexpectedly open the microphone.
        if keyDown || !flags.intersection([.command, .shift]).isEmpty { suppressed = true }
        held = !suppressed
        return held
    }
}

@MainActor final class VoiceShortcut {
    var onBegin: (() -> Bool)?
    var onRelease: (() -> Void)?
    private var global: Any?
    private var local: Any?
    private var pending: Task<Void, Never>?
    private var gate = VoiceShortcutGate()
    private var engaged = false
    private let holdDelay: UInt64
    init(holdDelay: UInt64 = 160_000_000) { self.holdDelay = holdDelay }
    func start() {
        stop()
        global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }; return event
        }
    }
    private func receive(_ event: NSEvent) {
        receive(flags: event.modifierFlags, keyDown: event.type == .keyDown)
    }
    func receive(flags: NSEvent.ModifierFlags, keyDown: Bool = false) {
        let wasHeld = gate.held
        let held = gate.update(flags, keyDown: keyDown)
        if held && !wasHeld {
            pending?.cancel()
            pending = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.holdDelay)
                guard !Task.isCancelled, self.gate.held else { return }
                self.engaged = self.onBegin?() ?? false
            }
        } else if !held {
            pending?.cancel(); pending = nil
            if engaged { engaged = false; onRelease?() }
        }
    }
    func stop() {
        pending?.cancel(); pending = nil
        if engaged { engaged = false; onRelease?() }
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        gate = VoiceShortcutGate(); engaged = false
    }
}
