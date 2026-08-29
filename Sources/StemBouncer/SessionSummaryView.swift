import SwiftUI

struct SessionSummaryView: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedGroupID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
            SessionEyebrow()

            VStack(alignment: .leading, spacing: AppDesign.compactSpacing) {
                Text("Ready for archival delivery")
                    .font(.largeTitle)
                    .bold()
                Text("Review the stem set, choose the delivery folder, then let StemBouncer run Logic unattended.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: AppDesign.standardSpacing) {
                SummaryMetric(
                    value: model.groups.count,
                    label: "Wet stems",
                    systemImage: "waveform"
                )
                SummaryMetric(
                    value: model.includedTrackCount,
                    label: "Tracks included",
                    systemImage: "checklist"
                )
                SummaryMetric(
                    value: model.unassignedTracks.count,
                    label: "Need review",
                    systemImage: model.unassignedTracks.isEmpty ? "checkmark.seal" : "exclamationmark.triangle"
                )
            }

            if !model.unmatchedPresetTracks.isEmpty {
                Label(
                    "Some tracks from the prior song were not found: \(model.unmatchedPresetTracks.joined(separator: ", ")). Review the stem set before export.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .padding(AppDesign.standardSpacing)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: AppDesign.controlRadius))
            }

            if !model.unassignedTracks.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: AppDesign.compactSpacing) {
                        Text("Tracks not assigned to any stem")
                            .bold()
                        Text(model.unassignedTracks.map(\.name).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(AppDesign.standardSpacing)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: AppDesign.controlRadius))
            }

            Button("Review First Stem", systemImage: "arrow.right", action: selectFirstStem)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func selectFirstStem() {
        selectedGroupID = model.groups.first?.id
    }
}
