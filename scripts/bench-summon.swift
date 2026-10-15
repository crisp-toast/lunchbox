// Times opening a new, tiled window of a running app (Terminal) two ways:
//   Spotlight: ⌘Space, type "terminal", Return, then ⌘N once Terminal is in front
//   Summon:    tap ⇧ then Space, type "terminal", ⇧Return (a new window, here)
// Both type at the same human pace and pause the same "glance" before each Return,
// and every run stops the clock when the new window has settled into its tile.
//
//   swiftc -O -o build/bench-summon scripts/bench-summon.swift && build/bench-summon [runs]
//
// It types real keystrokes, so it refuses to start unless the Mac has been idle for
// 10 minutes and only the spoof display (Tyler can't see) is on. Prints JSON.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let charDelay = 0.15   // about 80 words a minute
let glance = 0.30      // looking at the results (or at the app coming forward) before the next key
let query = "terminal"
let runs = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 8 : 8

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

// MARK: Safety

func idleSeconds() -> Double {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    defer { IOObjectRelease(entry) }
    guard let value = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return 0 }
    return value.doubleValue / 1e9
}

func onlySpoofDisplay() -> Bool {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.count == 1 && CGDisplayVendorNumber(ids[0]) == 9366 && CGDisplayModelNumber(ids[0]) == 60689
}

guard AXIsProcessTrusted() else { fail("needs Accessibility permission") }
if CommandLine.arguments.contains("--force") == false {
    guard onlySpoofDisplay() else { fail("not running: a display Tyler can see is on") }
    guard idleSeconds() >= 600 else { fail("not running: the Mac was used in the last 10 minutes") }
}

// MARK: Keys

let source = CGEventSource(stateID: .hidSystemState)
let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
    "j": 38, "k": 40, "n": 45, "m": 46]

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

func tapShift() {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? .maskShift : []
        e.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

func type(_ text: String) {
    for c in text {
        key(letters[c]!)
        Thread.sleep(forTimeInterval: charDelay - 0.024)
    }
}

// MARK: Watching the screen

func onScreen(owner: String) -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }
}

func terminalPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
}

func terminalWindows() -> [CGWindowID: CGRect] {
    var out: [CGWindowID: CGRect] = [:]
    for w in onScreen(owner: "Terminal") where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let id = w[kCGWindowNumber as String] as? CGWindowID, let b = w[kCGWindowBounds as String] as? NSDictionary,
           let r = CGRect(dictionaryRepresentation: b) { out[id] = r }
    }
    return out
}

/// The app in front: Accessibility's focused app, or else NSWorkspace's (which needs the run
/// loop to turn over before it notices a change).
func frontPID() -> pid_t? {
    var app: CFTypeRef?
    if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success,
       let element = app {
        var pid: pid_t = 0
        AXUIElementGetPid(element as! AXUIElement, &pid)
        if pid > 0 { return pid }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

/// Every on-screen window above the normal level, by number and owner: Spotlight's and
/// Summon's panels, whatever their owners are called on this version of macOS.
func floating() -> [CGWindowID: String] {
    var out: [CGWindowID: String] = [:]
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        guard let id = w[kCGWindowNumber as String] as? CGWindowID, let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b), r.width > 200, r.height > 40 else { continue }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        if layer != 0 || owner == "Tessel" { out[id] = owner }
    }
    return out
}

/// Waits for a new floating window to appear (the search panel); returns its owner.
func panelAppears(besides before: [CGWindowID: String]) -> String? {
    var owner: String?
    wait(3) { owner = floating().first { before[$0.key] == nil }?.value; return owner != nil }
    return owner
}

var reasons: [String] = []
var panelOwners: [String: String] = [:]

@discardableResult
func wait(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        usleep(5_000)
    }
    return false
}

