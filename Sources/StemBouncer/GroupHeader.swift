import SwiftUI

struct GroupHeader: View {
    @Binding var name: String
    let filename: String
    let trackCount: Int
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.standardSpacing) {
            VStack(alignment: .leading, spacing: AppDesign.compactSpacing) {
                TextField("Stem name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.largeTitle)
                    .bold()
                    .accessibilityLabel("Stem name")

                HStack(spacing: AppDesign.standardSpacing) {
                    Label(filename, systemImage: "waveform")
                    Text("^[\(trackCount) included track](inflect: true)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Delete Stem", systemImage: "trash", action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete this stem")
        }
        .padding(AppDesign.pagePadding)
    }
}
