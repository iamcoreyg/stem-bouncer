import SwiftUI

struct StemSetOptionButton: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppDesign.standardSpacing) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppDesign.compactSpacing / 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(AppDesign.standardSpacing)
            .background(.background.secondary, in: .rect(cornerRadius: AppDesign.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Creates the stem set and opens the first stem for review")
    }
}
