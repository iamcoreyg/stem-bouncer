import ApplicationServices
import Foundation

@MainActor
final class KeySender {
    var soloKeyCode: CGKeyCode = 1
    var bounceKeyCode: CGKeyCode = 11

    func sendSolo() {
        send(keyCode: soloKeyCode)
    }

    func send(keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
