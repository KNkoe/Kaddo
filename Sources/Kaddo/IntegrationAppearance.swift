import SwiftUI
import AppKit

enum IntegrationHealth: Equatable {
    case connected, reconnect, disconnected, connecting, unknown
    init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ACTIVE": self = .connected
        case "EXPIRED", "REVOKED", "FAILED": self = .reconnect
        case "INACTIVE", "DISABLED": self = .disconnected
        case "INITIALIZING", "INITIATED": self = .connecting
        default: self = .unknown
        }
    }
    var title: String {
        switch self {
        case .connected: return "Connected"
        case .reconnect: return "Reconnect needed"
        case .disconnected: return "Disconnected"
        case .connecting: return "Awaiting sign-in"
        case .unknown: return "Status unknown"
        }
    }
    var symbol: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .reconnect: return "exclamationmark.circle.fill"
        case .disconnected: return "minus.circle"
        case .connecting: return "clock"
        case .unknown: return "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .connected: return .green
        case .reconnect: return .orange
        case .connecting: return .blue
        default: return .secondary
        }
    }
}

extension IntegrationConnection {
    var health: IntegrationHealth { IntegrationHealth(status: status) }
    var displayName: String { IntegrationBrand.name(toolkit) }
}

enum IntegrationBrand {
    static func name(_ slug: String) -> String {
        ["googlecalendar": "Google Calendar", "googledrive": "Google Drive", "gmail": "Gmail",
         "github": "GitHub", "linkedin": "LinkedIn", "youtube": "YouTube", "content_studio": "Content Studio",
         "cloudflare": "Cloudflare", "trello": "Trello", "facebook": "Facebook", "notion": "Notion",
         "figma": "Figma", "vercel": "Vercel", "supabase": "Supabase", "slack": "Slack"][slug.lowercased()]
            ?? slug.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func iconURL(_ slug: String) -> URL? {
        return nil // Generic initials avoid bundling third-party brand assets.
    }
}

struct IntegrationAppIcon: View {
    let toolkit: String
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(Color.white)
            if let url = IntegrationBrand.iconURL(toolkit), let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().scaledToFit().padding(size * 0.18)
            } else {
                Text(String(IntegrationBrand.name(toolkit).prefix(1))).font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.25))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct IntegrationAccountCard: View {
    let item: IntegrationConnection
    let selected: Bool
    let verified: Bool
    let busy: Bool
    let select: () -> Void
    let reconnect: () -> Void
    private var selectable: Bool { verified && item.health == .connected }
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if selectable {
                    Button(action: select) { accountContent }.buttonStyle(.plain).disabled(busy)
                } else { accountContent }
            }
            if verified && item.health != .connected {
                Button(item.health == .connecting ? "Continue" : "Reconnect", action: reconnect)
                    .buttonStyle(KaddoButtonStyle()).disabled(busy)
            }
        }.padding(14).frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(selected && selectable ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: KaddoUI.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: KaddoUI.cornerRadius).strokeBorder(selected && selectable ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: 1))
            .accessibilityElement(children: .contain)
    }
    private var accountContent: some View {
                HStack(spacing: 12) {
                    IntegrationAppIcon(toolkit: item.toolkit)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.displayName).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        Text(item.alias).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Label(verified ? item.health.title : "Status not verified", systemImage: verified ? item.health.symbol : "arrow.clockwise.circle")
                            .font(.caption.weight(.medium)).foregroundStyle(verified ? item.health.color : .secondary)
                    }
                    Spacer(minLength: 4)
                    if selected && selectable { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }.contentShape(Rectangle())
    }
}

struct IntegrationAuthorization: Equatable {
    let accountID: String
    let url: URL
    static func parse(_ output: String) throws -> Self {
        // The CLI writes human progress before its final JSON object.
        for index in output.indices where output[index] == "{" {
            guard let data = output[index...].data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["connected_account_id"] as? String, !id.isEmpty,
                  let text = object["redirect_url"] as? String, let url = URL(string: text),
                  url.scheme == "https", let host = url.host?.lowercased(),
                  (host == "composio.dev" || host.hasSuffix(".composio.dev")),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { continue }
            return Self(accountID: id, url: url)
        }
        throw IntegrationError.failed("No sign-in link was returned. Refresh your apps before trying again; a connection may already have been created.")
    }
}
