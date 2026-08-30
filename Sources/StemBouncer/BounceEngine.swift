import ApplicationServices
import Foundation

@MainActor
final class BounceEngine {
    struct Update {
        var statusText: String
        var groupIndex: Int
        var progress: Double
        var completedGroupIDs: Set<UUID>
    }

    private let logic: LogicAccessibility
    private let keys: KeySender
    private let watcher: FileCompletionWatcher
    private let store: PersistenceStore

    init(
        logic: LogicAccessibility,
        keys: KeySender,
        watcher: FileCompletionWatcher = FileCompletionWatcher(),
        store: PersistenceStore = .shared
    ) {
        self.logic = logic
        self.keys = keys
        self.watcher = watcher
        self.store = store
    }

    func makeTakeFolder(base: URL, sessionName: String) throws -> URL {
        let safeSession = sessionName.safeFilenameComponent
        for take in 1...999 {
            let candidate = base.appendingPathComponent("\(safeSession) - Take \(String(format: "%02d", take))", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    func run(
        state initialState: PersistedRunState,
        configuration: RunConfiguration,
        onUpdate: @escaping @MainActor (Update) -> Void
    ) async throws -> PersistedRunState {
        var state = initialState
        var manifest = makeManifest(from: state)
        try await store.write(manifest: manifest, to: state.outputFolder)

        keys.soloKeyCode = CGKeyCode(configuration.soloKeyCode)
        keys.bounceKeyCode = CGKeyCode(configuration.bounceKeyCode)

        if let activeGroupID = state.activeGroupID,
           let interruptedGroup = state.groups.first(where: { $0.id == activeGroupID }) {
            let tracks = interruptedGroup.members.compactMap { member in
                state.tracks.first { $0.id == member.trackID }
            }
            try await logic.activateLogic()
            try await setSolo(false, for: tracks)
            state.activeGroupID = nil
            state.updatedAt = Date()
            try await store.save(run: state)
        }

        for (index, group) in state.groups.enumerated() {
            try Task.checkCancellation()
            if state.completedGroupIDs.contains(group.id) { continue }
            guard !group.members.isEmpty else { continue }

            let filename = group.filename(at: index)
            if !configuration.dryRun,
               watcher.existingFile(prefix: filename, fileExtension: "wav", in: state.outputFolder) != nil {
                onUpdate(.init(
                    statusText: "Verifying existing \(filename).wav",
                    groupIndex: index,
                    progress: Double(index) / Double(max(state.groups.count, 1)),
                    completedGroupIDs: state.completedGroupIDs
                ))
                _ = try await watcher.waitForFile(
                    prefix: filename,
                    fileExtension: "wav",
                    in: state.outputFolder,
                    timeout: .seconds(10),
                    onPoll: { try self.logic.assertNoBlockingDialog() }
                )
                state.completedGroupIDs.insert(group.id)
                state.updatedAt = Date()
                manifest.groups[index].completedAt = state.updatedAt
                manifest.groups[index].status = "complete"
                manifest.bounceSettingsObserved = logic.observedBounceSettings()
                try await store.save(run: state)
                try await store.write(manifest: manifest, to: state.outputFolder)
                onUpdate(.init(
                    statusText: "Recovered \(group.name) from its completed WAV",
                    groupIndex: index,
                    progress: Double(state.completedGroupIDs.count) / Double(max(state.groups.count, 1)),
                    completedGroupIDs: state.completedGroupIDs
                ))
                continue
            }

            onUpdate(.init(
                statusText: "Soloing \(group.name)",
                groupIndex: index,
                progress: Double(index) / Double(max(state.groups.count, 1)),
                completedGroupIDs: state.completedGroupIDs
            ))

            try await logic.activateLogic()
            let memberTracks = try group.members.map { member -> LogicTrack in
                guard let track = state.tracks.first(where: { $0.id == member.trackID }) else {
                    throw LogicAutomationError.trackUnavailable("Unknown track")
                }
                return track
            }

            do {
                try await setSolo(true, for: memberTracks)
                state.activeGroupID = group.id
                state.updatedAt = Date()
                try await store.save(run: state)
                let started = Date()
                manifest.groups[index].startedAt = started
                manifest.groups[index].status = configuration.dryRun ? "dry-running" : "bouncing"
                try await store.write(manifest: manifest, to: state.outputFolder)

                if configuration.dryRun {
                    try await Task.sleep(for: .milliseconds(400))
                } else {
                    onUpdate(.init(
                        statusText: "Bouncing \(filename)",
                        groupIndex: index,
                        progress: Double(index) / Double(max(state.groups.count, 1)),
                        completedGroupIDs: state.completedGroupIDs
                    ))
                    try await logic.openBounceAndSubmit(filename: filename, outputFolder: state.outputFolder, keySender: keys)
                    let timeoutSeconds = max(120, (state.firstBounceDuration ?? 300) * 3)
                    _ = try await watcher.waitForFile(
                        prefix: filename,
                        fileExtension: "wav",
                        in: state.outputFolder,
                        timeout: .seconds(timeoutSeconds),
                        onPoll: { try self.logic.assertNoBlockingDialog() }
                    )
                    if state.firstBounceDuration == nil {
                        state.firstBounceDuration = Date().timeIntervalSince(started)
                    }
                }

                try await setSolo(false, for: memberTracks)
                state.activeGroupID = nil
                state.completedGroupIDs.insert(group.id)
                state.updatedAt = Date()
                manifest.groups[index].completedAt = state.updatedAt
                manifest.groups[index].status = configuration.dryRun ? "dry-run complete" : "complete"
                manifest.bounceSettingsObserved = logic.observedBounceSettings()
                try await store.save(run: state)
                try await store.write(manifest: manifest, to: state.outputFolder)

                onUpdate(.init(
                    statusText: "Completed \(group.name)",
                    groupIndex: index,
                    progress: Double(state.completedGroupIDs.count) / Double(max(state.groups.count, 1)),
                    completedGroupIDs: state.completedGroupIDs
                ))
            } catch {
                await logic.cancelOpenBounceDialogs()
                if logic.isLogicFrontmost, (try? await setSolo(false, for: memberTracks)) != nil {
                    state.activeGroupID = nil
                    state.updatedAt = Date()
                    try? await store.save(run: state)
                }
                manifest.groups[index].status = "paused: \(error.localizedDescription)"
                try? await store.write(manifest: manifest, to: state.outputFolder)
                throw error
            }
        }

        manifest.completedAt = Date()
        try await store.write(manifest: manifest, to: state.outputFolder)
        try await store.clearRun()
        return state
    }

    private func setSolo(_ enabled: Bool, for tracks: [LogicTrack]) async throws {
        guard logic.isLogicFrontmost else { throw LogicAutomationError.logicNotFrontmost }
        for track in tracks {
            try Task.checkCancellation()
            if try logic.isTrackSoloed(track) == enabled { continue }
            try logic.selectTrack(track)
            keys.sendSolo()
            try await logic.waitForSoloState(enabled, for: track)
        }
    }

    private func makeManifest(from state: PersistedRunState) -> Manifest {
        let groups = state.groups.enumerated().map { index, group in
            let members = group.members.compactMap { member in
                state.tracks.first(where: { $0.id == member.trackID }).map { (member, $0) }
            }
            return Manifest.ManifestGroup(
                order: index + 1,
                name: group.name,
                memberTracks: members.map(\.1.name),
                contributeOnlyTracks: members.filter(\.0.contributeOnly).map(\.1.name),
                filename: group.filename(at: index),
                startedAt: nil,
                completedAt: state.completedGroupIDs.contains(group.id) ? state.updatedAt : nil,
                status: state.completedGroupIDs.contains(group.id) ? "complete" : "pending"
            )
        }
        return Manifest(
            sessionName: state.sessionName,
            logicVersion: logic.logicVersion,
            startedAt: state.startedAt,
            completedAt: nil,
            bounceSettingsObserved: [],
            summingCaveat: "Isolated passes through nonlinear shared-bus processing may not sum back to the full mix. This matches manual solo-and-bounce behavior.",
            groups: groups
        )
    }
}