/// Waits for a Terminal window that wasn't there before, then for it to stop moving.
/// Returns when it last moved (it has settled into its tile by then).
func settledNewWindow(besides before: Set<CGWindowID>) -> (CGWindowID, Date)? {
    var id: CGWindowID?
    guard wait(8, { id = terminalWindows().keys.first { !before.contains($0) }; return id != nil }), let id else { return nil }
    var last = terminalWindows()[id]
    var lastChange = Date()
    while Date().timeIntervalSince(lastChange) < 0.35 {
        usleep(5_000)
        let now = terminalWindows()[id]
        if now != last { last = now; lastChange = Date() }
    }
    return (id, lastChange)
}

func close(_ id: CGWindowID) {
    guard let pid = terminalPID() else { return }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
    for w in (value as? [AXUIElement]) ?? [] {
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(w, &wid)
        guard wid == id else { continue }
        var button: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &button)
        if let button { AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) }
    }
}

func startFromFinder() {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    wait(2) { frontPID() == finder }
    Thread.sleep(forTimeInterval: 0.6)
}

// MARK: The two ways

func spotlight() -> Double? {
    startFromFinder()
    let before = Set(terminalWindows().keys)
    let panelsBefore = floating()
    let t0 = Date()
    key(49, .maskCommand) // ⌘Space
    guard let owner = panelAppears(besides: panelsBefore) else { reasons.append("spotlight: no panel"); key(53); return nil }
    panelOwners["spotlight"] = owner
    type(query)
    Thread.sleep(forTimeInterval: glance)
    key(36) // Return: brings Terminal forward
    guard wait(3, { frontPID() == terminalPID() }) else {
        reasons.append("spotlight: Terminal not in front (front: \(frontPID().flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? "?"))")
        key(53); return nil
    }
    Thread.sleep(forTimeInterval: glance)
    key(45, .maskCommand) // ⌘N
    guard let (id, done) = settledNewWindow(besides: before) else { reasons.append("spotlight: no new window"); return nil }
    close(id)
    return done.timeIntervalSince(t0)
}

func summon() -> Double? {
    startFromFinder()
    let before = Set(terminalWindows().keys)
    let panelsBefore = floating()
    let t0 = Date()
    tapShift()
    key(49) // Space
    guard let owner = panelAppears(besides: panelsBefore) else { reasons.append("summon: no panel"); key(53); return nil }
    panelOwners["summon"] = owner
    type(query)
    Thread.sleep(forTimeInterval: glance)
    key(36, .maskShift) // ⇧Return: a new window
    guard let (id, done) = settledNewWindow(besides: before) else { reasons.append("summon: no new window"); return nil }
    close(id)
    return done.timeIntervalSince(t0)
}

// MARK: Run

guard terminalPID() != nil else { fail("open Terminal first") }
var times: [String: [Double]] = ["spotlight": [], "summon": []]
var failures: [String: Int] = ["spotlight": 0, "summon": 0]
_ = spotlight(); _ = summon() // warm up both
for _ in 0..<runs {
    for (name, run) in [("spotlight", spotlight), ("summon", summon)] {
        if let t = run() { times[name]!.append(t) } else { failures[name]! += 1 }
        Thread.sleep(forTimeInterval: 1)
    }
}
func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? .nan : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
}
let ms = median(times["spotlight"]!), mm = median(times["summon"]!)
let result: [String: Any] = [
    "date": ISO8601DateFormatter().string(from: Date()),
    "machine": "Mac mini (M4, 16 GB)", "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "typing_seconds_per_char": charDelay, "glance_seconds": glance, "query": query,
    "spotlight_seconds": times["spotlight"]!, "summon_seconds": times["summon"]!,
    "spotlight_median": ms.isNaN ? NSNull() : ms, "summon_median": mm.isNaN ? NSNull() : mm,
    "speedup": (ms / mm).isFinite ? ms / mm : NSNull(), "failures": failures,
    "failure_reasons": reasons, "panel_owners": panelOwners,
]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
