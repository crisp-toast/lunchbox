import CoreGraphics

/// Every command a key can trigger. Each has a default binding the user can change.
public enum Command: String, CaseIterable, Codable, Sendable {
    case focusLeft, focusRight, focusUp, focusDown
    case moveLeft, moveRight, moveUp, moveDown
    case grow, shrink, resize, focusMode, tidy, close
    case workspace1, workspace2, workspace3, workspace4, workspace5, workspace6, workspace7, workspace8, workspace9
    case moveToWorkspace1, moveToWorkspace2, moveToWorkspace3, moveToWorkspace4, moveToWorkspace5, moveToWorkspace6,
         moveToWorkspace7, moveToWorkspace8, moveToWorkspace9, hide
    case summon, cheatSheet

    /// LunchboxWM starts with three Workspaces; you can add more, up to nine (⌘1 to ⌘9).
    public static let defaultWorkspaces = 3
    public static let maxWorkspaces = 9

    /// Go to Workspace `space` (counting from 0).
    public static func goTo(_ space: Int) -> Command { Command(rawValue: "workspace\(space + 1)")! }
    /// Move the window to Workspace `space` (counting from 0).
    public static func moveTo(_ space: Int) -> Command { Command(rawValue: "moveToWorkspace\(space + 1)")! }

    /// The Workspace (counting from 0) a go-to or move-to command is for.
    public var workspace: Int? {
        for prefix in ["moveToWorkspace", "workspace"] where rawValue.hasPrefix(prefix) {
            return Int(rawValue.dropFirst(prefix.count)).map { $0 - 1 }
        }
        return nil
    }

    var movesWindow: Bool { rawValue.hasPrefix("moveToWorkspace") }

    /// Whether the command does anything with `spaces` Workspaces: ⌘4 is the app's own until
    /// there's a Workspace 4.
    public func isActive(spaces: Int) -> Bool { workspace.map { $0 < spaces } ?? true }

    public var action: KeyAction {
        if let space = workspace { return movesWindow ? .sendToSpace(space) : .switchSpace(space) }
        switch self {
        case .focusLeft: return .focus(.left)
        case .focusRight: return .focus(.right)
        case .focusUp: return .focus(.up)
        case .focusDown: return .focus(.down)
        case .moveLeft: return .move(.left)
        case .moveRight: return .move(.right)
        case .moveUp: return .move(.up)
        case .moveDown: return .move(.down)
        case .grow: return .grow
        case .shrink: return .shrink
        case .resize: return .resizeMode(true)
        case .focusMode: return .spotlight
        case .tidy: return .normalize
        case .hide: return .hide
        case .close: return .close
        case .summon: return .launcher
        case .cheatSheet: return .help
        default: fatalError("a Workspace command without a number: \(rawValue)")
        }
    }

    public var group: String {
        if workspace != nil { return "Workspaces" }
        switch self {
        case .summon: return "Summon"
        case .cheatSheet: return "Cheat Sheet"
        default: return "Windows"
        }
    }

    public var title: String {
        if let space = workspace {
            return movesWindow ? "Move the window to Workspace \(space + 1) and go with it" : "Go to Workspace \(space + 1)"
        }
        switch self {
        case .focusLeft: return "Focus the window to the left"
        case .focusRight: return "Focus the window to the right"
        case .focusUp: return "Focus the window above"
        case .focusDown: return "Focus the window below"
        case .moveLeft: return "Move the window left (out of a stack, or past its neighbor)"
        case .moveRight: return "Move the window right (out of a stack, or past its neighbor)"
        case .moveUp: return "Move the window up in its stack"
        case .moveDown: return "Move the window down in its stack"
        case .grow: return "Give the window more space"
        case .shrink: return "Give the window less space"
        case .resize: return "Resize: then the arrows (or your focus keys) push the window's edges"
        case .focusMode: return "Focus: this window centered, the rest on the Shelf"
        case .tidy: return "Tidy: even out every window in this Workspace"
        case .hide: return "Hide: put the window out of sight, still open (Summon brings it back)"
        case .close: return "Close the window"
        case .summon: return "Summon: open an app, window or website"
        case .cheatSheet: return "Open this Cheat Sheet"
        default: return rawValue
        }
    }

