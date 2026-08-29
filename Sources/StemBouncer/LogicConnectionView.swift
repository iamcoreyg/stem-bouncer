import SwiftUI

struct LogicConnectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: AppDesign.sectionSpacing) {
            Spacer(minLength: 70)

            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: AppDesign.standardSpacing) {
                Text("Archive wet stems")
                    .font(.largeTitle)
                    .bold()
                Text("Open a finished song in Logic Pro. StemBouncer will read its tracks without changing the session, then prepare the wet stems your label needs.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }

            Button("Read Open Logic Session", systemImage: "music.note.list", action: discover)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            if !model.logic.isTrusted {
                Button("Allow Accessibility Access", systemImage: "hand.raised", action: model.logic.requestPermission)
                    .buttonStyle(.link)
            }

            Label("Logic stays in control of the sound. Your current bounce settings, buses, sends, effects, and master chain are preserved.", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)

            Spacer(minLength: 70)
        }
        .frame(maxWidth: .infinity, minHeight: 520)
    }

    private func discover() {
        Task { await model.discoverTracks() }
    }
}
