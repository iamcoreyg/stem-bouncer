import Foundation

enum FileCompletionError: LocalizedError {
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let filename): "Timed out waiting for \(filename)"
        }
    }
}

struct FileCompletionWatcher {
    let pollInterval: Duration
    let stableInterval: Duration

    init(pollInterval: Duration = .milliseconds(500), stableInterval: Duration = .seconds(2)) {
        self.pollInterval = pollInterval
        self.stableInterval = stableInterval
    }

    func waitForFile(
        prefix: String,
        fileExtension: String? = nil,
        in folder: URL,
        timeout: Duration,
        onPoll: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws -> URL {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var candidate: URL?
        var lastSize: UInt64?
        var stableSince: ContinuousClock.Instant?

        while clock.now < deadline {
            try Task.checkCancellation()
            try await onPoll?()
            let match = existingFile(prefix: prefix, fileExtension: fileExtension, in: folder)

            if match != candidate {
                candidate = match
                lastSize = nil
                stableSince = nil
            }

            if let match,
               let values = try? match.resourceValues(forKeys: [.fileSizeKey]),
               let byteCount = values.fileSize {
                let size = UInt64(byteCount)
                if size > 0, size == lastSize {
                    stableSince = stableSince ?? clock.now
                    if let stableSince, stableSince.duration(to: clock.now) >= stableInterval {
                        return match
                    }
                } else {
                    lastSize = size
                    stableSince = nil
                }
            }

            try await Task.sleep(for: pollInterval)
        }

        throw FileCompletionError.timedOut(prefix)
    }

    func existingFile(prefix: String, fileExtension: String? = nil, in folder: URL) -> URL? {
        if let fileExtension {
            let expectedFile = folder
                .appendingPathComponent(prefix)
                .appendingPathExtension(fileExtension)
            return FileManager.default.fileExists(atPath: expectedFile.path) ? expectedFile : nil
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { file in
                guard file.deletingPathExtension().lastPathComponent == prefix else { return false }
                return true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    func preserveInterruptedFile(_ file: URL) throws -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        let fileExtension = file.pathExtension
        let folder = file.deletingLastPathComponent()

        for attempt in 1...999 {
            var candidate = folder.appendingPathComponent(
                "\(stem) - Interrupted \(String(format: "%02d", attempt))"
            )
            if !fileExtension.isEmpty {
                candidate.appendPathExtension(fileExtension)
            }
            guard !FileManager.default.fileExists(atPath: candidate.path) else { continue }
            try FileManager.default.moveItem(at: file, to: candidate)
            return candidate
        }

        throw CocoaError(.fileWriteFileExists)
    }
}
