import SwiftUI

struct StemSetChoiceView: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedGroupID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
            SessionEyebrow()

            VStack(alignment: .leading, spacing: AppDesign.compactSpacing) {
                Text("Choose the archival stem set")
                    .font(.largeTitle)
                    .bold()
                Text("Start with the structure you already use across the album. You can adjust any stem before export.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if !model.presets.isEmpty {
                VStack(alignment: .leading, spacing: AppDesign.standardSpacing) {
                    Text("Saved Stem Sets")
                        .font(.headline)
                    ForEach(model.presets) { preset in
                        StemSetOptionButton(
                            title: preset.name,
                            detail: "^[\(preset.groups.count) wet stem](inflect: true) · matched by track name",
                            systemImage: "square.stack.3d.up.fill"
                        ) {
                            apply(preset)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: AppDesign.standardSpacing) {
                Text(model.presets.isEmpty ? "Start a Stem Set" : "Or Start Fresh")
                    .font(.headline)

                StemSetOptionButton(
                    title: "One stem per Track Stack",
                    detail: "Best for archival delivery: drums, vocals, guitars, keys, and other musical sections.",
                    systemImage: "folder.fill.badge.gearshape"
                ) {
                    model.createOneGroupPerStack()
                    selectFirstGroup()
                }

                StemSetOptionButton(
                    title: "One stem per track",
                    detail: "Creates a separate wet print for every Logic track.",
                    systemImage: "list.bullet.rectangle"
                ) {
                    model.createOneGroupPerTrack()
                    selectFirstGroup()
                }
            }
        }
    }

    private func apply(_ preset: GroupPreset) {
        model.applyPreset(preset)
        selectFirstGroup()
    }

    private func selectFirstGroup() {
        selectedGroupID = model.groups.first?.id
    }
}
