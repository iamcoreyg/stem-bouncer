import SwiftUI

struct ExportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if let saved = model.resumeState, !model.isRunning {
                HStack(spacing: AppDesign.standardSpacing) {
                    Label(
                        "Paused after \(saved.completedGroupIDs.count) of \(saved.groups.count) stems",
                        systemImage: "pause.circle.fill"
                    )
                    Spacer()
                    Button("Resume Export", systemImage: "play.fill", action: model.resumeRun)
                        .buttonStyle(.borderedProminent)
                }
                .padding(AppDesign.standardSpacing)
                .background(.orange.opacity(0.1))
                Divider()
            }

            HStack(spacing: AppDesign.standardSpacing) {
                if model.status == .completed {
                    Label("Export complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Export complete")
                    Divider()
                        .frame(height: 28)
                }

                Button(action: model.chooseOutputFolder) {
                    Label {
                        VStack(alignment: .leading, spacing: AppDesign.compactSpacing / 2) {
                            Text(model.configuration.outputFolder == nil ? "Choose delivery folder" : "Delivery folder")
                            if let folder = model.configuration.outputFolder {
                                Text(folder.path(percentEncoded: false))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } icon: {
                        Image(systemName: model.configuration.outputFolder == nil ? "folder.badge.plus" : "folder.fill")
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)

                Spacer()

                if model.isRunning {
                    ProgressView(value: model.progress) {
                        Text(model.statusText)
                    }
                    .frame(maxWidth: 280)
                    Button("Pause", systemImage: "pause.fill", action: pause)
                        .buttonStyle(.bordered)
                } else {
                    Toggle("Dry run", isOn: $model.configuration.dryRun)
                        .toggleStyle(.switch)
                        .help("Checks every stem without opening Logic’s bounce dialog")

                    Button(exportButtonTitle, systemImage: "arrow.up.right.square", action: model.showPreflight)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.canStart)
                }
            }
            .padding(.horizontal, AppDesign.sectionSpacing)
            .padding(.vertical, AppDesign.standardSpacing)
            .background(.bar)
        }
    }

    private var exportButtonTitle: String {
        if model.configuration.dryRun { "Review Dry Run" }
        else { "Review & Export \(model.groups.count)" }
    }

    private func pause() {
        model.pauseRun(reason: "Paused by user.")
    }
}
