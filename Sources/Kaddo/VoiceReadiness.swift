import Foundation

/// Connection readiness is independent of conversational activity and microphone mute.
/// In particular, releasing push-to-talk while connecting must not imply a live microphone.
enum VoiceReadiness: Equatable {
    case off, authorizingMicrophone, startingBackend, preparingConversation, connectingAudio, ready
    case failed(String)

    var isStarting: Bool {
        switch self {
        case .authorizingMicrophone, .startingBackend, .preparingConversation, .connectingAudio: return true
        default: return false
        }
    }
    var isReady: Bool { self == .ready }
    var title: String {
        switch self {
        case .off: return "Voice off"
        case .authorizingMicrophone: return "Preparing microphone"
        case .startingBackend: return "Starting voice engine"
        case .preparingConversation: return "Preparing conversation"
        case .connectingAudio: return "Connecting audio"
        case .ready: return "Voice ready"
        case .failed: return "Voice couldn't connect"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Hold Control–Option to speak with Kaddo."
        case .authorizingMicrophone: return "Allow microphone access if macOS asks."
        case .startingBackend: return "Initializing your Codex connection."
        case .preparingConversation: return "Preparing Kaddo and your agent controls."
        case .connectingAudio: return "Connecting your microphone and speaker."
        case .ready: return "Hold Control–Option to speak. Release to mute."
        case .failed(let message): return message
        }
    }
    fileprivate var startupOrder: Int? {
        switch self {
        case .authorizingMicrophone: return 0
        case .startingBackend: return 1
        case .preparingConversation: return 2
        case .connectingAudio: return 3
        case .ready: return 4
        default: return nil
        }
    }
}

/// A pure lifecycle used by the media session. Every asynchronous startup callback
/// must belong to the active generation; late media events cannot resurrect it.
struct VoiceConnectionState: Equatable {
    private(set) var generation = UUID()
    private(set) var readiness: VoiceReadiness = .off
    private(set) var inputMuted = false
    var active: Bool { readiness.isStarting || readiness.isReady }
    var connected: Bool { readiness.isReady }
    // Permission dialogs are user-paced. All work after permission shares one deadline.
    static let startupTimeout: TimeInterval = 45
    var requiresStartupDeadline: Bool { readiness.isStarting && readiness != .authorizingMicrophone }
    var idleStatus: String {
        guard connected else { return readiness.isStarting ? readiness.title + "…" : "" }
        return inputMuted ? "Microphone muted · Codex voice" : "Listening · Codex voice"
    }
    mutating func start() { generation = UUID(); inputMuted = false; readiness = .authorizingMicrophone }
    mutating func stop() { generation = UUID(); inputMuted = false; readiness = .off }
    @discardableResult mutating func advance(_ next: VoiceReadiness, token: UUID) -> Bool {
        guard active, token == generation, let order = next.startupOrder,
              let current = readiness.startupOrder, order >= current, order <= current + 1 else { return false }
        readiness = next
        return true
    }
    @discardableResult mutating func setInputMuted(_ muted: Bool) -> Bool {
        guard active else { return false }
        inputMuted = muted
        return true
    }
}

/// Joins parallel audio and backend startup. The SDP is sent once, regardless of
/// which side finishes first or how often WebKit repeats an offer notification.
struct VoiceOfferGate {
    private var offer: String?
    private var started = false
    mutating func receive(_ sdp: String) {
        guard !started, !sdp.isEmpty else { return }
        offer = sdp
    }
    mutating func takeWhenBackendReady() -> String? {
        guard !started, let offer else { return nil }
        started = true
        self.offer = nil
        return offer
    }
}
