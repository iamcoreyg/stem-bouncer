import SwiftUI

struct StemSidebarRow: View {
    let group: StemGroup
    let number: Int
    let isActive: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: AppDesign.standardSpacing) {
            Text(number, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: AppDesign.compactSpacing / 2) {
                Text(group.name)
                    .lineLimit(1)
                Text("^[\(group.members.count) track](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isActive {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Exporting")
            } else if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Complete")
            }
        }
        .padding(.vertical, AppDesign.compactSpacing / 2)
    }
}
