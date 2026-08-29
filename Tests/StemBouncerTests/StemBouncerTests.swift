import Foundation
import Testing
@testable import StemBouncer

@Test func filenamesAreNumberedAndFilesystemSafe() {
    let group = StemGroup(name: "Lead Vox: Main/Print")
    #expect(group.filename(at: 0) == "01_Lead Vox- Main-Print")
    #expect(group.filename(at: 11) == "12_Lead Vox- Main-Print")
}

@Test func presetMatchingKeyNormalizesCaseAndWhitespace() {
    #expect("  Lead   VOX \n".matchKey == "lead vox")
    #expect("Kick".matchKey == "kick")
}

@Test func fileWatcherRequiresAStableNonemptyFile() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("StemBouncerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let expected = folder.appendingPathComponent("01_Kick.wav")
    Task {
        try await Task.sleep(for: .milliseconds(50))
        try Data([0, 1, 2, 3]).write(to: expected)
    }

    let watcher = FileCompletionWatcher(pollInterval: .milliseconds(20), stableInterval: .milliseconds(50))
    let result = try await watcher.waitForFile(prefix: "01_Kick", in: folder, timeout: .seconds(2))
    #expect(result.standardizedFileURL == expected.standardizedFileURL)
}

@Test func groupsSupportOverlapAndContributeOnlyMembers() {
    let trackID = UUID()
    let solo = StemGroup(name: "Lead", members: [.init(trackID: trackID, contributeOnly: false)])
    let vocals = StemGroup(name: "Vocals", members: [.init(trackID: trackID, contributeOnly: true)])
    #expect(solo.members.first?.trackID == vocals.members.first?.trackID)
    #expect(vocals.members.first?.contributeOnly == true)
}

@Test @MainActor func stackDefaultsPreserveTheProducerTrackOrder() {
    let model = AppModel()
    model.tracks = [
        LogicTrack(name: "Kick", stackName: "Drums"),
        LogicTrack(name: "Bass"),
        LogicTrack(name: "Snare", stackName: "Drums"),
        LogicTrack(name: "Lead Vox", stackName: "Vocals")
    ]

    model.createOneGroupPerStack()

    #expect(model.groups.map(\.name) == ["Drums", "Bass", "Vocals"])
    #expect(model.groups.first?.members.count == 2)
}