    /// Words people might search for. Generous on purpose.
    public var keywords: [String] {
        let focus = ["focus", "select", "switch window", "jump", "go to window", "navigate", "next window",
                     "previous window", "activate", "highlight", "change window", "move focus", "arrow", "halo"]
        let move = ["move", "swap", "rearrange", "reorder", "drag", "push", "place", "position", "snap",
                    "stack", "tile", "shuffle", "relocate", "arrow"]
        let workspace = ["workspace", "desktop", "virtual desktop", "space", "spaces", "screen", "room", "page", "switch"]
        let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        if let space = self.workspace {
            let n = space + 1
            return movesWindow
                ? workspace + ["move to", "send", "throw", "carry", "take window", "move window", "workspace \(n)", "\(n)", numbers[space]]
                : workspace + ["go to", "switch to", "show", "workspace \(n)", "\(n)", numbers[space]]
        }
        switch self {
        case .focusLeft: return focus + ["left", "west"]
        case .focusRight: return focus + ["right", "east"]
        case .focusUp: return focus + ["up", "above", "top", "north"]
        case .focusDown: return focus + ["down", "below", "bottom", "south"]
        case .moveLeft: return move + ["left"]
        case .moveRight: return move + ["right"]
        case .moveUp: return move + ["up", "above", "top", "raise"]
        case .moveDown: return move + ["down", "below", "bottom", "lower"]
        case .grow: return ["grow", "bigger", "larger", "enlarge", "expand", "increase", "resize", "size", "wider",
                            "taller", "more space", "zoom in", "plus", "make bigger", "widen"]
        case .shrink: return ["shrink", "smaller", "reduce", "decrease", "resize", "size", "narrower", "less space",
                              "zoom out", "minus", "make smaller", "narrow"]
        case .resize: return ["resize", "resize mode", "width", "height", "wider", "narrower", "taller", "shorter",
                              "stretch", "tall", "wide", "dimensions", "vertical", "horizontal", "size"]
        case .focusMode: return ["focus", "focus mode", "focus view", "spotlight", "center", "centre", "isolate",
                                 "concentrate", "zen", "distraction free", "maximize", "maximise", "fullscreen",
                                 "full screen", "one window", "solo", "single", "presentation", "shelf",
                                 "stage manager", "zoom", "fill"]
        case .tidy: return ["tidy", "normalize", "normalise", "balance", "even", "equal", "reset", "clean up",
                            "cleanup", "organize", "organise", "arrange", "fix layout", "default size", "50/50",
                            "fifty", "align", "restore", "evenly", "auto arrange"]
        case .hide: return ["hide", "stash", "minimize", "minimise", "put away", "tuck", "park", "send away",
                             "declutter", "out of the way", "later", "hidden", "off screen"]
        case .close: return ["close", "quit window", "kill", "dismiss", "exit window", "remove", "delete window",
                             "get rid", "shut"]
        case .summon: return ["summon", "launcher", "launch", "open app", "open", "search", "find", "spotlight search",
                              "alfred", "raycast", "run", "start", "application", "app", "web",
                              "google", "website", "url", "new window", "quick open", "command bar", "palette",
                              "find window", "window title", "switch window", "witch", "contexts"]
        case .cheatSheet: return ["cheat sheet", "help", "shortcuts", "keys", "keyboard", "list", "reference",
                                  "commands", "hotkeys", "keybindings", "key bindings", "guide", "how", "what", "manual", "?"]
        default: return []
        }
    }
}

/// A key combination. The key is either a fixed key code or "Workspace key n", the n-th
/// of the three keys earlier versions had you choose during setup (still honored in a
/// shortcut you changed back then).
public struct KeyBinding: Codable, Hashable, Sendable {
    public enum Key: Codable, Hashable, Sendable {
        case code(Int64)
        case workspaceKey(Int)
    }

    public var key: Key
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool
    /// Only the left ⌘ key counts, so right ⌘ keeps its usual job.
    public var leftCommandOnly: Bool
    /// ⇧ tapped on its own and then the key, with nothing typed in between
    /// (so typing a capital and a space quickly never triggers it).
    public var shiftTap: Bool

    public init(_ key: Key, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false,
                leftCommandOnly: Bool = false, shiftTap: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.leftCommandOnly = leftCommandOnly
        self.shiftTap = shiftTap
    }

    /// A binding from a recorded key press.
    public init(recording code: Int64, flags: CGEventFlags) {
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)
        let control = flags.contains(.maskControl)
        let left = flags.rawValue & Shortcuts.leftCommandMask != 0
        let right = flags.rawValue & 0x10 != 0
        self.init(.code(code), command: cmd, shift: shift, option: option, control: control,
                  leftCommandOnly: cmd && left && !right,
                  shiftTap: shift && !cmd && !option && !control)
    }

    func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskCommand) == command, flags.contains(.maskShift) == shift,
              flags.contains(.maskAlternate) == option, flags.contains(.maskControl) == control else { return false }
        if command && leftCommandOnly { return flags.rawValue & Shortcuts.leftCommandMask != 0 }
        return true
    }
}

