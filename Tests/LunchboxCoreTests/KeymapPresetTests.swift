import CoreGraphics
import Testing
@testable import LunchboxCore

/// Ready-made key sets: the arrows, or Vim's H J K L.
@Suite struct KeymapPresets {
    let leftCmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | Shortcuts.leftCommandMask)
    var leftCmdShift: CGEventFlags { leftCmd.union(.maskShift) }

    @Test func theDefaultsAreTheArrows() {
        #expect(Keymap().preset == .arrows)
    }

    @Test func vimKeysMoveFocusAndWindowsWithHJKL() {
        let map = Keymap().applying(.vim)
        #expect(map.preset == .vim)
        #expect(map.command(for: 4, flags: leftCmd, workspaceKeys: []) == .focusLeft)       // H
        #expect(map.command(for: 38, flags: leftCmd, workspaceKeys: []) == .focusDown)      // J
        #expect(map.command(for: 40, flags: leftCmd, workspaceKeys: []) == .focusUp)        // K
        #expect(map.command(for: 37, flags: leftCmd, workspaceKeys: []) == .focusRight)     // L
        #expect(map.command(for: 4, flags: leftCmdShift, workspaceKeys: []) == .moveLeft)
        #expect(map.command(for: 46, flags: leftCmdShift, workspaceKeys: []) == .hide)      // M, since ⇧H moves left
        #expect(map.command(for: 123, flags: leftCmd, workspaceKeys: []) == nil)            // the arrows are free again
    }

    @Test func nothingClashesWithVimKeys() {
        let map = Keymap().applying(.vim)
        for c in Command.allCases where c.isActive(spaces: 3) {
            #expect(map.conflict(with: map.binding(for: c), excluding: c, workspaceKeys: [], spaces: 3) == nil)
        }
    }

    @Test func backToArrowsIsTheDefaultsAgain() {
        #expect(Keymap().applying(.vim).applying(.arrows) == Keymap())
    }

    @Test func otherChangesStayUnlessTheyUsedAPresetKey() {
        var map = Keymap()
        map.overrides[.tidy] = KeyBinding(.code(31), command: true, shift: true, leftCommandOnly: true)     // ⌘⇧O
        map.overrides[.close] = KeyBinding(.code(37), command: true, leftCommandOnly: true)                 // ⌘L
        let vim = map.applying(.vim)
        #expect(vim.binding(for: .tidy) == map.binding(for: .tidy))
        #expect(vim.binding(for: .close) == Keymap.defaults[.close])
    }

    @Test func changingOnePresetKeyByHandMakesItCustom() {
        var map = Keymap().applying(.vim)
        map.overrides[.focusLeft] = KeyBinding(.code(0), command: true, leftCommandOnly: true)
        #expect(map.preset == nil)
    }
}
