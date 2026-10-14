import AppKit

/// Asks the user to press the three keys they want for spaces 1, 2 and 3,
/// whatever their keyboard's firmware sends for them.
final class KeyTeacher: NSObject, NSWindowDelegate {
    private let tap: HotkeyTap
    private let onDone: ([Int64]) -> Void
    private var panel: NSPanel?
    private var title = NSTextField(labelWithString: "")
    private var detail = NSTextField(wrappingLabelWithString: "")
    private var keys: [Int64] = []

    private static let prompts = [
        "Press the top key of the three",
        "Now the middle one",
        "Now the bottom one",
    ]

    init(tap: HotkeyTap, onDone: @escaping ([Int64]) -> Void) {
        self.tap = tap
        self.onDone = onDone
    }

    func begin() {
        keys = []
        let panel = self.panel ?? makePanel()
        update()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        tap.learnNextKey { [weak self] code in self?.learned(code) }
    }

    private func learned(_ code: Int64) {
        if code == 53 { // Esc
            finish(saving: false)
            return
        }
        if keys.contains(code) {
            detail.stringValue = "That's the same key as before. Press the next one down."
        } else {
            keys.append(code)
        }
        if keys.count == 3 {
            finish(saving: true)
        } else {
            update()
            tap.learnNextKey { [weak self] code in self?.learned(code) }
        }
    }

    private func update() {
        title.stringValue = "\(Self.prompts[keys.count])  (\(keys.count + 1) of 3)"
        if keys.isEmpty {
            detail.stringValue = "Use the three keys on the far right of your keyboard, above the right arrow. They become spaces 1, 2 and 3. Press Esc to cancel."
        } else if !detail.stringValue.hasPrefix("That's the same") {
            detail.stringValue = "Got it."
        }
    }

    private func finish(saving: Bool) {
        tap.learnNextKey(nil)
        if saving {
            onDone(keys)
            title.stringValue = "All set"
            detail.stringValue = "⌘ plus those keys goes to that space. Add Shift to move the focused window there."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.panel?.orderOut(nil) }
        } else {
            panel?.orderOut(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        tap.learnNextKey(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "Set Up Space Keys"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 372
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        panel.contentView = stack
        self.panel = panel
        return panel
    }
}