/// The user's key bindings: the defaults plus any they've changed.
public struct Keymap: Equatable, Sendable {
    public var overrides: [Command: KeyBinding]

    public init(overrides: [Command: KeyBinding] = [:]) {
        self.overrides = overrides
    }

    /// The number keys 1 to 9, for Workspaces 1 to 9.
    public static let numberKeys: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Workspaces are ⌘ and their number, and ⌘⇧ and the number carries the window there,
    /// like ⌘⇧ and an arrow moves it. Left ⌘ only, like every LunchboxWM shortcut, so right ⌘ and
    /// a number still does what it does in the app in front (a browser's tabs, say), and right
    /// ⌘⇧3, ⌘⇧4 and ⌘⇧5 still take screenshots; and only for Workspaces you have, so with three,
    /// ⌘⇧4 and ⌘⇧5 are the Mac's on either side.
    public static let defaults: [Command: KeyBinding] = {
        let leftCmd = { (code: Int64) in KeyBinding(.code(code), command: true, leftCommandOnly: true) }
        let leftCmdShift = { (code: Int64) in KeyBinding(.code(code), command: true, shift: true, leftCommandOnly: true) }
        var map: [Command: KeyBinding] = [
            .focusLeft: leftCmd(123), .focusRight: leftCmd(124), .focusDown: leftCmd(125), .focusUp: leftCmd(126),
            .moveLeft: leftCmdShift(123), .moveRight: leftCmdShift(124), .moveDown: leftCmdShift(125), .moveUp: leftCmdShift(126),
            .grow: leftCmdShift(24), .shrink: leftCmdShift(27), .resize: leftCmdShift(15), .focusMode: leftCmdShift(3), .tidy: leftCmdShift(29),
            .hide: leftCmdShift(4), .close: leftCmdShift(51), .cheatSheet: leftCmdShift(49),
            .summon: KeyBinding(.code(49), shift: true, shiftTap: true),
        ]
        for (space, code) in numberKeys.enumerated() {
            map[.goTo(space)] = leftCmd(code)
            map[.moveTo(space)] = leftCmdShift(code)
        }
        return map
    }()

    public func binding(for command: Command) -> KeyBinding {
        overrides[command] ?? Self.defaults[command]!
    }

    public func isCustom(_ command: Command) -> Bool {
        overrides[command].map { $0 != Self.defaults[command] } ?? false
    }

    static func code(of binding: KeyBinding, workspaceKeys: [Int64]) -> Int64? {
        switch binding.key {
        case .code(let c): return c
        case .workspaceKey(let i): return workspaceKeys.indices.contains(i) ? workspaceKeys[i] : nil
        }
    }

    /// The command a key press triggers, for normal (held-modifier) bindings, with `spaces`
    /// Workspaces.
    public func command(for code: Int64, flags: CGEventFlags, workspaceKeys: [Int64],
                        spaces: Int = Command.maxWorkspaces) -> Command? {
        Command.allCases.first { c in
            guard c.isActive(spaces: spaces) else { return false }
            let b = binding(for: c)
            return !b.shiftTap && Self.code(of: b, workspaceKeys: workspaceKeys) == code && b.matchesModifiers(flags)
        }
    }

    /// The command for "⇧ tapped, then this key".
    public func shiftTapCommand(for code: Int64, workspaceKeys: [Int64]) -> Command? {
        Command.allCases.first { c in
            let b = binding(for: c)
            return b.shiftTap && Self.code(of: b, workspaceKeys: workspaceKeys) == code
        }
    }

    /// Another command already using the same keys, if any, with `spaces` Workspaces.
    public func conflict(with binding: KeyBinding, excluding command: Command, workspaceKeys: [Int64],
                         spaces: Int = Command.maxWorkspaces) -> Command? {
        let code = Self.code(of: binding, workspaceKeys: workspaceKeys)
        return Command.allCases.first { c in
            guard c != command, c.isActive(spaces: spaces) else { return false }
            let other = self.binding(for: c)
            return Self.code(of: other, workspaceKeys: workspaceKeys) == code
                && other.command == binding.command && other.shift == binding.shift
                && other.option == binding.option && other.control == binding.control
        }
    }

