import Foundation

actor PersistenceStore {
    static let shared = PersistenceStore()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var supportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("StemBouncer", isDirectory: true)
    }

    private var runURL: URL { supportDirectory.appendingPathComponent("active-run.json") }
    private var presetsURL: URL { supportDirectory.appendingPathComponent("presets.json") }

    func save(run: PersistedRunState) throws {
        try ensureDirectory()
        try encoder.encode(run).write(to: runURL, options: .atomic)
    }

    func loadRun() throws -> PersistedRunState? {
        guard FileManager.default.fileExists(atPath: runURL.path) else { return nil }
        return try decoder.decode(PersistedRunState.self, from: Data(contentsOf: runURL))
    }

    func clearRun() throws {
        guard FileManager.default.fileExists(atPath: runURL.path) else { return }
        try FileManager.default.removeItem(at: runURL)
    }

    func loadPresets() throws -> [GroupPreset] {
        guard FileManager.default.fileExists(atPath: presetsURL.path) else { return [] }
        return try decoder.decode([GroupPreset].self, from: Data(contentsOf: presetsURL))
    }

    func save(presets: [GroupPreset]) throws {
        try ensureDirectory()
        try encoder.encode(presets).write(to: presetsURL, options: .atomic)
    }

    func write(manifest: Manifest, to folder: URL) throws {
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
