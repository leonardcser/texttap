import Cocoa
import ApplicationServices

final class TextInserter: @unchecked Sendable {
    // Delay between keystrokes in microseconds (1000 = 1ms)
    private let keystrokeDelay: useconds_t = 1000

    // Roles that might support Accessibility text insertion
    private let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String
    ]

    func insertIncremental(_ text: String) {
        guard !text.isEmpty else { return }

        // Only attempt Accessibility API for known text input roles
        if let (element, role) = getFocusedElement(), textInputRoles.contains(role) {
            if insertTextViaAccessibility(element: element, text: text) {
                return
            }
        }

        // Use typing for everything else - works universally including terminals
        typeText(text)
    }

    private func getFocusedElement() -> (AXUIElement, String)? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return nil
        }

        let axElement = element as! AXUIElement

        var role: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXRoleAttribute as CFString,
            &role
        )

        guard roleResult == .success, let roleString = role as? String else {
            return nil
        }

        return (axElement, roleString)
    }

    private func getElementValue(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        guard result == .success, let stringValue = value as? String else {
            return nil
        }
        return stringValue
    }

    private func insertTextViaAccessibility(element: AXUIElement, text: String) -> Bool {
        // Get current value to verify change afterwards
        let valueBefore = getElementValue(element)

        // Try to set the selected text (replaces selection)
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        guard setResult == .success else {
            return false
        }

        // Verify the text actually changed - some apps return success but don't insert
        let valueAfter = getElementValue(element)

        // If we can read values and they're the same, the insert failed
        if let before = valueBefore, let after = valueAfter {
            if before == after {
                return false
            }
        }

        return true
    }

    private func typeText(_ text: String) {
        // Type character by character for maximum compatibility with terminals
        // This approach is used by Hammerspoon, TextExpander, and Keyboard Maestro
        let source = CGEventSource(stateID: .privateState)

        for char in text {
            let utf16Chars = Array(char.utf16)

            // Create key down event with the unicode character
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }

            // Create key up event
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }

            // Small delay between keystrokes for reliability
            usleep(keystrokeDelay)
        }
    }
}
