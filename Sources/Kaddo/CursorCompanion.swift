import SwiftUI
import AppKit

/// A transient reply event. It is never restored from chat history on launch.
struct CompanionReply: Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    init(text: String, createdAt: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.createdAt = createdAt
        self.text = Self.summary(text)
    }
    var duration: TimeInterval { min(12, max(6, Double(text.count) / 22 + 3)) }
    static func summary(_ text: String) -> String {
        let withoutCode = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
        let plain = withoutCode.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^\\s{0,3}[#>•*-]+\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !plain.isEmpty else { return "Open Kaddo to see the full reply." }
        guard plain.count > 170 else { return plain }
        let prefix = String(plain.prefix(167))
        let boundary = prefix.lastIndex(of: " ") ?? prefix.endIndex
        return String(prefix[..<boundary]) + "…"
    }
    func visibleText(at date: Date, reducedMotion: Bool) -> String {
        reducedMotion ? text : String(text.prefix(min(text.count, max(0, Int(max(0, date.timeIntervalSince(createdAt)) * 52)))))
    }
}

/// Window expansion preserves the character's screen position, including at display edges.
struct CursorCompanionLayout: Equatable {
    var frame: CGRect
    var headCenter: CGPoint
    var bubbleFrame: CGRect
    var bubbleAbove: Bool
    static let idle = CursorCompanionLayout(frame: CGRect(x: 0, y: 0, width: 45, height: 45), headCenter: CGPoint(x: 22.5, y: 22.5), bubbleFrame: .zero, bubbleAbove: true)
    static func make(headOrigin: CGPoint, bounds: CGRect, showingReply: Bool) -> Self {
        guard bounds.width >= 45, bounds.height >= 45, bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.minY.isFinite,
              headOrigin.x.isFinite, headOrigin.y.isFinite else { return .idle }
        let head = CGPoint(x: min(bounds.maxX - 45, max(bounds.minX, headOrigin.x)), y: min(bounds.maxY - 45, max(bounds.minY, headOrigin.y)))
        guard showingReply, bounds.width >= 120, bounds.height >= 110 else {
            var result = idle; result.frame.origin = head; return result
        }
        let width = min(260, bounds.width), height = min(130, bounds.height)
        let above = bounds.maxY - head.y >= height
        let x = min(bounds.maxX - width, max(bounds.minX, head.x + 22.5 - width / 2))
        let y = min(bounds.maxY - height, max(bounds.minY, above ? head.y : head.y + 45 - height))
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let center = CGPoint(x: head.x + 22.5 - x, y: frame.maxY - head.y - 22.5)
        let bubbleHeight = max(0, height - 54)
        return Self(frame: frame, headCenter: center,
                    bubbleFrame: CGRect(x: 0, y: above ? 0 : 54, width: width, height: bubbleHeight), bubbleAbove: above)
    }
}

struct CompanionReplyBubble: View {
    let reply: CompanionReply
    var above: Bool
    var tailX: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Text(reply.text).hidden().overlay(alignment: .topLeading) {
                Text(reply.visibleText(at: timeline.date, reducedMotion: reduceMotion))
            }.font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 10)
                .foregroundStyle(.white.opacity(0.96))
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 0.7))
                .overlay(alignment: above ? .bottomLeading : .topLeading) {
                    ReplyTail().fill(Color(white: above ? 0.10 : 0.19)).frame(width: 12, height: 8)
                        .rotationEffect(.degrees(above ? 0 : 180)).offset(x: tailX - 6, y: above ? 7 : -7)
                }
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        }.accessibilityElement(children: .ignore).accessibilityLabel(reply.text)
    }
}
private struct ReplyTail: Shape {
    func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: 0)); p.closeSubpath() } }
}
