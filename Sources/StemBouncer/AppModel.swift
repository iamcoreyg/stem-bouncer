import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppModel {
    var tracks: [LogicTrack] = []
    var groups: [StemGroup] = []
    var presets: [GroupPreset] = []
    var configuration = RunConfiguration()
    var status: RunStatus = .idle
    var statusText = "Open a Logic session to prepare its archival stems."
    var progress = 0.0
    var currentGroupIndex: Int?
    var completedGroupIDs = Set<UUID>()
    var preflightResults: [PreflightResult] = []
    var isShowingPreflight = false
    var presentedError: AppAlert?
    var resumeState: PersistedRunState?
    var unmatchedPresetTracks: [String] = []

    @ObservationIgnored let logic = LogicAccessibility()
    @ObservationIgnored private let keys = KeySender()
    @ObservationIgnored private let store = PersistenceStore.shared
    @ObservationIgnored private lazy var engine = BounceEngine(logic: logic, keys: keys)
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    var isRunning: Bool { status == .running }
    var hasBlockingPreflightIssue: Bool { preflightResults.contains { $0.severity == .failure } }
    var canStart: Bool { !groups.isEmpty && groups.allSatisfy { !$0.members.isEmpty } && configuration.outputFolder != nil }
    var assignedTrackIDs: Set<UUID> { Set(groups.flatMap(\.members).map(\.trackID)) }
    var unassignedTracks: [LogicTrack] { tracks.filter { !assignedTrackIDs.contains($0.id) } }
    var includedTrackCount: Int { assignedTrackIDs.count }

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedBundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self,
                      self.status == .running,
                      activatedBundleID != LogicAccessibility.bundleIdentifier else { return }
                self.pauseRun(reason: "Paused because another app became active.")
            }
        }

        Task {
            presets = (try? await store.loadPresets()) ?? []
            if let saved = try? await store.loadRun() {
                resumeState = saved
                statusText = "A paused run for \(saved.sessionName) can be resumed."
            }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func discoverTracks() async {
        presentedError = nil
        statusText = "Reading the open Logic session…"
        do {
            let previousTracks = tracks
            let previousGroups = groups
            let discovered = try logic.discoverTracks()
            status = .idle
            progress = 0
            currentGroupIndex = nil
            completedGroupIDs.removeAll()
            tracks = discovered
            if let sessionName = logic.currentSessionName {
                configuration.sessionName = sessionName
            }
            if !previousGroups.isEmpty, !previousTracks.isEmpty {
                remapExistingStemSet(previousGroups, from: previousTracks, to: discovered)
            }
            statusText = groups.isEmpty
                ? "\(discovered.count) tracks found. Choose a stem set to continue."
                : "\(discovered.count) tracks found. Your stem set is ready to review."
        } catch {
            statusText = "Couldn’t read the Logic session."
            presentedError = AppAlert(message: error.localizedDescription)
            if !logic.isTrusted { logic.requestPermission() }
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Stem Output Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { configuration.outputFolder = panel.url }
    }

    func createOneGroupPerTrack() {
        groups = tracks.map { StemGroup(name: $0.name, members: [.init(trackID: $0.id, contributeOnly: false)]) }
        statusText = "Created \(groups.count) stem groups."
    }

    func createOneGroupPerStack() {
        var orderedNames: [String] = []
        var grouped: [String: [LogicTrack]] = [:]
        for track in tracks {
            let name = track.stackName ?? track.name
            if grouped[name] == nil { orderedNames.append(name) }
            grouped[name, default: []].append(track)
        }
        groups = orderedNames.map { name in
            StemGroup(name: name, members: grouped[name, default: []].map { .init(trackID: $0.id, contributeOnly: false) })
        }
        statusText = "Created \(groups.count) stack-based groups."
    }

    func addGroup() {
        groups.append(StemGroup(name: "New Stem"))
    }

    func addGroup(named name: String) -> UUID {
        let group = StemGroup(name: name)
        groups.append(group)
        return group.id
    }

    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
    }

    func moveGroup(id: UUID, offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), groups.count - 1)
        guard destination != index else { return }
        groups.swapAt(index, destination)
    }

    func moveGroups(fromOffsets: IndexSet, toOffset: Int) {
        groups.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func setMembership(trackID: UUID, groupID: UUID, included: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if included {
            if !groups[index].members.contains(where: { $0.trackID == trackID }) {
                groups[index].members.append(.init(trackID: trackID, contributeOnly: false))
            }
        } else {
            groups[index].members.removeAll { $0.trackID == trackID }
        }
    }

    func toggleContributeOnly(trackID: UUID, groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
              let memberIndex = groups[groupIndex].members.firstIndex(where: { $0.trackID == trackID }) else { return }
        groups[groupIndex].members[memberIndex].contributeOnly.toggle()
    }

    func setContributeOnly(trackID: UUID, groupID: UUID, contributeOnly: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
              let memberIndex = groups[groupIndex].members.firstIndex(where: { $0.trackID == trackID }) else { return }
        groups[groupIndex].members[memberIndex].contributeOnly = contributeOnly
    }

    func savePreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let presetGroups = groups.map { group in
            GroupPreset.PresetGroup(name: group.name, members: group.members.compactMap { member in
                tracks.first(where: { $0.id == member.trackID }).map {
                    .init(trackName: $0.name, contributeOnly: member.contributeOnly)
                }
            })
        }
        presets.removeAll { $0.name.matchKey == name.matchKey }
        presets.append(.init(id: UUID(), name: name, groups: presetGroups, createdAt: Date()))
        Task { try? await store.save(presets: presets) }
    }

    func applyPreset(_ preset: GroupPreset) {
        var unmatched = Set<String>()
        groups = preset.groups.map { presetGroup in
            let members = presetGroup.members.compactMap { presetMember -> GroupMember? in
                guard let track = tracks.first(where: { $0.name.matchKey == presetMember.trackName.matchKey }) else {
                    unmatched.insert(presetMember.trackName)
                    return nil
                }
                return .init(trackID: track.id, contributeOnly: presetMember.contributeOnly)
            }
            return StemGroup(name: presetGroup.name, members: members)
        }
        unmatchedPresetTracks = unmatched.sorted()
        statusText = unmatched.isEmpty ? "Applied \(preset.name)." : "Applied \(preset.name); \(unmatched.count) preset tracks need attention."
    }

    func deletePreset(_ preset: GroupPreset) {
        presets.removeAll { $0.id == preset.id }
        Task { try? await store.save(presets: presets) }
    }

    func showPreflight() {
        requestNotificationPermission()
        status = .preflight
        preflightResults = logic.preflight(configuration: configuration)
        isShowingPreflight = true
    }

    func refreshPreflight() {
        preflightResults = logic.preflight(configuration: configuration)
    }

    func startRun(allowWarnings: Bool = true) {
        guard !hasBlockingPreflightIssue, canStart else { return }
        guard let baseFolder = configuration.outputFolder else { return }
        isShowingPreflight = false
        presentedError = nil

        do {
            let takeFolder = try engine.makeTakeFolder(base: baseFolder, sessionName: configuration.sessionName)
            var state = PersistedRunState(
                id: UUID(),
                sessionName: configuration.sessionName,
                groups: groups,
                tracks: tracks,
                completedGroupIDs: [],
                outputFolder: takeFolder,
                startedAt: Date(),
                updatedAt: Date(),
                firstBounceDuration: nil,
                dryRun: configuration.dryRun,
                activeGroupID: nil
            )
            begin(state: &state)
        } catch {
            status = .failed
            presentedError = AppAlert(message: error.localizedDescription)
        }
    }

    func resumeRun() {
        Task { await prepareAndResumeRun() }
    }

    func pauseRun(reason: String) {
        guard status == .running else { return }
        runTask?.cancel()
        runTask = nil
        status = .paused
        statusText = reason
    }

    private func begin(state: inout PersistedRunState) {
        status = .running
        progress = Double(state.completedGroupIDs.count) / Double(max(state.groups.count, 1))
        completedGroupIDs = state.completedGroupIDs
        statusText = configuration.dryRun ? "Starting dry run…" : "Starting bounce run…"
        let runState = state
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.save(run: runState)
                let completed = try await self.engine.run(state: runState, configuration: self.configuration) { update in
                    self.statusText = update.statusText
                    self.currentGroupIndex = update.groupIndex
                    self.progress = update.progress
                    self.completedGroupIDs = update.completedGroupIDs
                }
                self.completedGroupIDs = completed.completedGroupIDs
                self.progress = 1
                self.status = .completed
                self.statusText = self.configuration.dryRun ? "Dry run completed." : "All stems completed."
                self.resumeState = nil
                self.notifyCompletion()
            } catch is CancellationError {
                self.resumeState = try? await self.store.loadRun()
            } catch {
                self.status = .paused
                self.statusText = "Run paused safely."
                self.presentedError = AppAlert(message: error.localizedDescription)
                self.resumeState = try? await self.store.loadRun()
            }
            self.runTask = nil
        }
    }

    private func prepareAndResumeRun() async {
        guard var saved = resumeState else { return }
        do {
            let currentTracks = try logic.discoverTracks()
            let priorTracksByID = Dictionary(uniqueKeysWithValues: saved.tracks.map { ($0.id, $0) })
            let currentTracksByKey = Dictionary(uniqueKeysWithValues: currentTracks.map { ($0.discoveryKey, $0) })
            saved.groups = try saved.groups.map { group in
                var updated = group
                updated.members = try group.members.map { member in
                    guard let priorTrack = priorTracksByID[member.trackID],
                          let currentTrack = currentTracksByKey[priorTrack.discoveryKey] else {
                        throw LogicAutomationError.trackUnavailable(priorTracksByID[member.trackID]?.name ?? "Unknown track")
                    }
                    return GroupMember(trackID: currentTrack.id, contributeOnly: member.contributeOnly)
                }
                return updated
            }
            saved.tracks = currentTracks
            tracks = currentTracks
            groups = saved.groups
            configuration.sessionName = saved.sessionName
            configuration.outputFolder = saved.outputFolder.deletingLastPathComponent()
            configuration.dryRun = saved.dryRun
            completedGroupIDs = saved.completedGroupIDs
            begin(state: &saved)
        } catch {
            status = .paused
            statusText = "Resume needs attention."
            presentedError = AppAlert(message: error.localizedDescription)
        }
    }

    private func remapExistingStemSet(
        _ existingGroups: [StemGroup],
        from previousTracks: [LogicTrack],
        to currentTracks: [LogicTrack]
    ) {
        let previousByID = Dictionary(uniqueKeysWithValues: previousTracks.map { ($0.id, $0) })
        let currentByKey = Dictionary(uniqueKeysWithValues: currentTracks.map { ($0.discoveryKey, $0) })
        var unmatched = Set<String>()

        groups = existingGroups.map { group in
            var updated = group
            updated.members = group.members.compactMap { member in
                guard let previousTrack = previousByID[member.trackID],
                      let currentTrack = currentByKey[previousTrack.discoveryKey] else {
                    if let name = previousByID[member.trackID]?.name { unmatched.insert(name) }
                    return nil
                }
                return GroupMember(trackID: currentTrack.id, contributeOnly: member.contributeOnly)
            }
            return updated
        }
        unmatchedPresetTracks = unmatched.sorted()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyCompletion() {
        NSSound(named: NSSound.Name("Glass"))?.play()
        let content = UNMutableNotificationContent()
        content.title = "StemBouncer finished"
        content.body = configuration.dryRun ? "The dry run completed successfully." : "All stem groups were bounced successfully."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
