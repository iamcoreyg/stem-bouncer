import SwiftUI

struct TrackMembershipRow: View {
    @Environment(AppModel.self) private var model
    let track: LogicTrack
    let group: StemGroup

    private var member: GroupMember? {
        group.members.first { $0.trackID == track.id }
    }

    var body: some View {
        HStack(spacing: AppDesign.standardSpacing) {
            Button(action: toggleMembership) {
                Label {
                    VStack(alignment: .leading, spacing: AppDesign.compactSpacing / 2) {
                        Text(track.name)
                            .foregroundStyle(.primary)
                        if let stackName = track.stackName {
                            Text(stackName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: member == nil ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(member == nil ? Color.secondary : Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(member == nil ? "Include \(track.name)" : "Remove \(track.name)")

            Spacer()

            if let member {
                Menu {
                    Button("Stem audio", systemImage: member.contributeOnly ? "circle" : "checkmark") {
                        model.setContributeOnly(trackID: track.id, groupID: group.id, contributeOnly: false)
                    }
                    Button("Processing contributor", systemImage: member.contributeOnly ? "checkmark" : "circle") {
                        model.setContributeOnly(trackID: track.id, groupID: group.id, contributeOnly: true)
                    }
                } label: {
                    Label(
                        member.contributeOnly ? "Processing contributor" : "Stem audio",
                        systemImage: member.contributeOnly ? "point.3.connected.trianglepath.dotted" : "waveform"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(member.contributeOnly
                    ? "Soloed to drive processing; its audible signal remains in this stem"
                    : "Printed as part of this wet stem")
            }
        }
        .padding(.vertical, AppDesign.compactSpacing)
    }

    private func toggleMembership() {
        model.setMembership(trackID: track.id, groupID: group.id, included: member == nil)
    }
}
