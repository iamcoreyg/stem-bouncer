import SwiftUI

struct PreflightCheckRow: View {
    let result: PreflightResult

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.standardSpacing) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppDesign.compactSpacing / 2) {
                Text(result.title)
                    .font(.headline)
                Text(result.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(AppDesign.standardSpacing)
        .background(.background.secondary, in: .rect(cornerRadius: AppDesign.controlRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title), \(severityLabel). \(result.detail)")
    }

    private var icon: String {
        switch result.severity {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch result.severity {
        case .pass: .green
        case .warning: .orange
        case .failure: .red
        }
    }

    private var severityLabel: String {
        switch result.severity {
        case .pass: "passed"
        case .warning: "review"
        case .failure: "blocked"
        }
    }
}
