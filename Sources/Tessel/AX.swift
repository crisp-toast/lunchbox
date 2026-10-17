import AppKit
import ApplicationServices

/// Private but long-stable HIServices call that maps an AX window to its window-server ID.
/// Rectangle, Amethyst and AeroSpace all rely on it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Private, long-stable window-server calls for Spaces (the macOS desktops, and the
/// Space a full screen app gets from the green button). Amethyst and yabai rely on them.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

/// The Spaces the displays are showing right now.
func shownSpaces() -> Set<Int> {
    let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] ?? []
    return Set(displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int })
}

/// The Spaces a window is on. None once it's gone.
func windowSpaces(of id: CGWindowID) -> [Int] {
    CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [Int] ?? []
}

/// Whether a window is on a Space out of view: its display is showing a full screen
/// app (or another desktop). Accessibility only lists windows on the Spaces in view,
/// so these go missing from their app's list without having closed.
func isOutOfView(_ id: CGWindowID, shown: Set<Int>) -> Bool {
    let on = windowSpaces(of: id)
    return !on.isEmpty && !on.contains(where: shown.contains)
}

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

/// Whether a dialog is showing. Alerts draw in a slightly larger companion window
/// centered on theirs (room for the glass edge), and the window Accessibility names
/// never counts as on screen, so a showing window of the same app wrapped around it
/// counts too.
func isDialogShowing(_ id: CGWindowID, pid: pid_t, frame: CGRect) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
        if (info[kCGWindowNumber as String] as? CGWindowID) == id { return true }
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
        let margin = CGSize(width: bounds.width - frame.width, height: bounds.height - frame.height)
        if abs(bounds.midX - frame.midX) < 2, abs(bounds.midY - frame.midY) < 2,
           (0...200).contains(margin.width), (0...200).contains(margin.height) { return true }
    }
    return false
}

/// Whether the window server is showing a window right now: far cheaper than the
/// whole window list, so it can be asked every few milliseconds.
func isOnScreen(_ id: CGWindowID) -> Bool {
    var raw = UnsafeRawPointer(bitPattern: UInt(id))
    guard let array = CFArrayCreate(nil, &raw, 1, nil),
          let info = (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first else { return false }
    return info[kCGWindowIsOnscreen as String] as? Bool ?? false
}

/// Where each on-screen window is, by window number.
func onScreenWindowBounds() -> [CGWindowID: CGRect] {
    var out: [CGWindowID: CGRect] = [:]
    for info in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID, let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { continue }
        out[id] = rect
    }
    return out
}

/// Every window that exists, on screen or not (minimized, hidden, on another desktop).
func allWindowIDs() -> Set<CGWindowID> {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
}
