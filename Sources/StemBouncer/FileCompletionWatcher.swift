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
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { file in
                guard file.deletingPathExtension().lastPathComponent == prefix else { return false }
                guard let fileExtension else { return true }
                return file.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}
