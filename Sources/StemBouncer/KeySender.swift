import AppKit
import ApplicationServices
import Foundation

@MainActor
final class KeySender {
    var soloKeyCode: CGKeyCode = 1
    var bounceKeyCode: CGKeyCode = 11
    private let targetBundleIdentifier: String
    private let frontmostBundleIdentifier: () -> String?

    init(
        targetBundleIdentifier: String = LogicAccessibility.bundleIdentifier,
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
    }

    func validateTargetIsFrontmost() throws {
        guard frontmostBundleIdentifier() == targetBundleIdentifier else {
            throw LogicAutomationError.logicNotFrontmost
        }
    }

    func sendSolo() throws {
        try send(keyCode: soloKeyCode)
    }

    func send(keyCode: CGKeyCode, modifiers: CGEventFlags = []) throws {
        try validateTargetIsFrontmost()
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw LogicAutomationError.keyEventUnavailable
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
