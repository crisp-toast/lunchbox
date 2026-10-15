import CoreGraphics

/// Every command a key can trigger. Each has a default binding the user can change.
public enum Command: String, CaseIterable, Codable, Sendable {
    case focusLeft, focusRight, focusUp, focusDown
    case moveLeft, moveRight, moveUp, moveDown
    case grow, shrink, focusMode, tidy, close
    case workspace1, workspace2, workspace3
    case moveToWorkspace1, moveToWorkspace2, moveToWorkspace3, stash
    case summon, cheatSheet

    public var action: KeyAction {
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
        case .focusMode: return .spotlight
        case .tidy: return .normalize
        case .stash: return .hide
        case .close: return .close
        case .workspace1: return .switchSpace(0)
        case .workspace2: return .switchSpace(1)
        case .workspace3: return .switchSpace(2)
        case .moveToWorkspace1: return .sendToSpace(0)
        case .moveToWorkspace2: return .sendToSpace(1)
        case .moveToWorkspace3: return .sendToSpace(2)
        case .summon: return .launcher
        case .cheatSheet: return .help
        }
    }

    public var group: String {
        switch self {
        case .workspace1, .workspace2, .workspace3, .moveToWorkspace1, .moveToWorkspace2, .moveToWorkspace3, .stash:
            return "Workspaces"
        case .summon: return "Summon"
        case .cheatSheet: return "Cheat Sheet"
        default: return "Windows"
        }
    }

    public var title: String {
        switch self {
        case .focusLeft: return "Focus the window to the left"
        case .focusRight: return "Focus the window to the right"
        case .focusUp: return "Focus the window above"
        case .focusDown: return "Focus the window below"
        case .moveLeft: return "Move the window left (stacks, then passes)"
        case .moveRight: return "Move the window right (stacks, then passes)"
        case .moveUp: return "Move the window up in its stack"
        case .moveDown: return "Move the window down in its stack"
        case .grow: return "Give the window more space"
        case .shrink: return "Give the window less space"
        case .focusMode: return "Focus: this window centered, the rest on the Shelf"
        case .tidy: return "Tidy: even out every window in this Workspace"
        case .stash: return "Stash: send the window to Workspace 3 and stay here"
        case .close: return "Close the window"
        case .workspace1: return "Go to Workspace 1"
        case .workspace2: return "Go to Workspace 2"
        case .workspace3: return "Go to Workspace 3"
        case .moveToWorkspace1: return "Move the window to Workspace 1 and go with it"
        case .moveToWorkspace2: return "Move the window to Workspace 2 and go with it"
        case .moveToWorkspace3: return "Move the window to Workspace 3 and go with it"
        case .summon: return "Summon: open an app, file or website"
        case .cheatSheet: return "Open this Cheat Sheet"
        }
    }

    /// Words people might search for. Generous on purpose.
    public var keywords: [String] {
        let focus = ["focus", "select", "switch window", "jump", "go to window", "navigate", "next window",
                     "previous window", "activate", "highlight", "change window", "move focus", "arrow", "halo"]
        let move = ["move", "swap", "rearrange", "reorder", "drag", "push", "place", "position", "snap",
                    "stack", "tile", "shuffle", "relocate", "arrow"]
        let workspace = ["workspace", "desktop", "virtual desktop", "space", "spaces", "screen", "room", "page", "switch"]
        let numbers = ["one", "two", "three"]
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
        case .focusMode: return ["focus", "focus mode", "focus view", "spotlight", "center", "centre", "isolate",
                                 "concentrate", "zen", "distraction free", "maximize", "maximise", "fullscreen",
                                 "full screen", "one window", "solo", "single", "presentation", "shelf",
                                 "stage manager", "zoom", "fill"]
        case .tidy: return ["tidy", "normalize", "normalise", "balance", "even", "equal", "reset", "clean up",
                            "cleanup", "organize", "organise", "arrange", "fix layout", "default size", "50/50",
                            "fifty", "align", "restore", "evenly", "auto arrange"]
        case .stash: return ["stash", "hide", "minimize", "minimise", "put away", "tuck", "park", "send away",
                             "declutter", "out of the way", "workspace 3", "later", "hidden"] + workspace
        case .close: return ["close", "quit window", "kill", "dismiss", "exit window", "remove", "delete window",
                             "get rid", "shut"]
        case .workspace1, .workspace2, .workspace3:
            let n = ["workspace1": 1, "workspace2": 2, "workspace3": 3][rawValue]!
            return workspace + ["go to", "switch to", "show", "workspace \(n)", "\(n)", numbers[n - 1], "page up", "page down", "end"]
        case .moveToWorkspace1, .moveToWorkspace2, .moveToWorkspace3:
            let n = ["moveToWorkspace1": 1, "moveToWorkspace2": 2, "moveToWorkspace3": 3][rawValue]!
            return workspace + ["move to", "send", "throw", "carry", "take window", "move window", "workspace \(n)", "\(n)", numbers[n - 1]]
        case .summon: return ["summon", "launcher", "launch", "open app", "open", "search", "find", "spotlight search",
                              "alfred", "raycast", "run", "start", "application", "app", "file", "folder", "web",
                              "google", "website", "url", "new window", "quick open", "command bar", "palette"]
        case .cheatSheet: return ["cheat sheet", "help", "shortcuts", "keys", "keyboard", "list", "reference",
                                  "commands", "hotkeys", "keybindings", "key bindings", "guide", "how", "what", "manual", "?"]
        }
    }
}

/// A key combination. The key is either a fixed key code or "Workspace key n",
/// the n-th of the three keys chosen during setup.
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

    public static let defaults: [Command: KeyBinding] = {
        let leftCmd = { (code: Int64) in KeyBinding(.code(code), command: true, leftCommandOnly: true) }
        let leftCmdShift = { (code: Int64) in KeyBinding(.code(code), command: true, shift: true, leftCommandOnly: true) }
        return [
            .focusLeft: leftCmd(123), .focusRight: leftCmd(124), .focusDown: leftCmd(125), .focusUp: leftCmd(126),
            .moveLeft: leftCmdShift(123), .moveRight: leftCmdShift(124), .moveDown: leftCmdShift(125), .moveUp: leftCmdShift(126),
            .grow: leftCmdShift(24), .shrink: leftCmdShift(27), .focusMode: leftCmdShift(3), .tidy: leftCmdShift(29),
            .stash: leftCmdShift(4), .close: leftCmdShift(51), .cheatSheet: leftCmdShift(49),
            .summon: KeyBinding(.code(49), shift: true, shiftTap: true),
            .workspace1: KeyBinding(.workspaceKey(0), command: true),
            .workspace2: KeyBinding(.workspaceKey(1), command: true),
            .workspace3: KeyBinding(.workspaceKey(2), command: true),
            .moveToWorkspace1: KeyBinding(.workspaceKey(0), command: true, shift: true),
            .moveToWorkspace2: KeyBinding(.workspaceKey(1), command: true, shift: true),
            .moveToWorkspace3: KeyBinding(.workspaceKey(2), command: true, shift: true),
        ]
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

    /// The command a key press triggers, for normal (held-modifier) bindings.
    public func command(for code: Int64, flags: CGEventFlags, workspaceKeys: [Int64]) -> Command? {
        Command.allCases.first { c in
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

    /// Another command already using the same keys, if any.
    public func conflict(with binding: KeyBinding, excluding command: Command, workspaceKeys: [Int64]) -> Command? {
        let code = Self.code(of: binding, workspaceKeys: workspaceKeys)
        return Command.allCases.first { c in
            guard c != command else { return false }
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
