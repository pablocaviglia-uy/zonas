import AppKit
import ApplicationServices

/// Minimal wrapper over the Accessibility API for reading and moving another
/// application's window.
///
/// Everything in here requires the user to have granted Accessibility
/// permission. Without it the calls don't fail loudly: they return an error and
/// the app simply looks like it isn't doing anything, which is the most
/// confusing way to break.
struct AXWindow {
    let element: AXUIElement

    /// Finds the window sitting under a point on screen (CG coordinates).
    ///
    /// `AXUIElementCopyElementAtPosition` returns the **most specific** element
    /// under the cursor: a button, a cell, a text field. To reach the window you
    /// have to walk up the parent chain until you find the one whose role is
    /// window.
    ///
    /// The hop limit keeps us from hanging on broken hierarchies, and they are
    /// out there: some apps return cyclic parents.
    static func at(cgPoint point: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,
                                               Float(point.x),
                                               Float(point.y),
                                               &found) == .success,
              var current = found else { return nil }

        for _ in 0 ..< 12 {
            if current.role == kAXWindowRole { return AXWindow(element: current) }
            guard let parent = current.parent else { break }
            current = parent
        }
        return nil
    }

    var frame: CGRect? {
        guard let origin = element.position, let size = element.size else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Places the window into a rectangle (CG coordinates).
    ///
    /// Position and size are two separate attributes and the order matters. If
    /// the window is flush against an edge, setting the size first can make the
    /// system move it on its own and the result ends up offset. That's why it
    /// gets positioned, resized, and positioned again: the second pass absorbs
    /// that rearrangement.
    ///
    /// Not checking the result is deliberate for now: some apps enforce a
    /// minimum size and report success having applied something else. Detecting
    /// that properly is a separate job.
    func setFrame(_ rect: CGRect) {
        element.setPosition(rect.origin)
        element.setSize(rect.size)
        element.setPosition(rect.origin)
    }
}

extension AXUIElement {

    fileprivate func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    fileprivate var role: String? {
        attribute(kAXRoleAttribute) as? String
    }

    fileprivate var parent: AXUIElement? {
        guard let value = attribute(kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    fileprivate var position: CGPoint? {
        guard let value = attribute(kAXPositionAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    fileprivate var size: CGSize? {
        guard let value = attribute(kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    fileprivate func setPosition(_ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }

    fileprivate func setSize(_ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value)
    }
}
