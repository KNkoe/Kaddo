import SwiftUI

struct AgentProfileView: View {
    let helperID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    private var helper: HelperProfile? { model.helpers.first { $0.id == helperID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent profile").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }.padding(22)
            Divider()
            ScrollView {
                if let helper {
                    let identity = helper.characterIdentity
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 18) {
                            AgentAvatar(profile: helper, size: 84, isMain: helper.id == model.primaryHelperID)
                                .frame(width: 100, height: 100)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(identity.personalityName).font(.title3.bold())
                                Text(identity.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                Text(identity.traits.joined(separator: " · ")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                        }
                        if helper.characterDesignState == "designing" {
                            HStack { ProgressView(); Text("Creating a character and personality for this agent…").font(.caption) }
                        }
                        if let error = helper.characterDesignError {
                            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        Text("Name").font(.headline)
                        TextField("Agent name", text: $name)
                        Text("Role & instructions").font(.headline)
                        KaddoTextEditor(text: $instructions).frame(minHeight: 114).accessibilityLabel("Role and instructions")
                        DisclosureGroup("Personality details") {
                            Text(identity.behavior).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                        }
                        HStack {
                            Menu("Character options") {
                                Button(helper.characterDesignState == "failed" ? "Retry character design" : "Redesign character") {
                                    model.updateHelper(id: helperID, name: name, instructions: instructions)
                                    model.regenerateIdentity(id: helperID)
                                }.disabled(helper.characterDesignState == "designing" || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            Spacer()
                            Button("Save profile") {
                                model.updateHelper(id: helperID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), instructions: instructions)
                                dismiss()
                            }.buttonStyle(KaddoButtonStyle(prominent: true)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(22)
                }
            }
        }.buttonStyle(KaddoButtonStyle()).textFieldStyle(KaddoTextFieldStyle()).frame(width: 580, height: 540).preferredColorScheme(.dark)
            .onAppear { if let helper { name = helper.name; instructions = helper.instructions } }
    }
}
