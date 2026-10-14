import CoreGraphics
import Testing
@testable import TesselCore

let workspaceKeys: [Int64] = [116, 121, 119]

@Suite struct KeymapMatching {
    let map = Keymap()

    @Test func defaultsMatchTheOldShortcuts() {
        #expect(map.command(for: 123, flags: flags(), workspaceKeys: workspaceKeys) == .focusLeft)
        #expect(map.command(for: 124, flags: flags(shift: true), workspaceKeys: workspaceKeys) == .moveRight)
        #expect(map.command(for: 3, flags: flags(shift: true), workspaceKeys: workspaceKeys) == .focusMode)
        #expect(map.command(for: 49, flags: flags(shift: true), workspaceKeys: workspaceKeys) == .cheatSheet)
        #expect(map.command(for: 116, flags: flags(), workspaceKeys: workspaceKeys) == .workspace1)
        #expect(map.command(for: 119, flags: flags(leftCommand: false, rightCommand: true, shift: true), workspaceKeys: workspaceKeys) == .moveToWorkspace3)
        #expect(map.shiftTapCommand(for: 49, workspaceKeys: workspaceKeys) == .summon)
    }

    @Test func rightCommandAndPlainKeysPassThrough() {
        #expect(map.command(for: 123, flags: flags(leftCommand: false, rightCommand: true), workspaceKeys: workspaceKeys) == nil)
        #expect(map.command(for: 123, flags: CGEventFlags(rawValue: 0), workspaceKeys: workspaceKeys) == nil)
        #expect(map.command(for: 49, flags: flags(), workspaceKeys: workspaceKeys) == nil) // ⌘Space is Spotlight's
    }

    @Test func overridesReplaceDefaults() {
        var custom = map
        custom.overrides[.focusMode] = KeyBinding(.code(3), command: true, option: true)
        #expect(custom.command(for: 3, flags: flags(shift: true), workspaceKeys: workspaceKeys) == nil)
        var withOption = flags()
        withOption.insert(.maskAlternate)
        #expect(custom.command(for: 3, flags: withOption, workspaceKeys: workspaceKeys) == .focusMode)
        #expect(custom.isCustom(.focusMode))
        #expect(!custom.isCustom(.tidy))
    }

    @Test func conflictsAreFound() {
        let clash = KeyBinding(.code(3), command: true, shift: true, leftCommandOnly: true)
        #expect(map.conflict(with: clash, excluding: .tidy, workspaceKeys: workspaceKeys) == .focusMode)
        #expect(map.conflict(with: clash, excluding: .focusMode, workspaceKeys: workspaceKeys) == nil)
    }

    @Test func recordingAKeyPress() {
        let b = KeyBinding(recording: 17, flags: flags(shift: true))
        #expect(b.command && b.shift && b.leftCommandOnly && !b.shiftTap)
        let tap = KeyBinding(recording: 49, flags: CGEventFlags.maskShift)
        #expect(tap.shiftTap)
    }

    @Test func keycapLabels() {
        #expect(Keymap.keycaps(for: map.binding(for: .moveLeft), workspaceKeys: workspaceKeys) == ["Left ⌘", "⇧", "←"])
        #expect(Keymap.keycaps(for: map.binding(for: .summon), workspaceKeys: workspaceKeys) == ["⇧", "then", "Space"])
        #expect(Keymap.keycaps(for: map.binding(for: .workspace2), workspaceKeys: workspaceKeys) == ["⌘", "Page Down"])
        #expect(Keymap.keycaps(for: map.binding(for: .workspace2), workspaceKeys: []) == ["⌘", "Workspace key 2"])
    }

    @Test func workspaceKeyGuidance() {
        #expect(KeyNames.isGoodWorkspaceKey(116))
        #expect(KeyNames.isGoodWorkspaceKey(105)) // F13
        #expect(!KeyNames.isGoodWorkspaceKey(0))  // A
        #expect(!KeyNames.isGoodWorkspaceKey(49)) // Space
    }
}

@Suite struct ForgivingSearch {
    let entries: [CheatEntry] = Command.allCases.map {
        CheatEntry(id: $0.rawValue, keys: Keymap.keycaps(for: Keymap().binding(for: $0), workspaceKeys: workspaceKeys),
                   title: $0.title, group: $0.group, keywords: $0.keywords)
    }

    func top(_ q: String) -> String? { CheatSheetSearch.search(q, in: entries).entries.first?.id }
    func finds(_ q: String, _ id: String) -> Bool { CheatSheetSearch.search(q, in: entries).entries.prefix(4).contains { $0.id == id } }

    @Test func naturalWords() {
        #expect(top("maximize") == "focusMode")
        #expect(top("fullscreen") == "focusMode")
        #expect(finds("hide window", "stash"))
        #expect(finds("minimize", "stash"))
        #expect(finds("launcher", "summon"))
        #expect(finds("open app", "summon"))
        #expect(finds("help", "cheatSheet"))
        #expect(finds("reset layout", "tidy"))
        #expect(finds("bigger", "grow"))
        #expect(finds("kill window", "close"))
    }

    @Test func spacesMeanWorkspaces() {
        #expect(finds("virtual desktop", "workspace1"))
        #expect(finds("switch space 2", "workspace2"))
        #expect(finds("send window to desktop 3", "moveToWorkspace3"))
    }

    @Test func symbolsAndAbbreviations() {
        #expect(finds("cmd shift left", "moveLeft"))
        #expect(finds("⌘ ←", "focusLeft"))
        #expect(finds("page down", "workspace2"))
    }

    @Test func typosStillWork() {
        #expect(finds("workspce 1", "workspace1"))
        #expect(finds("sumon", "summon"))
        #expect(finds("cheatsheet", "cheatSheet"))
    }

    @Test func fillerWordsAreIgnored() {
        #expect(top("make it bigger") == "grow")
        #expect(top("how do I hide a window") == "stash")
        #expect(!CheatSheetSearch.search("make it bigger", in: entries).closest)
    }

    @Test func titlesOutrankKeywords() {
        #expect(top("workspce 3") == "workspace3")
        #expect(top("go to workspace 2") == "workspace2")
    }

    @Test func nothingMatchesFallsBackToClosest() {
        let r = CheatSheetSearch.search("tile thing zzz", in: entries)
        #expect(r.closest)
        #expect(!r.entries.isEmpty)
        #expect(CheatSheetSearch.search("", in: entries).entries.count == entries.count)
    }
}
