import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedGroupID: UUID?
    @State private var presetName = ""
    @State private var isNamingStemSet = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            StemSetSidebar(selectedGroupID: $selectedGroupID)
                .navigationSplitViewColumnWidth(
                    min: AppDesign.sidebarWidth,
                    ideal: AppDesign.sidebarWidth,
                    max: 340
                )
        } detail: {
            VStack(spacing: 0) {
                if let selectedGroupID {
                    GroupDetailView(groupID: selectedGroupID, selectedGroupID: $selectedGroupID)
                } else {
                    SessionOverviewView(selectedGroupID: $selectedGroupID)
                }

                Divider()
                ExportBar()
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.isShowingPreflight) { PreflightView() }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text("StemBouncer"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Save Stem Set", isPresented: $isNamingStemSet) {
            TextField("Stem set name", text: $presetName)
            Button("Cancel", role: .cancel, action: clearPresetName)
            Button("Save", action: saveStemSet)
        } message: {
            Text("Reuse this stem structure across songs with matching track names.")
        }
        .onChange(of: model.groups.map(\.id)) { _, groupIDs in
            if let selectedGroupID, groupIDs.contains(selectedGroupID) { return }
            self.selectedGroupID = groupIDs.first
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Refresh Logic Session", systemImage: "arrow.clockwise", action: refreshSession)
                .disabled(model.isRunning)

            Menu("Stem Sets", systemImage: "square.stack.3d.up") {
                if model.presets.isEmpty {
                    Text("No saved stem sets")
                } else {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                    Divider()
                }
                Button("Save Current Stem Set…", systemImage: "plus", action: beginSavingStemSet)
                    .disabled(model.groups.isEmpty)
            }
        }
    }

    private func refreshSession() {
        selectedGroupID = nil
        Task { await model.discoverTracks() }
    }

    private func apply(_ preset: GroupPreset) {
        model.applyPreset(preset)
        selectedGroupID = model.groups.first?.id
    }

    private func beginSavingStemSet() {
        presetName = ""
        isNamingStemSet = true
    }

    private func saveStemSet() {
        model.savePreset(named: presetName)
        clearPresetName()
    }

    private func clearPresetName() {
        presetName = ""
    }
}
