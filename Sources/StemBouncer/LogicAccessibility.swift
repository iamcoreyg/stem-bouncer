import AppKit
import ApplicationServices
import Foundation

enum LogicAutomationError: LocalizedError {
    case accessibilityDenied
    case logicNotRunning
    case logicNotFrontmost
    case noMainWindow
    case noTracksFound
    case trackUnavailable(String)
    case couldNotSelect(String)
    case bounceDialogTimedOut
    case filenameFieldMissing
    case confirmationButtonMissing
    case unexpectedDialog(String, URL?)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: "Accessibility permission is required."
        case .logicNotRunning: "Logic Pro is not running."
        case .logicNotFrontmost: "Logic Pro must be frontmost."
        case .noMainWindow: "Logic’s main window could not be read."
        case .noTracksFound: "No track headers were found in Logic’s main window."
        case .trackUnavailable(let name): "The track “\(name)” is no longer available."
        case .couldNotSelect(let name): "Could not select the track “\(name)”."
        case .bounceDialogTimedOut: "Logic’s bounce dialog did not appear within five seconds."
        case .filenameFieldMissing: "The bounce save dialog appeared, but its filename field was not found."
        case .confirmationButtonMissing: "The expected Bounce or Save button was not found."
        case .unexpectedDialog(let title, let screenshot):
            if let screenshot { "Unexpected Logic dialog “\(title)”. Screenshot: \(screenshot.path)" }
            else { "Unexpected Logic dialog “\(title)”." }
        }
    }
}

@MainActor
final class LogicAccessibility {
    nonisolated static let bundleIdentifier = "com.apple.logic10"

