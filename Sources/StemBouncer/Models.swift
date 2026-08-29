import Foundation

struct LogicTrack: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var stackName: String?
    var discoveryKey: String

    init(id: UUID = UUID(), name: String, stackName: String? = nil, ordinal: Int = 0) {
        self.id = id
        self.name = name
        self.stackName = stackName
        self.discoveryKey = "\(name.matchKey)#\(ordinal)"
    }
}

struct GroupMember: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { trackID }
    let trackID: UUID
    var contributeOnly: Bool
}

struct StemGroup: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var members: [GroupMember]
    var rangeOverride: BounceRange?

    init(id: UUID = UUID(), name: String, members: [GroupMember] = [], rangeOverride: BounceRange? = nil) {
        self.id = id
        self.name = name
        self.members = members
        self.rangeOverride = rangeOverride
    }
}

struct BounceRange: Codable, Hashable, Sendable {
    var start: String
    var end: String
}

struct GroupPreset: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var groups: [PresetGroup]
    var createdAt: Date

    struct PresetGroup: Codable, Hashable, Sendable {
        var name: String
        var members: [PresetMember]
    }

    struct PresetMember: Codable, Hashable, Sendable {
        var trackName: String
        var contributeOnly: Bool
    }
}

enum CycleExpectation: String, Codable, CaseIterable, Identifiable, Sendable {
    case current = "Use Logic’s current state"
    case on = "Cycle must be on"
    case off = "Cycle must be off"
    var id: String { rawValue }
}

struct RunConfiguration: Codable, Hashable, Sendable {
    var sessionName = "Untitled Session"
    var outputFolder: URL?
    var dryRun = false
    var cycleExpectation: CycleExpectation = .current
    var soloKeyCode: UInt16 = 1
    var bounceKeyCode: UInt16 = 11
}

enum RunStatus: String, Codable, Sendable {
    case idle, preflight, running, paused, completed, failed
}

struct PersistedRunState: Codable, Sendable {
    var id: UUID
    var sessionName: String
    var groups: [StemGroup]
    var tracks: [LogicTrack]
    var completedGroupIDs: Set<UUID>
    var outputFolder: URL
    var startedAt: Date
    var updatedAt: Date
    var firstBounceDuration: TimeInterval?
    var dryRun: Bool
    var activeGroupID: UUID? = nil
}

struct Manifest: Codable, Sendable {
    var schemaVersion = 1
    var sessionName: String
    var logicVersion: String
    var startedAt: Date
    var completedAt: Date?
    var bounceSettingsObserved: [String]
    var summingCaveat: String
    var groups: [ManifestGroup]

    struct ManifestGroup: Codable, Sendable {
        var order: Int
        var name: String
        var memberTracks: [String]
        var contributeOnlyTracks: [String]
        var filename: String
        var startedAt: Date?
        var completedAt: Date?
        var status: String
    }
}

struct PreflightResult: Identifiable, Hashable, Sendable {
    enum Severity: String, Sendable { case pass, warning, failure }
    let id = UUID()
    var title: String
    var detail: String
    var severity: Severity
}

extension String {
    var matchKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    var safeFilenameComponent: String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Stem" : cleaned
    }
}

extension StemGroup {
    func filename(at index: Int) -> String {
        String(format: "%02d_%@", index + 1, name.safeFilenameComponent)
    }
}
