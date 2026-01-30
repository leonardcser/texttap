import Cocoa
import ApplicationServices

class CursorTracker {
    private var timer: Timer?
    var onCursorPositionChanged: ((NSRect?) -> Void)?

    func startTracking() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let position = self?.getCursorPosition()
            self?.onCursorPositionChanged?(position)
        }
    }

    func stopTracking() {
        timer?.invalidate()
        timer = nil
    }

    func getCursorPosition() -> NSRect? {
        // Get the system-wide accessibility element
        let systemWide = AXUIElementCreateSystemWide()

        // Get the focused element
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success,
              let element = focusedElement else {
            return nil
        }

        let axElement = element as! AXUIElement

        // Try to get the selected text range first
        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        if rangeResult == .success,
           let range = selectedRange {
            // Get bounds for the selected text range
            var bounds: AnyObject?
            let boundsResult = AXUIElementCopyParameterizedAttributeValue(
                axElement,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                range,
                &bounds
            )

            if boundsResult == .success,
               let boundsValue = bounds {
                var rect = CGRect.zero
                if AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) {
                    // Convert to screen coordinates (flip Y)
                    if let screen = NSScreen.main {
                        let screenHeight = screen.frame.height
                        rect.origin.y = screenHeight - rect.origin.y - rect.height
                    }
                    return rect
                }
            }
        }

        // Fallback: try to get the element's position and size
        var position: AnyObject?
        var size: AnyObject?

        let posResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXPositionAttribute as CFString,
            &position
        )
        let sizeResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXSizeAttribute as CFString,
            &size
        )

        if posResult == .success && sizeResult == .success,
           let posValue = position as! AXValue?,
           let sizeValue = size as! AXValue? {
            var point = CGPoint.zero
            var elementSize = CGSize.zero

            AXValueGetValue(posValue, .cgPoint, &point)
            AXValueGetValue(sizeValue, .cgSize, &elementSize)

            // Return a rect at the right edge of the element (approximate cursor position)
            let cursorRect = CGRect(
                x: point.x + elementSize.width,
                y: point.y,
                width: 2,
                height: min(elementSize.height, 20)
            )

            // Convert to screen coordinates
            if let screen = NSScreen.main {
                let screenHeight = screen.frame.height
                var flippedRect = cursorRect
                flippedRect.origin.y = screenHeight - cursorRect.origin.y - cursorRect.height
                return flippedRect
            }

            return cursorRect
        }

        // Last resort: use mouse position
        let mouseLocation = NSEvent.mouseLocation
        return NSRect(x: mouseLocation.x, y: mouseLocation.y, width: 2, height: 20)
    }
}
