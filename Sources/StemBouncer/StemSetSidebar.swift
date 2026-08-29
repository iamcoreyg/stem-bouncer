import SwiftUI

struct StemSetSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedGroupID: UUID?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            List(selection: $selectedGroupID) {
                Section("Session") {
                    Button(action: showSessionOverview) {
                        Label {
                            VStack(alignment: .leading, spacing: AppDesign.compactSpacing / 2) {
                                Text(model.configuration.sessionName)
                                    .lineLimit(1)
                                Text(sessionDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "music.note.house.fill")
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if !model.groups.isEmpty {
                    Section("Stem Set") {
                        ForEach(numberedGroups) { numberedGroup in
                            StemSidebarRow(
                                group: numberedGroup.group,
                                number: numberedGroup.index + 1,
                                isActive: model.currentGroupIndex == numberedGroup.index && model.isRunning,
                                isComplete: model.completedGroupIDs.contains(numberedGroup.group.id)
                            )
                            .tag(numberedGroup.group.id)
                        }
                        .onMove(perform: model.moveGroups)
                    }
                }

                if !model.unassignedTracks.isEmpty, !model.groups.isEmpty {
                    Section("Review") {
                        Label {
                            Text("^[\(model.unassignedTracks.count) unassigned track](inflect: true)")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button("Add Stem", systemImage: "plus", action: addStem)
                    .disabled(model.tracks.isEmpty || model.isRunning)
                Spacer()
                Menu("Stem Set Actions", systemImage: "ellipsis.circle") {
                    Button("One Stem per Track", action: createPerTrack)
                    Button("One Stem per Track Stack", action: createPerStack)
                }
                .labelStyle(.iconOnly)
                .disabled(model.tracks.isEmpty || model.isRunning)
            }
            .padding(AppDesign.standardSpacing)
        }
    }

    private var sessionDescription: String {
        if model.tracks.isEmpty { "No session loaded" }
        else { "^[\(model.tracks.count) track](inflect: true)" }
    }

    private var numberedGroups: [NumberedStemGroup] {
        model.groups.indices.map { NumberedStemGroup(index: $0, group: model.groups[$0]) }
    }

    private func showSessionOverview() {
        selectedGroupID = nil
    }

    private func addStem() {
        selectedGroupID = model.addGroup(named: "New Stem")
    }

    private func createPerTrack() {
        model.createOneGroupPerTrack()
        selectedGroupID = model.groups.first?.id
    }

    private func createPerStack() {
        model.createOneGroupPerStack()
        selectedGroupID = model.groups.first?.id
    }
}
