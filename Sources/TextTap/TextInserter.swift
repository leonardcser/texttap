import Cocoa
import ApplicationServices

final class TextInserter: @unchecked Sendable {
    func insertIncremental(_ text: String) {
        guard !text.isEmpty else { return }

        // Try accessibility API first (handles selection replacement better)
        if insertTextViaAccessibility(text) {
            print("[TextInserter] Inserted via Accessibility API: '\(text)'")
            return
        }

        // Fall back to typing (works in terminals, replaces selection in most apps)
        print("[TextInserter] Inserting via typing: '\(text)'")
        typeText(text)
    }

    private func insertTextViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return false
        }

        let axElement = element as! AXUIElement

        // Try to set the selected text (replaces selection)
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        return setResult == .success
    }

    private func typeText(_ text: String) {
        let utf16Chars = Array(text.utf16)
        guard !utf16Chars.isEmpty else { return }

        let source = CGEventSource(stateID: .privateState)
        let chunkSize = 20

        for chunkStart in stride(from: 0, to: utf16Chars.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, utf16Chars.count)
            let chunk = Array(utf16Chars[chunkStart..<chunkEnd])

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyDown.post(tap: .cghidEventTap)
            }

            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }
}
