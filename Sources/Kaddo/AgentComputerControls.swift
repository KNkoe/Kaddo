import SwiftUI

struct AgentComputerControls: View {
    @ObservedObject var computer: AgentComputerUse
    var onlyJob: UUID? = nil
    var cancel: (UUID) -> Void
    var body: some View {
        if let id = computer.jobID, onlyJob == nil || onlyJob == id {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(computer.status, systemImage: "desktopcomputer").font(.headline)
                    Spacer()
                    Button("Stop computer use", role: .destructive) { cancel(id) }
                }
                if let permission = computer.permission {
                    NativeComputerPermissionView(request: permission) { allow, values, session in computer.resolvePermission(permission.id, allow: allow, values: values, rememberSession: session) }.id(permission.id)
                }
                if let review = computer.pending {
                    ScrollView { Text(review.actionDescription).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    Text("Target: \(review.approval.appName) · \(review.approval.windowTitle)").font(.caption).foregroundStyle(.secondary)
                    if AgentComputerVisualReview.required(for: review.approval.action, elementIndex: review.elementIndex),
                       let data = AgentComputerVisualReview.imageData(review.reviewedImageURL), let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .accessibilityLabel("Exact app screenshot for this coordinate action")
                        Text("Coordinates refer to this screenshot. Any visual change requires a fresh review.").font(.caption2).foregroundStyle(.secondary)
                    }
                    if review.elementIndex != nil {
                        if let observed = review.observedTarget {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Observed target · \(observed.summary)").font(.caption.weight(.semibold))
                                Text(observed.context).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("This element is not identified in the captured view. A fresh observation is required.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text("Agent request: \(review.reason)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    HStack {
                        Button("Allow this action") { computer.resolve(review.id, allow: true) }.buttonStyle(KaddoButtonStyle(prominent: true))
                            .disabled(review.elementIndex != nil && review.observedTarget == nil)
                        Button("Deny action") { computer.resolve(review.id, allow: false) }
                    }
                    Text("This approves only the action shown. The agent must inspect the result before continuing.").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(12).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .buttonStyle(KaddoButtonStyle())
            .accessibilityElement(children: .contain)
        }
    }
}

private struct NativeComputerPermissionView: View {
    let request: NativeComputerPermission
    var resolve: (Bool, [String: Any], Bool) -> Void
    @State private var rememberSession = false
    @State private var choices: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.message).font(.callout).textSelection(.enabled)
            if request.supported {
                ForEach(request.fields) { field in
                    if field.boolean {
                        Toggle(field.title, isOn: Binding(get: { toggles[field.id] ?? false }, set: { toggles[field.id] = $0 }))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(field.title).font(.callout.weight(.medium))
                            KaddoMenuPicker(title: field.title,
                                selection: Binding(get: { choices[field.id] ?? field.choices.first ?? "" }, set: { choices[field.id] = $0 }),
                                options: field.choices.map { ($0, $0) })
                        }
                    }
                }
                if request.allowSession { Toggle("Allow for this computer task", isOn: $rememberSession) }
                Button("Approve Codex access") {
                    var values: [String: Any] = [:]
                    for field in request.fields { values[field.id] = field.boolean ? (toggles[field.id] ?? false) as Any : (choices[field.id] ?? field.choices.first ?? "") as Any }
                    resolve(true, values, rememberSession)
                }.buttonStyle(KaddoButtonStyle(prominent: true))
            } else { Text("This request requires verification in Codex. Kaddo cannot approve it here.").font(.caption) }
            Button("Decline access") { resolve(false, [:], false) }
        }
    }
}
