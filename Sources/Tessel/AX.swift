import AppKit
import ApplicationServices

/// Private but long-stable HIServices call that maps an AX window to its window-server ID.
/// Rectangle, Amethyst and AeroSpace all rely on it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    static func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool { (value(attribute) as? Bool) ?? false }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        (value(attribute) as? [AXUIElement]) ?? []
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) }
    var isFullScreen: Bool { bool("AXFullScreen") }

    var isResizable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    var position: CGPoint? {
        guard let v = value(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let v = value(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &size) ? size : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, v) == .success
    }

    /// Size, then position, then size again: the second size call catches apps
    /// that clamp a window's size to the display it is currently on.
    func setFrame(_ frame: CGRect) {
        setSize(frame.size)
        setPosition(frame.origin)
        if let s = size, abs(s.width - frame.width) > 1 || abs(s.height - frame.height) > 1 {
            setSize(frame.size)
        }
    }

    func set(_ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(self, attribute as CFString, value as CFBoolean)
    }

    func raise() { AXUIElementPerformAction(self, kAXRaiseAction as CFString) }
}

/// Window-server IDs of normal windows currently on screen.
func onScreenWindowIDs() -> Set<CGWindowID> {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var ids = Set<CGWindowID>()
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
        if let n = info[kCGWindowNumber as String] as? CGWindowID { ids.insert(n) }
    }
    return ids
}
