import AppKit
import ApplicationServices
import Foundation

enum LogicAutomationError: LocalizedError {
    case accessibilityDenied
    case logicNotRunning
    case logicNotFrontmost
    case noMainWindow
    case noTracksFound(URL?)
    case trackUnavailable(String)
    case couldNotSelect(String)
    case soloStateUnavailable(String)
    case couldNotSetSolo(String, Bool)
    case bounceDialogTimedOut
    case bounceFormatControlMissing(String)
    case couldNotSetBounceFormat(String)
    case filenameFieldMissing
    case confirmationButtonMissing
    case unexpectedDialog(String, URL?)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: "Accessibility permission is required."
        case .logicNotRunning: "Logic Pro is not running."
        case .logicNotFrontmost: "Logic Pro must be frontmost."
        case .noMainWindow: "Logic’s main window could not be read."
        case .noTracksFound(let diagnostic):
            if let diagnostic {
                "No track headers were found. An Accessibility diagnostic was saved to \(diagnostic.path)."
            } else {
                "No track headers were found in Logic’s main window."
            }
        case .trackUnavailable(let name): "The track “\(name)” is no longer available."
        case .couldNotSelect(let name): "Could not select the track “\(name)”."
        case .soloStateUnavailable(let name): "Logic did not expose the Solo state for “\(name)”."
        case .couldNotSetSolo(let name, let enabled): "Logic did not turn Solo \(enabled ? "on" : "off") for “\(name)”."
        case .bounceDialogTimedOut: "Logic’s bounce dialog did not appear within five seconds."
        case .bounceFormatControlMissing(let control): "Logic’s bounce dialog did not expose the \(control) control."
        case .couldNotSetBounceFormat(let detail): "Could not configure Logic for WAV output: \(detail)."
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
    private var configuredBounceSettings: [String] = []

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
        let windows = currentWindows()
        guard let window = projectWindow(in: windows) ?? standardWindow(in: windows),
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
        let currentApplication = NSRunningApplication.current
        NSApplication.shared.yieldActivation(to: application)
        application.activate(from: currentApplication, options: [.activateAllWindows])
        let systemWideElement = AXUIElementCreateSystemWide()
        let logicElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            logicElement
        )
        if let bundleURL = application.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The other activation requests can still complete the handoff.
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            try Task.checkCancellation()
            if isLogicFrontmost { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LogicAutomationError.logicNotFrontmost
    }

    func discoverTracks() throws -> [LogicTrack] {
        guard isTrusted else { throw LogicAutomationError.accessibilityDenied }
        guard let application = runningApplication else { throw LogicAutomationError.logicNotRunning }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = copyArray(appElement, kAXWindowsAttribute)
        guard !windows.isEmpty else {
            throw LogicAutomationError.noMainWindow
        }
        guard let window = projectWindow(in: windows) ?? standardWindow(in: windows) else {
            throw LogicAutomationError.noTracksFound(writeAccessibilityDiagnostic(for: windows))
        }

        let elements = descendants(of: window, maxDepth: 16, limit: 30_000)

        var occurrenceCounts: [String: Int] = [:]
        var seenHeaders = Set<CFHashCode>()
        var tracks: [LogicTrack] = []
        cachedTrackElements.removeAll()

        for header in elements where isTrackHeader(header) {
            guard seenHeaders.insert(CFHash(header)).inserted,
                  let name = trackName(from: header),
                  !name.isEmpty else { continue }
            appendTrack(
                named: name,
                header: header,
                occurrenceCounts: &occurrenceCounts,
                tracks: &tracks
            )
        }

        if tracks.isEmpty {
            for soloControl in elements where isSoloControl(soloControl) {
                guard let header = trackHeaderAncestor(for: soloControl),
                      seenHeaders.insert(CFHash(header)).inserted,
                      let name = trackName(from: header),
                      !name.isEmpty else { continue }
                appendTrack(
                    named: name,
                    header: header,
                    occurrenceCounts: &occurrenceCounts,
                    tracks: &tracks
                )
            }
        }

        guard !tracks.isEmpty else {
            throw LogicAutomationError.noTracksFound(writeAccessibilityDiagnostic(for: windows))
        }
        return tracks
    }

    func selectTrack(_ track: LogicTrack) throws {
        guard let element = cachedTrackElements[track.discoveryKey] else {
            throw LogicAutomationError.trackUnavailable(track.name)
        }

        if let parent = copyElement(element, kAXParentAttribute) {
            _ = AXUIElementSetAttributeValue(
                parent,
                kAXSelectedChildrenAttribute as CFString,
                [] as CFArray
            )
            if AXUIElementSetAttributeValue(
                parent,
                kAXSelectedChildrenAttribute as CFString,
                [element] as CFArray
            ) == .success,
               isOnlySelectedTrack(element, in: parent) {
                return
            }
        }

        let focusedResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if focusedResult == .success,
           let parent = copyElement(element, kAXParentAttribute),
           isOnlySelectedTrack(element, in: parent) { return }

        let selectedResult = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        guard selectedResult == .success,
              let parent = copyElement(element, kAXParentAttribute),
              isOnlySelectedTrack(element, in: parent) else {
            throw LogicAutomationError.couldNotSelect(track.name)
        }
    }

    func isTrackSoloed(_ track: LogicTrack) throws -> Bool {
        guard let header = cachedTrackElements[track.discoveryKey] else {
            throw LogicAutomationError.trackUnavailable(track.name)
        }
        guard let soloControl = descendants(of: header, maxDepth: 2, limit: 80).first(where: isSoloControl),
              let enabled = boolValue(soloControl, kAXValueAttribute) else {
            throw LogicAutomationError.soloStateUnavailable(track.name)
        }
        return enabled
    }

    func waitForSoloState(_ enabled: Bool, for track: LogicTrack, timeout: Duration = .seconds(1)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if try isTrackSoloed(track) == enabled { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LogicAutomationError.couldNotSetSolo(track.name, enabled)
    }

    func observedBounceSettings() -> [String] {
        if !configuredBounceSettings.isEmpty { return configuredBounceSettings }
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
        results.append(.init(
            title: "Output format",
            detail: "Real exports use uncompressed WAV only. StemBouncer verifies the named Logic controls before each bounce.",
            severity: .pass
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

        do {
            try await configureWAVBounce(in: firstDialog)
        } catch {
            await cancel(dialog: firstDialog)
            throw error
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

    private func configureWAVBounce(in dialog: AXUIElement) async throws {
        guard let destinationTable = bounceDestinationTable(in: dialog) else {
            throw LogicAutomationError.bounceFormatControlMissing("Destination table")
        }

        let rows = descendants(of: destinationTable, maxDepth: 4, limit: 500).filter {
            stringValue($0, kAXRoleAttribute) == (kAXRowRole as String)
        }
        guard let uncompressedRow = rows.first(where: {
            hasExactLabel("Uncompressed", in: $0, maxDepth: 3)
        }), let uncompressedCheckbox = destinationCheckbox(in: uncompressedRow) else {
            throw LogicAutomationError.bounceFormatControlMissing("Uncompressed destination")
        }

        try await setCheckbox(uncompressedCheckbox, enabled: true, named: "Uncompressed")
        for row in rows where CFHash(row) != CFHash(uncompressedRow) {
            guard let checkbox = destinationCheckbox(in: row) else { continue }
            let destinationName = firstSemanticLabel(in: row, excluding: ["enable"]) ?? "other destination"
            try await setCheckbox(checkbox, enabled: false, named: destinationName)
        }

        guard let fileTypePopup = uncompressedFileTypePopUp(in: dialog) else {
            throw LogicAutomationError.bounceFormatControlMissing("File Type")
        }
        try await selectPopUpValue("WAVE", in: fileTypePopup)

        guard boolValue(uncompressedCheckbox, kAXValueAttribute) == true,
              popUpValue(fileTypePopup, matches: "WAVE") else {
            throw LogicAutomationError.couldNotSetBounceFormat("Logic did not retain Uncompressed WAV")
        }
        configuredBounceSettings = ["Destination: Uncompressed", "File Type: WAVE (.wav)"]
    }

    private func bounceDestinationTable(in dialog: AXUIElement) -> AXUIElement? {
        descendants(of: dialog, maxDepth: 10, limit: 3_000).first { element in
            guard stringValue(element, kAXRoleAttribute) == (kAXTableRole as String) else { return false }
            return descendants(of: element, maxDepth: 4, limit: 500).contains { row in
                stringValue(row, kAXRoleAttribute) == (kAXRowRole as String)
                    && hasExactLabel("Uncompressed", in: row, maxDepth: 3)
                    && destinationCheckbox(in: row) != nil
            }
        }
    }

    private func destinationCheckbox(in row: AXUIElement) -> AXUIElement? {
        let checkboxes = descendants(of: row, maxDepth: 3, limit: 80).filter {
            stringValue($0, kAXRoleAttribute) == (kAXCheckBoxRole as String)
        }
        return checkboxes.first {
            stringValue($0, kAXIdentifierAttribute)?.matchKey == "enable"
        } ?? (checkboxes.count == 1 ? checkboxes[0] : nil)
    }

    private func setCheckbox(_ checkbox: AXUIElement, enabled: Bool, named name: String) async throws {
        if boolValue(checkbox, kAXValueAttribute) == enabled { return }
        guard AXUIElementPerformAction(checkbox, kAXPressAction as CFString) == .success else {
            throw LogicAutomationError.couldNotSetBounceFormat("the \(name) destination could not be changed")
        }
        guard try await waitForValue(of: checkbox, toEqual: enabled, timeout: .seconds(2)) else {
            throw LogicAutomationError.couldNotSetBounceFormat("the \(name) destination did not update")
        }
    }

    private func uncompressedFileTypePopUp(in dialog: AXUIElement) -> AXUIElement? {
        return descendants(of: dialog, maxDepth: 10, limit: 3_000).first { element in
            guard stringValue(element, kAXRoleAttribute) == (kAXPopUpButtonRole as String) else { return false }
            return [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                .compactMap { stringValue(element, $0) }
                .contains(where: Self.isUncompressedFileTypeValue)
        }
    }

    nonisolated static func isUncompressedFileTypeValue(_ value: String) -> Bool {
        ["aiff", "wave", "wav", "caf"].contains(normalizedAXLabel(value))
    }

    private func selectPopUpValue(_ value: String, in popUp: AXUIElement) async throws {
        if popUpValue(popUp, matches: value) { return }
        guard try await waitUntilEnabled(popUp, timeout: .seconds(2)) else {
            throw LogicAutomationError.couldNotSetBounceFormat("File Type remained disabled")
        }

        let setResult = AXUIElementSetAttributeValue(popUp, kAXValueAttribute as CFString, value as CFString)
        if setResult == .success,
           try await waitForPopUpValue(popUp, value: value, timeout: .milliseconds(300)) {
            return
        }

        guard AXUIElementPerformAction(popUp, kAXPressAction as CFString) == .success,
              let menuItem = try await waitForMenuItem(named: value, timeout: .seconds(2)),
              AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success,
              try await waitForPopUpValue(popUp, value: value, timeout: .seconds(2)) else {
            throw LogicAutomationError.couldNotSetBounceFormat("File Type could not be set to \(value)")
        }
    }

    private func waitForMenuItem(named name: String, timeout: Duration) async throws -> AXUIElement? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let appElement,
               let item = descendants(of: appElement, maxDepth: 14, limit: 50_000).first(where: {
                   stringValue($0, kAXRoleAttribute) == (kAXMenuItemRole as String)
                       && hasExactLabel(name, in: $0, maxDepth: 0)
               }) {
                return item
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func waitForValue(of element: AXUIElement, toEqual expected: Bool, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if boolValue(element, kAXValueAttribute) == expected { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitUntilEnabled(_ element: AXUIElement, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if boolValue(element, kAXEnabledAttribute) != false { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForPopUpValue(_ popUp: AXUIElement, value: String, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if popUpValue(popUp, matches: value) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func popUpValue(_ popUp: AXUIElement, matches expected: String) -> Bool {
        [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { stringValue(popUp, $0) }
            .contains { Self.axLabel($0, matches: expected) }
    }

    private func hasExactLabel(_ expected: String, in element: AXUIElement, maxDepth: Int) -> Bool {
        descendants(of: element, maxDepth: maxDepth, limit: 120).contains { candidate in
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
                .compactMap { stringValue(candidate, $0) }
                .contains { Self.axLabel($0, matches: expected) }
        }
    }

    private func firstSemanticLabel(in element: AXUIElement, excluding excluded: Set<String>) -> String? {
        descendants(of: element, maxDepth: 3, limit: 120)
            .flatMap { candidate in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { stringValue(candidate, $0) }
            }
            .first { label in
                let key = Self.normalizedAXLabel(label)
                return !key.isEmpty && !excluded.contains(key)
            }
    }

    nonisolated static func axLabel(_ label: String, matches expected: String) -> Bool {
        normalizedAXLabel(label) == normalizedAXLabel(expected)
    }

    nonisolated private static func normalizedAXLabel(_ label: String) -> String {
        label.matchKey.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private func cancel(dialog: AXUIElement) async {
        let cancelButton = descendants(of: dialog, maxDepth: 8, limit: 2_000).first { element in
            stringValue(element, kAXRoleAttribute) == (kAXButtonRole as String)
                && hasExactLabel("Cancel", in: element, maxDepth: 0)
        }
        guard let cancelButton,
              AXUIElementPerformAction(cancelButton, kAXPressAction as CFString) == .success else { return }

        let dialogHash = CFHash(dialog)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if !currentWindowsAndSheets().contains(where: { CFHash($0) == dialogHash }) { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
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

    func cancelOpenBounceDialogs() async {
        if let goToWindow = element(withIdentifier: "GoToWindow", in: currentWindowsAndSheets()),
           let closeButton = element(withIdentifier: "CloseButton", in: [goToWindow]) {
            _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            await waitUntilElementDisappears(goToWindow, timeout: .seconds(2))
        }

        for dialog in currentWindowsAndSheets() where filenameField(in: dialog) != nil || windowTitle(dialog).matchKey.contains("bounce") {
            await cancel(dialog: dialog)
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

    private func currentWindowsAndSheets() -> [AXUIElement] {
        let windows = currentWindows()
        return windows + windows.flatMap { copyArray($0, "AXSheets") }
    }

    private func element(withIdentifier identifier: String, in roots: [AXUIElement]) -> AXUIElement? {
        roots.lazy
            .flatMap { self.descendants(of: $0, maxDepth: 10, limit: 3_000) }
            .first {
                stringValue($0, kAXIdentifierAttribute)?.matchKey == identifier.matchKey
            }
    }

    private func waitForElement(withIdentifier identifier: String, timeout: Duration) async throws -> AXUIElement? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let element = element(withIdentifier: identifier, in: currentWindowsAndSheets()) { return element }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func waitUntilElementDisappears(_ element: AXUIElement, timeout: Duration) async {
        let elementHash = CFHash(element)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let isPresent = currentWindowsAndSheets()
                .flatMap { descendants(of: $0, maxDepth: 10, limit: 3_000) }
                .contains { CFHash($0) == elementHash }
            if !isPresent { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
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
            let windows = currentWindowsAndSheets()
            if let window = windows.first(where: { !baseline.contains(CFHash($0)) && filenameField(in: $0) != nil }) { return window }
            if let window = windows.first(where: { filenameField(in: $0) != nil }) { return window }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func filenameField(in window: AXUIElement) -> AXUIElement? {
        descendants(of: window, maxDepth: 8, limit: 2_000).first { element in
            guard stringValue(element, kAXRoleAttribute) == (kAXTextFieldRole as String) else { return false }
            return Self.isSaveFilenameField(
                identifier: stringValue(element, kAXIdentifierAttribute),
                label: searchableText(element)
            )
        }
    }

    nonisolated static func isSaveFilenameField(identifier: String?, label: String) -> Bool {
        identifier?.matchKey == "saveasnametextfield"
            || label.matchKey.contains("save as")
            || label.matchKey.contains("filename")
    }

    private func setFilename(_ filename: String, in field: AXUIElement) throws {
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, filename as CFString) == .success else {
            throw LogicAutomationError.filenameFieldMissing
        }
    }

    private func navigateSavePanel(to folder: URL, keySender: KeySender) async throws {
        keySender.send(keyCode: 5, modifiers: [.maskCommand, .maskShift])
        guard let pathField = try await waitForElement(
            withIdentifier: "PathTextField",
            timeout: .seconds(2)
        ), AXUIElementSetAttributeValue(
            pathField,
            kAXValueAttribute as CFString,
            folder.path as CFString
        ) == .success else {
            throw LogicAutomationError.unexpectedDialog("Go to Folder", captureDiagnosticScreenshot())
        }
        let navigationFieldHash = CFHash(pathField)
        keySender.send(keyCode: 36)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            try Task.checkCancellation()
            let stillPresent = currentWindowsAndSheets()
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
        if let nameField = descendants(of: element, maxDepth: 2, limit: 40).first(where: isTrackNameField) {
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                if let value = stringValue(nameField, attribute), let name = normalizedTrackName(from: value) {
                    return name
                }
            }
        }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let value = stringValue(element, attribute) else { continue }
            if attribute == kAXDescriptionAttribute,
               let name = Self.trackName(inHeaderDescription: value) {
                return name
            }
            if let name = normalizedTrackName(from: value) { return name }
        }
        let children = descendants(of: element, maxDepth: 4, limit: 160)
        let nameRoles = [kAXTextFieldRole as String, kAXStaticTextRole as String]
        for child in children where nameRoles.contains(stringValue(child, kAXRoleAttribute) ?? "") {
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let value = stringValue(child, attribute), let name = normalizedTrackName(from: value) { return name }
            }
        }
        return nil
    }

    private func trackHeaderAncestor(for soloControl: AXUIElement) -> AXUIElement? {
        var current = soloControl
        for _ in 0..<9 {
            guard let parent = copyElement(current, kAXParentAttribute) else { return nil }
            current = parent
            if isTrackHeader(parent) { return parent }
            let nearbySoloControls = descendants(of: parent, maxDepth: 4, limit: 300).filter(isSoloControl)
            if nearbySoloControls.count == 1, trackName(from: parent) != nil { return parent }
        }
        return nil
    }

    private func projectWindow(in windows: [AXUIElement]) -> AXUIElement? {
        windows.first { window in
            descendants(of: window, maxDepth: 12, limit: 20_000).contains(where: isTrackHeader)
        }
    }

    private func standardWindow(in windows: [AXUIElement]) -> AXUIElement? {
        windows.first {
            stringValue($0, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String)
        }
    }

    private func isTrackHeader(_ element: AXUIElement) -> Bool {
        guard let role = stringValue(element, kAXRoleAttribute),
              Self.isTrackHeaderRole(role),
              stringValue(element, kAXHelpAttribute)?.matchKey.hasPrefix("track header") == true else {
            return false
        }
        let children = copyArray(element, kAXChildrenAttribute)
        return children.contains(where: isSoloControl) && children.contains(where: isTrackNameField)
    }

    private func isTrackNameField(_ element: AXUIElement) -> Bool {
        guard stringValue(element, kAXRoleAttribute) == (kAXTextFieldRole as String) else { return false }
        return stringValue(element, kAXHelpAttribute)?.matchKey.hasPrefix("name field") == true
    }

    private func isTrackSelected(_ element: AXUIElement) -> Bool {
        if boolValue(element, kAXSelectedAttribute) == true { return true }
        return copyArray(element, kAXChildrenAttribute).contains { child in
            stringValue(child, kAXRoleAttribute) == (kAXRadioButtonRole as String)
                && stringValue(child, kAXDescriptionAttribute)?.matchKey == "has focus"
                && boolValue(child, kAXValueAttribute) == true
        }
    }

    private func isOnlySelectedTrack(_ element: AXUIElement, in parent: AXUIElement) -> Bool {
        let selectedChildren = copyArray(parent, kAXSelectedChildrenAttribute)
        if !selectedChildren.isEmpty {
            return selectedChildren.count == 1 && CFHash(selectedChildren[0]) == CFHash(element)
        }
        let selectedHeaders = copyArray(parent, kAXChildrenAttribute)
            .filter(isTrackHeader)
            .filter(isTrackSelected)
        return selectedHeaders.count == 1 && CFHash(selectedHeaders[0]) == CFHash(element)
    }

    nonisolated static func isTrackHeaderRole(_ role: String) -> Bool {
        role == (kAXLayoutItemRole as String) || role == (kAXGroupRole as String)
    }

    nonisolated static func trackName(inHeaderDescription description: String) -> String? {
        let pairs: [(Character, Character)] = [("“", "”"), ("\"", "\"")]
        for (openingQuote, closingQuote) in pairs {
            guard let openingIndex = description.firstIndex(of: openingQuote) else { continue }
            let remainder = description[description.index(after: openingIndex)...]
            guard let closingIndex = remainder.lastIndex(of: closingQuote) else { continue }
            let name = remainder[..<closingIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private func appendTrack(
        named name: String,
        header: AXUIElement,
        occurrenceCounts: inout [String: Int],
        tracks: inout [LogicTrack]
    ) {
        let ordinal = occurrenceCounts[name.matchKey, default: 0]
        occurrenceCounts[name.matchKey] = ordinal + 1
        let stackName = parentStackName(of: header, excluding: name)
        let track = LogicTrack(name: name, stackName: stackName, ordinal: ordinal)
        cachedTrackElements[track.discoveryKey] = header
        tracks.append(track)
    }

    private func parentStackName(of element: AXUIElement, excluding trackName: String) -> String? {
        var current = element
        for _ in 0..<4 {
            guard let parent = copyElement(current, kAXParentAttribute) else { return nil }
            current = parent
            if let title = stringValue(parent, kAXTitleAttribute),
               let name = normalizedTrackName(from: title), name != trackName { return name }
        }
        return nil
    }

    private func isSoloControl(_ element: AXUIElement) -> Bool {
        let role = stringValue(element, kAXRoleAttribute)
        guard role == (kAXButtonRole as String) || role == (kAXCheckBoxRole as String) else { return false }
        let label = allSearchableText(element)
        return label == "solo"
            || label.hasPrefix("solo ")
            || label.hasSuffix(" solo")
            || label.contains(" solo button")
            || label.contains("solo_button")
    }

    private func normalizedTrackName(from rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.matchKey
        if lowercased.hasPrefix("track header:") || lowercased.hasPrefix("track header,") {
            value = String(value.dropFirst("track header".count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let key = value.matchKey
        guard !key.isEmpty, key.count <= 160, key.rangeOfCharacter(from: .letters) != nil else { return nil }
        let excluded = [
            "solo", "mute", "record enable", "input monitoring", "volume", "pan",
            "track header", "tracks", "track list", "automation", "read", "off",
            "hide", "freeze", "protect", "channel strip", "arrangement"
        ]
        guard !excluded.contains(key),
              !key.hasSuffix(" button"),
              !key.hasSuffix(" checkbox") else { return nil }
        return value
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

    private func allSearchableText(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute, kAXRoleDescriptionAttribute]
            .compactMap { stringValue(element, $0) }
            .joined(separator: " ")
            .matchKey
    }

    private func writeAccessibilityDiagnostic(for windows: [AXUIElement]) -> URL? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "StemBouncer/Diagnostics", directoryHint: .isDirectory)
        let url = directory.appending(path: "latest-logic-ax.txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var lines = [
                "StemBouncer Logic Accessibility Diagnostic",
                "Logic version: \(logicVersion)",
                "Session: \(currentSessionName ?? "Unknown")",
                "Windows: \(windows.count)",
                "Generated: \(Date.now.formatted(.iso8601))",
                ""
            ]
            var remaining = 30_000
            for (index, window) in windows.enumerated() where remaining > 0 {
                lines.append("Window \(index + 1)")
                let before = lines.count
                appendDiagnosticLines(for: window, depth: 0, remaining: remaining, lines: &lines)
                remaining -= lines.count - before
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func appendDiagnosticLines(
        for element: AXUIElement,
        depth: Int,
        remaining: Int,
        lines: inout [String]
    ) {
        guard remaining > 0 else { return }
        let attributes = [
            "role=\(stringValue(element, kAXRoleAttribute) ?? "")",
            "subrole=\(stringValue(element, kAXSubroleAttribute) ?? "")",
            "identifier=\(stringValue(element, kAXIdentifierAttribute) ?? "")",
            "title=\(stringValue(element, kAXTitleAttribute) ?? "")",
            "description=\(stringValue(element, kAXDescriptionAttribute) ?? "")",
            "help=\(stringValue(element, kAXHelpAttribute) ?? "")",
            "value=\(stringValue(element, kAXValueAttribute) ?? "")"
        ]
        lines.append("\(String(repeating: "  ", count: depth))\(attributes.joined(separator: " | "))")
        var remainingChildren = remaining - 1
        for child in copyArray(element, kAXChildrenAttribute) where remainingChildren > 0 {
            let before = lines.count
            appendDiagnosticLines(for: child, depth: depth + 1, remaining: remainingChildren, lines: &lines)
            remainingChildren -= lines.count - before
        }
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
