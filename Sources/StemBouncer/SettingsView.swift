import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Archive") {
                TextField("Session name", text: $model.configuration.sessionName)
                Picker("Cycle mode", selection: $model.configuration.cycleExpectation) {
                    ForEach(CycleExpectation.allCases) { expectation in
                        Text(expectation.rawValue).tag(expectation)
                    }
                }
            }

            Section("Keyboard Control — Advanced") {
                LabeledContent("Solo virtual key code") {
                    TextField("1", value: $model.configuration.soloKeyCode, format: .number)
                        .frame(width: 70)
                }
                LabeledContent("Bounce virtual key code") {
                    TextField("11", value: $model.configuration.bounceKeyCode, format: .number)
                        .frame(width: 70)
                }
                Text("Only change these if your Logic key commands have been remapped. Defaults are S and Command-B.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Signal-path note") {
                Text("Wet stems made through nonlinear shared buses may not sum back to the full mix. This is identical to soloing and bouncing by hand.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
