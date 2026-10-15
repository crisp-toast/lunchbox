import AppKit
import TesselCore

/// Enter a license, or buy one: shown from the menu, when the trial ends, and when an
/// activation link carries a key that doesn't check out.
final class LicenseWindow: NSObject, NSWindowDelegate {
    private let licensing: Licensing
    private var window: NSWindow?
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let field = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let activate = NSButton(title: "Activate", target: nil, action: nil)
    private let buy = NSButton(title: "Buy Tessel – $9.99…", target: nil, action: nil)
    private let lost = NSButton(title: "Lost your license?", target: nil, action: nil)

    init(licensing: Licensing) {
        self.licensing = licensing
        super.init()
    }

    /// Shows the window. `error` explains why it opened (a link with a bad key);
    /// `activated` thanks the buyer after a link activated Tessel.
    func show(error: String? = nil, activated: License? = nil) {
        let window = configure(error: error, activated: activated)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    /// Debugging: draws the window into a PNG without putting it on any screen.
    func snapshot(to path: String, trialEnded: Bool = false) {
        let window = configure(error: nil, activated: nil, trialEnded: trialEnded)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func configure(error: String?, activated: License?, trialEnded: Bool = false) -> NSWindow {
        let window = self.window ?? makeWindow()
        self.window = window
        let ended = (licensing.trial == .ended || trialEnded) && licensing.license == nil
        if let license = licensing.license {
            heading.stringValue = "Tessel is licensed"
            detail.stringValue = "Licensed to \(license.email). Paste a different key below to replace it."
        } else if ended {
            heading.stringValue = "Your free trial has ended"
            detail.stringValue = "Buy Tessel to keep your windows tiled. It's a one-time $9.99, with every future version included. Your windows stay right where they are."
        } else {
            heading.stringValue = "Enter your license"
            let day: String
            if case .active(let left) = licensing.trial { day = " Your free trial has \(left) day\(left == 1 ? "" : "s") left." } else { day = "" }
            detail.stringValue = "Paste the license key from your email, or click the activation link in it." + day
        }
        message.stringValue = error ?? activated.map { "Activated. Thanks for buying Tessel, \($0.email)!" } ?? ""
        message.textColor = activated == nil ? .systemRed : .systemGreen
        message.isHidden = message.stringValue.isEmpty
        buy.isHidden = licensing.license != nil
        lost.isHidden = licensing.license != nil
        field.stringValue = ""
        // Fit the window to what it says now.
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 460, height: content.fittingSize.height))
        }
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tessel License"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .aqua)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 360
        field.placeholderString = "tessel1.…"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.target = self
        field.action = #selector(activateKey)
        message.font = .systemFont(ofSize: 12)
        message.preferredMaxLayoutWidth = 400
        activate.target = self
        activate.action = #selector(activateKey)
        activate.keyEquivalent = "\r"
        buy.target = self
        buy.action = #selector(buyTessel)
        lost.target = self
        lost.action = #selector(recover)
        lost.isBordered = false
        lost.contentTintColor = .linkColor

        let text = NSStackView(views: [heading, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 14
        let buttons = NSStackView(views: [lost, NSView(), buy, activate])
        buttons.distribution = .fill
        let stack = NSStackView(views: [top, field, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
        ])
        window.contentView = content
        return window
    }

    @objc private func activateKey() {
        let text = field.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        message.isHidden = false
        if let license = licensing.activate(text) {
            message.textColor = .systemGreen
            message.stringValue = "Activated. Thanks, \(license.email)!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.window?.close() }
        } else {
            message.textColor = .systemRed
            message.stringValue = "That key doesn't check out. Copy it again from your license email (the whole thing, starting with tessel1.), or have it sent again."
        }
    }

    @objc private func buyTessel() { NSWorkspace.shared.open(Licensing.buyURL) }
    @objc private func recover() { NSWorkspace.shared.open(Licensing.recoverURL) }

}