    private var cachedTrackElements: [String: AXUIElement] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first
    }

    var isLogicFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleIdentifier }

    var logicVersion: String {
        guard let url = runningApplication?.bundleURL,
              let bundle = Bundle(url: url) else { return "Unknown" }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var currentSessionName: String? {
        guard let window = currentWindows().first,
              let title = stringValue(window, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title.replacingOccurrences(of: " — Logic Pro", with: "")
            .replacingOccurrences(of: " - Logic Pro", with: "")
    }

    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func activateLogic() async throws {
        guard isTrusted else { throw LogicAutomationError.accessibilityDenied }
        guard let application = runningApplication else { throw LogicAutomationError.logicNotRunning }
        application.activate(options: [.activateAllWindows])
        try await Task.sleep(for: .milliseconds(100))
        guard isLogicFrontmost else { throw LogicAutomationError.logicNotFrontmost }
    }

    func discoverTracks() throws -> [LogicTrack] {
        guard isTrusted else { throw LogicAutomationError.accessibilityDenied }
        guard let application = runningApplication else { throw LogicAutomationError.logicNotRunning }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = copyArray(appElement, kAXWindowsAttribute).first else {
            throw LogicAutomationError.noMainWindow
        }

        let elements = descendants(of: window, maxDepth: 12, limit: 12_000)
        let candidates = elements.filter { element in
            let role = stringValue(element, kAXRoleAttribute)
            guard role == (kAXRowRole as String) || role == (kAXGroupRole as String) else { return false }
            let nearbySoloControls = descendants(of: element, maxDepth: 3, limit: 100).filter { isSoloControl($0) }
            return nearbySoloControls.count == 1
        }

        var occurrenceCounts: [String: Int] = [:]
        var seenSoloControls = Set<CFHashCode>()
        var tracks: [LogicTrack] = []
        cachedTrackElements.removeAll()

        for candidate in candidates {
            guard let soloControl = descendants(of: candidate, maxDepth: 3, limit: 100).first(where: { isSoloControl($0) }),
                  seenSoloControls.insert(CFHash(soloControl)).inserted,
                  let name = trackName(from: candidate),
                  !name.isEmpty else { continue }
            let ordinal = occurrenceCounts[name.matchKey, default: 0]
            occurrenceCounts[name.matchKey] = ordinal + 1
            let stackName = parentStackName(of: candidate, excluding: name)
            let track = LogicTrack(name: name, stackName: stackName, ordinal: ordinal)
            cachedTrackElements[track.discoveryKey] = candidate
            tracks.append(track)
        }

        guard !tracks.isEmpty else { throw LogicAutomationError.noTracksFound }
        return tracks
    }

    func selectTrack(_ track: LogicTrack) throws {
        guard let element = cachedTrackElements[track.discoveryKey] else {
            throw LogicAutomationError.trackUnavailable(track.name)
        }

        let selectedResult = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        if selectedResult == .success { return }
        let focusedResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard focusedResult == .success else { throw LogicAutomationError.couldNotSelect(track.name) }
    }

    func observedBounceSettings() -> [String] {
        guard let app = appElement else { return [] }
        let text = copyArray(app, kAXWindowsAttribute)
            .flatMap { descendants(of: $0, maxDepth: 8, limit: 3_000) }
            .compactMap { element -> String? in
                let role = stringValue(element, kAXRoleAttribute)
                guard role == (kAXStaticTextRole as String) || role == (kAXPopUpButtonRole as String) else { return nil }
                return stringValue(element, kAXValueAttribute) ?? stringValue(element, kAXTitleAttribute)
            }
        return Array(text.filter { !$0.isEmpty }.prefix(40))
    }

    func preflight(configuration: RunConfiguration) -> [PreflightResult] {
        var results: [PreflightResult] = []
        results.append(.init(
            title: "Accessibility permission",
            detail: isTrusted ? "StemBouncer can control Logic." : "Grant access in System Settings → Privacy & Security → Accessibility.",
            severity: isTrusted ? .pass : .failure
        ))
        results.append(.init(
            title: "Logic Pro",
            detail: runningApplication == nil ? "Open the session in Logic Pro." : (isLogicFrontmost ? "Logic is open and frontmost." : "Logic is open and will be brought frontmost when the run begins."),
            severity: runningApplication == nil ? .failure : (isLogicFrontmost ? .pass : .warning)
        ))

        if let folder = configuration.outputFolder {
            let writable = FileManager.default.isWritableFile(atPath: folder.path)
            results.append(.init(
                title: "Output folder",
                detail: writable ? folder.path : "The selected folder is not writable.",
                severity: writable ? .pass : .failure
            ))
        } else {
            results.append(.init(title: "Output folder", detail: "Choose where stems should be written.", severity: .failure))
        }

        guard let app = appElement else { return results }
        let elements = copyArray(app, kAXWindowsAttribute).flatMap { descendants(of: $0, maxDepth: 12, limit: 12_000) }

        let activeSoloSafety = elements.contains { element in
            let label = searchableText(element)
            return (label.contains("solo safe") || label.contains("solo lock")) && boolValue(element, kAXValueAttribute) == true
        }
        results.append(.init(
            title: "Solo safety",
            detail: activeSoloSafety ? "A solo-safe or solo-locked channel appears active." : "No exposed solo-safe or solo-locked channel was found. Confirm manually if Logic does not expose this state.",
            severity: activeSoloSafety ? .failure : .warning
        ))

        let metronome = state(forControlContaining: ["metronome", "click"], in: elements)
        results.append(.init(
            title: "Metronome",
            detail: metronome == true ? "Turn the metronome off before starting." : (metronome == false ? "Metronome is off." : "Logic did not expose metronome state; confirm it is off."),
            severity: metronome == true ? .failure : (metronome == false ? .pass : .warning)
        ))

        if configuration.cycleExpectation != .current {
            let cycle = state(forControlContaining: ["cycle"], in: elements)
            let expected = configuration.cycleExpectation == .on
            results.append(.init(
                title: "Cycle mode",
                detail: cycle == nil ? "Logic did not expose cycle state; confirm it manually." : (cycle == expected ? "Cycle state matches this run." : "Cycle state does not match this run."),
                severity: cycle == nil ? .warning : (cycle == expected ? .pass : .failure)
            ))
        }
        return results
    }

    func openBounceAndSubmit(filename: String, outputFolder: URL, keySender: KeySender) async throws {
        let baselineWindows = Set(currentWindows().map(CFHash))
        keySender.send(keyCode: keySender.bounceKeyCode, modifiers: .maskCommand)
        guard let firstDialog = try await waitForNewWindow(excluding: baselineWindows, timeout: .seconds(5)) else {
            throw LogicAutomationError.bounceDialogTimedOut
        }

        if filenameField(in: firstDialog) != nil {
            try await navigateSavePanel(to: outputFolder, keySender: keySender)
            guard let currentDialog = try await waitForWindowWithFilenameField(excluding: [], timeout: .seconds(2)),
                  let currentField = filenameField(in: currentDialog) else { throw LogicAutomationError.filenameFieldMissing }
            try setFilename(filename, in: currentField)
            try pressDefaultButton(in: currentDialog)
            return
        }

        let labels = windowLabels(firstDialog)
        guard labels.contains(where: { $0.matchKey.contains("bounce") }) else {
            throw LogicAutomationError.unexpectedDialog(windowTitle(firstDialog), captureDiagnosticScreenshot())
        }

        try pressDefaultButton(in: firstDialog)
        let secondBaseline = Set(currentWindows().map(CFHash))
        guard let saveDialog = try await waitForWindowWithFilenameField(excluding: secondBaseline, timeout: .seconds(5)),
              let field = filenameField(in: saveDialog) else {
            throw LogicAutomationError.filenameFieldMissing
        }
        _ = field
        try await navigateSavePanel(to: outputFolder, keySender: keySender)
        guard let currentDialog = try await waitForWindowWithFilenameField(excluding: [], timeout: .seconds(2)),
              let currentField = filenameField(in: currentDialog) else { throw LogicAutomationError.filenameFieldMissing }
        try setFilename(filename, in: currentField)
        try pressDefaultButton(in: currentDialog)
    }

    func captureDiagnosticScreenshot() -> URL? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemBouncer/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("unexpected-dialog-\(Int(Date().timeIntervalSince1970)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? url : nil
        } catch {
            return nil
        }
    }

    func assertNoBlockingDialog() throws {
        let blockingTerms = ["overwrite", "replace", "not found", "missing file", "error"]
        let dialogs = currentWindows().flatMap { window in
            descendants(of: window, maxDepth: 5, limit: 1_000).filter {
                let role = stringValue($0, kAXRoleAttribute)
                return role == (kAXSheetRole as String) || role == "AXDialog"
            }
        }
        if let dialog = dialogs.first(where: { dialog in
            let text = windowLabels(dialog).joined(separator: " ").matchKey
            return blockingTerms.contains(where: text.contains)
        }) {
            throw LogicAutomationError.unexpectedDialog(windowTitle(dialog), captureDiagnosticScreenshot())
        }
    }

    private var appElement: AXUIElement? {
        guard let application = runningApplication else { return nil }
        return AXUIElementCreateApplication(application.processIdentifier)
    }

    private func currentWindows() -> [AXUIElement] {
        guard let appElement else { return [] }
        return copyArray(appElement, kAXWindowsAttribute)
    }

    private func waitForNewWindow(excluding baseline: Set<CFHashCode>, timeout: Duration) async throws -> AXUIElement? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let window = currentWindows().first(where: { !baseline.contains(CFHash($0)) }) { return window }
            if let sheet = currentWindows().flatMap({ copyArray($0, "AXSheets") }).first { return sheet }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func waitForWindowWithFilenameField(excluding baseline: Set<CFHashCode>, timeout: Duration) async throws -> AXUIElement? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            let windows = currentWindows() + currentWindows().flatMap { copyArray($0, "AXSheets") }
            if let window = windows.first(where: { !baseline.contains(CFHash($0)) && filenameField(in: $0) != nil }) { return window }
            if let window = windows.first(where: { filenameField(in: $0) != nil }) { return window }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func filenameField(in window: AXUIElement) -> AXUIElement? {
        descendants(of: window, maxDepth: 8, limit: 2_000).first { element in
            guard stringValue(element, kAXRoleAttribute) == (kAXTextFieldRole as String) else { return false }
            let label = searchableText(element)
            return label.contains("save as") || label.contains("filename") || label.contains("name")
        } ?? descendants(of: window, maxDepth: 8, limit: 2_000).first {
            stringValue($0, kAXRoleAttribute) == (kAXTextFieldRole as String)
        }
    }

    private func setFilename(_ filename: String, in field: AXUIElement) throws {
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, filename as CFString) == .success else {
            throw LogicAutomationError.filenameFieldMissing
        }
    }

    private func navigateSavePanel(to folder: URL, keySender: KeySender) async throws {
        keySender.send(keyCode: 5, modifiers: [.maskCommand, .maskShift])
        try await Task.sleep(for: .milliseconds(180))
        let allElements = currentWindows().flatMap { descendants(of: $0, maxDepth: 10, limit: 3_000) }
        let focusedField = allElements.first {
            stringValue($0, kAXRoleAttribute) == (kAXTextFieldRole as String) && boolValue($0, kAXFocusedAttribute) == true
        }
        guard let focusedField,
              AXUIElementSetAttributeValue(focusedField, kAXValueAttribute as CFString, folder.path as CFString) == .success else {
            throw LogicAutomationError.unexpectedDialog("Go to Folder", captureDiagnosticScreenshot())
        }
        let navigationFieldHash = CFHash(focusedField)
        keySender.send(keyCode: 36)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let stillPresent = currentWindows()
                .flatMap { descendants(of: $0, maxDepth: 10, limit: 3_000) }
                .contains { CFHash($0) == navigationFieldHash }
            if !stillPresent { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LogicAutomationError.unexpectedDialog("Go to Folder did not close", captureDiagnosticScreenshot())
    }

    private func pressDefaultButton(in window: AXUIElement) throws {
        let buttons = descendants(of: window, maxDepth: 8, limit: 2_000).filter {
            stringValue($0, kAXRoleAttribute) == (kAXButtonRole as String)
        }
        let preferred = copyElement(window, kAXDefaultButtonAttribute)
            ?? buttons.first { button in
                let label = searchableText(button)
                return ["bounce", "save", "ok"].contains(where: label.contains)
            }
        guard let button = preferred,
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw LogicAutomationError.confirmationButtonMissing
        }
    }

    private func trackName(from element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let value = stringValue(element, attribute), isPlausibleTrackName(value) { return value }
        }
        let children = descendants(of: element, maxDepth: 3, limit: 80)
        for child in children where stringValue(child, kAXRoleAttribute) == (kAXStaticTextRole as String) {
            if let value = stringValue(child, kAXValueAttribute) ?? stringValue(child, kAXTitleAttribute),
               isPlausibleTrackName(value) { return value }
        }
        return nil
    }

    private func parentStackName(of element: AXUIElement, excluding trackName: String) -> String? {
        var current = element
        for _ in 0..<4 {
            guard let parent = copyElement(current, kAXParentAttribute) else { return nil }
            current = parent
            if let title = stringValue(parent, kAXTitleAttribute),
               isPlausibleTrackName(title), title != trackName { return title }
        }
        return nil
    }

    private func isSoloControl(_ element: AXUIElement) -> Bool {
        guard stringValue(element, kAXRoleAttribute) == (kAXButtonRole as String) else { return false }
        let label = searchableText(element)
        return label == "solo" || label.hasPrefix("solo ") || label.hasSuffix(" solo")
    }

    private func isPlausibleTrackName(_ value: String) -> Bool {
        let key = value.matchKey
        guard !key.isEmpty, key.count <= 160 else { return false }
        return !["solo", "mute", "record enable", "input monitoring", "volume", "pan"].contains(key)
    }

    private func state(forControlContaining terms: [String], in elements: [AXUIElement]) -> Bool? {
        for element in elements {
            let label = searchableText(element)
            if terms.contains(where: label.contains), let state = boolValue(element, kAXValueAttribute) { return state }
        }
        return nil
    }

    private func windowLabels(_ window: AXUIElement) -> [String] {
        descendants(of: window, maxDepth: 6, limit: 1_000).flatMap { element in
            [stringValue(element, kAXTitleAttribute), stringValue(element, kAXDescriptionAttribute), stringValue(element, kAXValueAttribute)].compactMap { $0 }
        }
    }

    private func windowTitle(_ window: AXUIElement) -> String {
        stringValue(window, kAXTitleAttribute) ?? "Untitled dialog"
    }

    private func searchableText(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { stringValue(element, $0) }
            .joined(separator: " ")
            .matchKey
    }

    private func descendants(of root: AXUIElement, maxDepth: Int, limit: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = Set<CFHashCode>()
        while !queue.isEmpty, result.count < limit {
            let (element, depth) = queue.removeFirst()
            guard seen.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            guard depth < maxDepth else { continue }
            for child in copyArray(element, kAXChildrenAttribute) { queue.append((child, depth + 1)) }
        }
        return result
    }

    private func copyArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
