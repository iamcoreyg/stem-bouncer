import SwiftUI

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID
    @Binding var selectedGroupID: UUID?
    @State private var searchText = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        @Bindable var model = model

        if let groupIndex = model.groups.firstIndex(where: { $0.id == groupID }) {
            let group = model.groups[groupIndex]
            let visibleTracks = filteredTracks

            VStack(spacing: 0) {
                GroupHeader(
                    name: $model.groups[groupIndex].name,
                    filename: group.filename(at: groupIndex),
                    trackCount: group.members.count,
                    onDelete: beginDelete
                )
                .confirmationDialog(
                    "Delete “\(group.name)” from this stem set?",
                    isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete Stem", role: .destructive, action: deleteGroup)
                    Button("Cancel", role: .cancel) { }
                }

                Divider()

                if visibleTracks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(visibleTracks) { track in
                        TrackMembershipRow(track: track, group: group)
                    }
                    .listStyle(.inset)
                }

                if group.members.contains(where: \.contributeOnly) {
                    Divider()
                    Label(
                        "Processing contributors are soloed with this stem so sidechains and shared processing react correctly. Their audible signal is included in the print.",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AppDesign.standardSpacing)
                }
            }
            .searchable(text: $searchText, prompt: "Search Logic tracks")
        } else {
            ContentUnavailableView(
                "Stem not found",
                systemImage: "waveform.badge.exclamationmark",
                description: Text("Choose another stem from the sidebar.")
            )
        }
    }

    private var filteredTracks: [LogicTrack] {
        guard !searchText.isEmpty else { return model.tracks }
        return model.tracks.filter { $0.name.localizedStandardContains(searchText) }
    }

    private func beginDelete() {
        isConfirmingDelete = true
    }

    private func deleteGroup() {
        model.removeGroup(id: groupID)
        selectedGroupID = model.groups.first?.id
    }
}
