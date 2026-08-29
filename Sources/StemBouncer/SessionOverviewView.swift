import SwiftUI

struct SessionOverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedGroupID: UUID?

    var body: some View {
        ScrollView {
            Group {
                if model.tracks.isEmpty {
                    LogicConnectionView()
                } else if model.groups.isEmpty {
                    StemSetChoiceView(selectedGroupID: $selectedGroupID)
                } else {
                    SessionSummaryView(selectedGroupID: $selectedGroupID)
                }
            }
            .frame(maxWidth: AppDesign.contentMaxWidth)
            .padding(AppDesign.pagePadding)
            .frame(maxWidth: .infinity)
        }
    }
}