    /// Keycaps for a binding, e.g. ["Left ⌘", "⇧", "←"] or ["⇧", "then", "Space"].
    public static func keycaps(for binding: KeyBinding, workspaceKeys: [Int64]) -> [String] {
        var caps: [String] = []
        if binding.control { caps.append("⌃") }
        if binding.option { caps.append("⌥") }
        if binding.shift { caps.append("⇧") }
        if binding.command { caps.append(binding.leftCommandOnly ? "Left ⌘" : "⌘") }
        if binding.shiftTap { caps.append("then") }
        switch binding.key {
        case .code(let c): caps.append(KeyNames.name(c))
        case .workspaceKey(let i):
            if workspaceKeys.indices.contains(i) { caps.append(KeyNames.name(workspaceKeys[i])) }
            else { caps.append("Workspace key \(i + 1)") }
        }
        return caps
    }
}

/// Names for key codes on a US layout.
public enum KeyNames {
    static let names: [Int64: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "+", 27: "−", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        36: "↩", 76: "Enter", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Del",
        123: "←", 124: "→", 125: "↓", 126: "↑", 116: "Page Up", 121: "Page Down", 115: "Home", 119: "End", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        69: "Keypad +", 78: "Keypad −", 67: "Keypad ×", 75: "Keypad ÷", 65: "Keypad .", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
        88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
    ]

    public static func name(_ code: Int64) -> String { names[code] ?? "Key \(code)" }

    /// Keys that make good Workspace keys: the navigation cluster and function
    /// keys, never keys that type or edit text.
    public static func isGoodWorkspaceKey(_ code: Int64) -> Bool {
        (96...122).contains(code) || [64, 79, 80, 90].contains(code)
    }
}

extension Keymap {
    /// Ready-made sets of keys for moving around: the arrows (the defaults), or Vim's H J K L,
    /// as tiling window managers usually offer. Either way left ⌘ moves focus and left ⌘⇧ moves the
    /// window; with Vim keys, Hide moves from ⌘⇧H to ⌘⇧M, since ⌘⇧H moves left.
    public enum Preset: String, CaseIterable, Sendable {
        case arrows, vim

        public var title: String {
            switch self {
            case .arrows: return "Arrow keys"
            case .vim: return "Vim keys (H J K L)"
            }
        }

        /// The commands a preset sets; it leaves every other shortcut alone.
        public static let commands: [Command] = [.focusLeft, .focusDown, .focusUp, .focusRight,
                                                  .moveLeft, .moveDown, .moveUp, .moveRight, .hide]

        public var bindings: [Command: KeyBinding] {
            switch self {
            case .arrows:
                return Dictionary(uniqueKeysWithValues: Self.commands.map { ($0, Keymap.defaults[$0]!) })
            case .vim:
                let leftCmd = { (code: Int64) in KeyBinding(.code(code), command: true, leftCommandOnly: true) }
                let leftCmdShift = { (code: Int64) in KeyBinding(.code(code), command: true, shift: true, leftCommandOnly: true) }
                let h: Int64 = 4, j: Int64 = 38, k: Int64 = 40, l: Int64 = 37, m: Int64 = 46
                return [
                    .focusLeft: leftCmd(h), .focusDown: leftCmd(j), .focusUp: leftCmd(k), .focusRight: leftCmd(l),
                    .moveLeft: leftCmdShift(h), .moveDown: leftCmdShift(j), .moveUp: leftCmdShift(k), .moveRight: leftCmdShift(l),
                    .hide: leftCmdShift(m),
                ]
            }
        }
    }

    /// The preset these shortcuts follow, or nil once one of its keys was changed by hand.
    public var preset: Preset? {
        Preset.allCases.first { p in Preset.commands.allSatisfy { binding(for: $0) == p.bindings[$0] } }
    }

    /// These shortcuts with a preset's keys. Anything else changed by hand stays, unless it used one
    /// of the preset's keys: that goes back to its default.
    public func applying(_ preset: Preset) -> Keymap {
        var map = self
        let keys = preset.bindings
        for (command, binding) in keys { map.overrides[command] = binding == Self.defaults[command] ? nil : binding }
        for command in Command.allCases where keys[command] == nil {
            let mine = map.binding(for: command)
            if keys.values.contains(where: { $0.key == mine.key && $0.command == mine.command && $0.shift == mine.shift
                && $0.option == mine.option && $0.control == mine.control }) {
                map.overrides[command] = nil
            }
        }
        return map
    }
}
