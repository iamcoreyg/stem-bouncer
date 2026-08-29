import SwiftUI

struct SessionEyebrow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label {
            Text("\(model.configuration.sessionName) · ^[\(model.tracks.count) track](inflect: true)")
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
