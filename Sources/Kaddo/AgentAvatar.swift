import SwiftUI

/// Agent portraits are generated for their own profiles, separate from Kaddo's shared companion.
struct AgentAvatar: View {
    var profile: HelperProfile
    var size: CGFloat = KaddoUI.avatarSize
    var isMain = false
    var body: some View {
        Group {
            if isMain { KaddoPerchedCharacter(size: size) }
            else { AgentCharacterView(identity: profile.characterIdentity, size: size) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

enum CharacterPresence {
    static func showsFollower(enabled: Bool, panelPresented: Bool, workspacePresented: Bool) -> Bool {
        enabled && !panelPresented && !workspacePresented
    }
}
