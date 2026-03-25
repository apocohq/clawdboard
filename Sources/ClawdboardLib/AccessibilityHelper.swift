import ApplicationServices
import Foundation

/// Utilities for finding and focusing UI elements in running applications
/// using the macOS Accessibility (AX) APIs.
public enum AccessibilityHelper {

    /// Whether the app has been granted Accessibility permissions.
    /// If `promptIfNeeded` is true, shows the system permission dialog on first call.
    public static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Search a running application's AX tree for an element whose title or value
    /// contains the given search string, and perform kAXPressAction on it.
    /// Returns true if the element was found and activated.
    @discardableResult
    public static func findAndActivateElement(
        pid: pid_t,
        titleContaining searchString: String,
        maxDepth: Int = 12
    ) -> Bool {
        let trusted = isTrusted()
        debugLog("[AX] findAndActivateElement pid=\(pid) search=\"\(searchString)\" trusted=\(trusted)")
        guard trusted else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        guard let target = findElement(root: appElement, titleContaining: searchString, maxDepth: maxDepth)
        else {
            debugLog("[AX] No element found matching \"\(searchString)\"")
            return false
        }

        let role = stringAttribute(kAXRoleAttribute as String, from: target) ?? "?"
        let value = stringAttribute(kAXValueAttribute as String, from: target) ?? "?"
        debugLog("[AX] Found match: role=\(role) value=\"\(value)\" — clicking element")

        // Use CGEvent click directly. kAXPressAction returns success on JetBrains
        // AXStaticText but is a no-op, so we skip it entirely.
        return clickElement(target)
    }

    // MARK: - Private

    /// Two-phase BFS: first locate an AXGroup whose AXDescription contains "Tool Window",
    /// then search within that group for an AXStaticText whose AXValue contains the search string.
    /// This scopes the search to the JetBrains Terminal tool window and avoids false positives.
    private static func findElement(
        root: AXUIElement,
        titleContaining searchString: String,
        maxDepth: Int
    ) -> AXUIElement? {
        // Phase 1: find all "Tool Window" groups
        let toolWindowGroups = findGroups(root: root, descContaining: "Tool Window", maxDepth: maxDepth)
        debugLog("[AX] Found \(toolWindowGroups.count) Tool Window group(s)")

        // Phase 2: search within each group for matching AXStaticText
        for group in toolWindowGroups {
            let desc = stringAttribute(kAXDescriptionAttribute as String, from: group) ?? "?"
            debugLog("[AX] Searching within group desc=\"\(desc)\"")
            if let match = findStaticText(root: group, valueContaining: searchString, maxDepth: 3) {
                return match
            }
        }

        debugLog("[AX] No matching AXStaticText found in any Tool Window group")
        return nil
    }

    /// BFS to collect AXGroup elements whose AXDescription contains the given substring.
    private static func findGroups(
        root: AXUIElement,
        descContaining search: String,
        maxDepth: Int
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0

        while index < queue.count {
            let (element, depth) = queue[index]
            index += 1

            let role = stringAttribute(kAXRoleAttribute as String, from: element)
            let desc = stringAttribute(kAXDescriptionAttribute as String, from: element)

            if role == "AXGroup", let desc = desc, desc.contains(search) {
                results.append(element)
                continue  // don't descend into matched groups — we'll search them in phase 2
            }

            guard depth < maxDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return results
    }

    /// Shallow BFS within a subtree for AXStaticText with matching AXValue.
    private static func findStaticText(
        root: AXUIElement,
        valueContaining search: String,
        maxDepth: Int
    ) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0

        while index < queue.count {
            let (element, depth) = queue[index]
            index += 1

            let role = stringAttribute(kAXRoleAttribute as String, from: element)
            let value = stringAttribute(kAXValueAttribute as String, from: element)

            if role == "AXStaticText", let value = value, value.contains(search) {
                debugLog("[AX] MATCH on AXValue=\"\(value)\"")
                return element
            }

            guard depth < maxDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    /// Simulate a mouse click at the center of an AX element's frame.
    private static func clickElement(_ element: AXUIElement) -> Bool {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            debugLog("[AX] Could not read position/size for CGEvent click")
            return false
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        let axPos = posValue as! AXValue
        // swiftlint:disable:next force_cast
        let axSize = sizeValue as! AXValue
        guard
            AXValueGetValue(axPos, .cgPoint, &position),
            AXValueGetValue(axSize, .cgSize, &size)
        else {
            debugLog("[AX] Could not extract CGPoint/CGSize from AXValue")
            return false
        }

        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        debugLog("[AX] Clicking at (\(center.x), \(center.y))")

        guard
            let mouseDown = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: center, mouseButton: .left),
            let mouseUp = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: center, mouseButton: .left)
        else {
            debugLog("[AX] Failed to create CGEvent")
            return false
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        debugLog("[AX] CGEvent click posted")
        return true
    }

    /// Read a string attribute from an AX element.
    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let str = value as? String else { return nil }
        return str
    }

    /// Read children from an AX element.
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else { return [] }
        return array
    }
}
