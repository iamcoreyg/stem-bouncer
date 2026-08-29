import SwiftUI

struct PreflightView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppDesign.standardSpacing) {
                Image(systemName: model.hasBlockingPreflightIssue ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.hasBlockingPreflightIssue ? .red : .green)
                    .accessibilityHidden(true)

                Text(model.configuration.dryRun ? "Ready to check the stem set?" : "Ready to export wet stems?")
                    .font(.title)
                    .bold()

                Text(exportSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(AppDesign.pagePadding)

            Divider()

            ScrollView {
                VStack(spacing: AppDesign.standardSpacing) {
                    ForEach(model.preflightResults) { result in
                        PreflightCheckRow(result: result)
                    }

                    Label(
                        "Turn on Do Not Disturb and leave Logic in front while the export runs. StemBouncer pauses immediately if another app takes focus.",
                        systemImage: "moon.zzz"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AppDesign.standardSpacing)
                }
                .padding(AppDesign.sectionSpacing)
            }

            Divider()

            HStack {
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Check Again", systemImage: "arrow.clockwise", action: model.refreshPreflight)
                Spacer()
                if !model.logic.isTrusted {
                    Button("Allow Accessibility Access", action: model.logic.requestPermission)
                }
                Button(primaryButtonTitle, systemImage: "play.fill") { model.startRun() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.hasBlockingPreflightIssue || !model.canStart)
            }
            .padding(AppDesign.sectionSpacing)
        }
        .frame(width: 680, height: 620)
    }

    private var exportSummary: String {
        let action = model.configuration.dryRun ? "check" : "export"
        let destination = model.configuration.outputFolder?.lastPathComponent ?? "the selected folder"
        return "StemBouncer will \(action) \(model.groups.count) stems from \(model.configuration.sessionName) and place them in a new take inside \(destination)."
    }

    private var primaryButtonTitle: String {
        model.configuration.dryRun ? "Start Dry Run" : "Export \(model.groups.count) Wet Stems"
    }
}
