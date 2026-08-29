import SwiftUI

struct SummaryMetric: View {
    let value: Int
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.standardSpacing) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text(value, format: .number)
                .font(.title)
                .bold()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppDesign.sectionSpacing)
        .background(.background.secondary, in: .rect(cornerRadius: AppDesign.cardRadius))
    }
}
