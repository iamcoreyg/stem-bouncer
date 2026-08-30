import ApplicationServices
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

@Test func logicTrackHeaderDescriptionYieldsTheDisplayedName() {
    #expect(LogicAccessibility.trackName(inHeaderDescription: "Track 20 “jan 5 kick”") == "jan 5 kick")
    #expect(LogicAccessibility.trackName(inHeaderDescription: "Track 2 \"Audio 12\"") == "Audio 12")
}

@Test func logicTrackHeaderRolesIncludeLogicTwelveLayoutItems() {
    #expect(LogicAccessibility.isTrackHeaderRole(kAXLayoutItemRole as String))
    #expect(LogicAccessibility.isTrackHeaderRole(kAXGroupRole as String))
    #expect(!LogicAccessibility.isTrackHeaderRole(kAXRadioButtonRole as String))
}

@Test func logicSavePanelUsesTheNamedFilenameField() {
    #expect(LogicAccessibility.isSaveFilenameField(identifier: "saveAsNameTextField", label: ""))
    #expect(LogicAccessibility.isSaveFilenameField(identifier: nil, label: "Save As:"))
    #expect(!LogicAccessibility.isSaveFilenameField(identifier: nil, label: "manifest.json"))
}

@Test func logicBounceLabelsMatchNamesWithoutPunctuation() {
    #expect(LogicAccessibility.axLabel("Uncompressed", matches: "uncompressed"))
    #expect(LogicAccessibility.axLabel("File Type:", matches: "file type"))
    #expect(!LogicAccessibility.axLabel("Sample Rate:", matches: "file type"))
}

@Test func logicRecognizesNamedUncompressedFileTypes() {
    #expect(LogicAccessibility.isUncompressedFileTypeValue("AIFF"))
    #expect(LogicAccessibility.isUncompressedFileTypeValue("WAVE"))
    #expect(LogicAccessibility.isUncompressedFileTypeValue("CAF"))
    #expect(!LogicAccessibility.isUncompressedFileTypeValue("Interleaved"))
    #expect(!LogicAccessibility.isUncompressedFileTypeValue("44.1 kHz"))
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

@Test func fileWatcherCanRequireWAVOutput() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("StemBouncerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    try Data([0, 1, 2, 3]).write(to: folder.appendingPathComponent("01_Kick.mp3"))
    let expected = folder.appendingPathComponent("01_Kick.wav")
    let writer = Task {
        try await Task.sleep(for: .milliseconds(100))
        try Data([4, 5, 6, 7]).write(to: expected)
    }
    defer { writer.cancel() }

    let watcher = FileCompletionWatcher(pollInterval: .milliseconds(20), stableInterval: .milliseconds(50))
    let result = try await watcher.waitForFile(
        prefix: "01_Kick",
        fileExtension: "wav",
        in: folder,
        timeout: .seconds(2)
    )
    #expect(result.standardizedFileURL == expected.standardizedFileURL)
}

@Test func fileWatcherFindsExistingWAVWithoutMatchingOtherFormats() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("StemBouncerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let mp3 = folder.appendingPathComponent("01_Kick.mp3")
    let wav = folder.appendingPathComponent("01_Kick.wav")
    try Data([0]).write(to: mp3)
    try Data([1]).write(to: wav)

    let watcher = FileCompletionWatcher()
    #expect(
        watcher.existingFile(prefix: "01_Kick", fileExtension: "wav", in: folder)?.standardizedFileURL
            == wav.standardizedFileURL
    )
    #expect(watcher.existingFile(prefix: "02_Snare", fileExtension: "wav", in: folder) == nil)
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
