import Cocoa
import ApplicationServices

/// Finds the text caret through Accessibility.
enum Caret {
    /// The caret's screen rectangle in AppKit coordinates. Apps that do not report the caret,
    /// such as terminals, get a point inside the bottom-left of the focused text area, where
    /// a prompt usually is. Without a focused element, the mouse pointer is used.
    static func location() -> NSRect {
        if let element = focusedElement() {
            if let caret = caretBounds(element) {
                return appKitRect(caret)
            }
            if let frame = frame(element) {
                return appKitRect(CGRect(x: frame.minX + 8, y: frame.maxY - 28, width: 2, height: 20))
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 2, height: 20)
    }

    /// Asks the frontmost app directly; some apps, such as Ghostty, do not answer the
    /// system-wide focused-element query.
    static func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
    }

    private static func caretBounds(_ element: AXUIElement) -> CGRect? {
        guard let range: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var bounds: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
        return rect
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Accessibility measures from the top-left of the primary screen; AppKit from its bottom-left.
    private static func appKitRect(_ rect: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
