import Cocoa
import ApplicationServices

/// Inserts text at the cursor of the focused app.
struct TextInserter {
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole]

    /// Replaces the selection of a standard text field through Accessibility, or types the
    /// text, which works everywhere including terminals.
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        if let element = Caret.focusedElement(), Self.replaceSelection(element, with: text) { return }
        Self.type(text)
    }

    private static func replaceSelection(_ element: AXUIElement, with text: String) -> Bool {
        var role: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String, textRoles.contains(role) else { return false }
        let before = value(element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        // Some apps report success without changing anything.
        guard let before, let after = value(element) else { return true }
        return before != after
    }

    private static func value(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            let utf16 = Array(character.utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
            usleep(1000)  // Some apps drop characters typed faster
        }
    }
}
