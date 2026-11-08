import AppKit
import QuartzCore
import ScreenCaptureKit

/// Spotlight's shelf: the windows set aside by ⌘⇧F, shown as small cards tilted
/// in 3D down the left edge, the way iPadOS and Stage Manager show their
/// recent windows.
///
/// macOS has no way to tilt or shrink another app's window (and many refuse to
/// get small), so the real windows wait off screen and the shelf draws cards
/// for them: a snapshot of the window when Screen Recording is allowed,
/// otherwise the app's icon and name. Clicking a card swaps that window into the
/// center; the pointer over a card outlines it, to show it can be clicked.
final class Shelf {
    struct Card {
        let id: CGWindowID
        let name: String
        let icon: NSImage
        /// Width / height of the window, so the card has its shape.
        let aspect: CGFloat
    }

    var onPick: ((CGWindowID) -> Void)?
    /// Something being dragged (a file, an image, text) rested on a card: end Focus so it
    /// can be dropped into one of the windows.
    var onDragRest: ((CGWindowID) -> Void)?

    private var panel: NSPanel?
    private var stage: CALayer?
    private var cards: [CGWindowID: CardLayer] = [:]
    private var order: [CGWindowID] = []
    private var hitRects: [(CGWindowID, CGRect)] = []
    private var shownOn: CGDirectDisplayID?
    private var snapshots: [CGWindowID: CGImage] = [:]
    private var hideWork: DispatchWorkItem?

    private static let stripWidth: CGFloat = 300
    private static let cardWidth: CGFloat = 196
    private static let leftInset: CGFloat = 34
    private static let spacing: CGFloat = 34
    private static let maxCards = 6
    private static let tilt: CGFloat = 0.52 // about 30°, right edge receding

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var isShowing: Bool { panel?.isVisible ?? false }

    func show(_ list: [Card], on display: Display) {
        let shown = Array(list.prefix(Self.maxCards))
        if isShowing, shownOn == display.id, shown.map(\.id) == order { return }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }) else { return }
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.minX, y: area.minY, width: Self.stripWidth, height: area.height), display: false)
        guard let stage else { return }
        stage.frame = CGRect(origin: .zero, size: panel.frame.size)

        // Cards keep their window's shape, within reason, and stack centered.
        let sizes = shown.map { card -> CGSize in
            let height = min(150, max(96, Self.cardWidth / card.aspect))
            return CGSize(width: Self.cardWidth, height: height.rounded())
        }
        let total = sizes.map(\.height).reduce(0, +) + Self.spacing * CGFloat(max(0, shown.count - 1))
        var top = (panel.frame.height + total) / 2

        for (id, layer) in cards where !shown.contains(where: { $0.id == id }) {
            layer.removeFromSuperlayer()
            cards[id] = nil
        }
        hitRects = []
        for (i, (card, size)) in zip(shown, sizes).enumerated() {
            let isNew = cards[card.id] == nil
            let layer = cards[card.id] ?? CardLayer(card: card)
            cards[card.id] = layer
            if let image = snapshots[card.id] { layer.setSnapshot(image) }
            if layer.superlayer == nil { stage.addSublayer(layer) }

            let frame = CGRect(x: Self.leftInset, y: (top - size.height).rounded(), width: size.width, height: size.height)
            top -= size.height + Self.spacing
            hitRects.append((card.id, frame.insetBy(dx: -6, dy: -18)))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer.position = CGPoint(x: frame.minX, y: frame.midY)
            layer.layoutCard()
            layer.transform = CATransform3DMakeRotation(Self.tilt, 0, 1, 0)
            layer.opacity = 1
            CATransaction.commit()

            if isNew && !reduceMotion {
                // Slide in from the left edge, one after another.
                let slide = CABasicAnimation(keyPath: "transform")
                slide.fromValue = CATransform3DTranslate(CATransform3DMakeRotation(Self.tilt * 1.6, 0, 1, 0), -140, 0, 0)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                let group = CAAnimationGroup()
                group.animations = [slide, fade]
                group.duration = 0.32
                group.beginTime = CACurrentMediaTime() + Double(i) * 0.035
                group.fillMode = .backwards
                group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                layer.add(group, forKey: "in")
            }
        }
        order = shown.map(\.id)
        shownOn = display.id
        panel.orderFrontRegardless()
    }

    func hide(animated: Bool) {
        guard let panel, panel.isVisible else {
            snapshots = [:]
            return
        }
        order = []
        shownOn = nil
        snapshots = [:]
        pointedAt = nil
        let finish = { [weak self] in
            panel.orderOut(nil)
            self?.cards.values.forEach { $0.removeFromSuperlayer() }
            self?.cards = [:]
            self?.hitRects = []
        }
        guard animated && !reduceMotion else { return finish() }
        for (i, layer) in cards.values.enumerated() {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.toValue = CATransform3DTranslate(CATransform3DMakeRotation(Self.tilt * 1.6, 0, 1, 0), -140, 0, 0)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [slide, fade]
            group.duration = 0.22
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.02
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(group, forKey: "out")
        }
        let work = DispatchWorkItem(block: finish)
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func setSnapshot(_ image: CGImage, for id: CGWindowID) {
        snapshots[id] = image
        cards[id]?.setSnapshot(image)
    }

    fileprivate func picked(at point: CGPoint) {
        guard let id = card(at: point) else { return }
        onPick?(id)
    }

    fileprivate func card(at point: CGPoint) -> CGWindowID? {
        hitRects.first(where: { $0.1.contains(point) })?.0
    }

    /// The card under the pointer (or none): a light outline and a pointing hand say it can be clicked.
    private var pointedAt: CGWindowID?

    fileprivate func pointerHover(_ id: CGWindowID?) {
        guard id != pointedAt else { return }
        pointedAt = id
        for (cardID, card) in cards { card.hovered = cardID == id }
        (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    /// A drag is over this card (or none): light it up, the way Finder answers a folder.
    fileprivate func dragHover(_ id: CGWindowID?) {
        for (cardID, card) in cards { card.highlighted = cardID == id }
    }

    fileprivate func dragRested(on id: CGWindowID) {
        dragHover(nil)
        onDragRest?(id)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        let view = ShelfView(shelf: self)
        view.wantsLayer = true
        view.acceptDrags()
        let stage = CALayer()
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 850
        stage.sublayerTransform = perspective
        view.layer?.addSublayer(stage)
        panel.contentView = view
        self.panel = panel
        self.stage = stage
        return panel
    }
}

private final class ShelfView: NSView {
    weak var shelf: Shelf?

    init(shelf: Shelf) {
        self.shelf = shelf
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { shelf?.picked(at: convert(event.locationInWindow, from: nil)) }

    // MARK: The pointer over a card (tracked even while another app is in front)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointer(event) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseExited(with event: NSEvent) { shelf?.pointerHover(nil) }

    private func pointer(_ event: NSEvent) {
        shelf?.pointerHover(shelf?.card(at: convert(event.locationInWindow, from: nil)))
    }

    // MARK: Spring-loading: a dragged file resting on a card ends Focus, so it can be dropped.

    private var hovered: CGWindowID?
    private var rest: DispatchWorkItem?

    func acceptDrags() {
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, .pdf, .rtf, .html, .color,
                                 NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                                 NSPasteboard.PasteboardType("public.data")]
                                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { hover(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    private func track(_ drag: NSDraggingInfo) -> NSDragOperation {
        hover(shelf?.card(at: convert(drag.draggingLocation, from: nil)))
        return [] // nothing drops onto a card; it opens the windows up instead
    }

    private func hover(_ id: CGWindowID?) {
        guard id != hovered else { return }
        hovered = id
        rest?.cancel()
        shelf?.dragHover(id)
        guard let id else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered == id else { return }
            self.hovered = nil
            self.shelf?.dragRested(on: id)
        }
        rest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// One card: the window's snapshot (or its app icon), rounded, with a soft
/// shadow, the app icon tucked at its corner, and the app name underneath.
private final class CardLayer: CALayer {
    private let face = CALayer()
    private let placeholderIcon = CALayer()
    private let badge = CALayer()
    private let label = CATextLayer()

    init(card: Shelf.Card) {
        super.init()
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.45
        shadowRadius = 16
        shadowOffset = CGSize(width: 0, height: -8)

        face.cornerRadius = 11
        face.cornerCurve = .continuous
        face.masksToBounds = true
        face.borderWidth = 0.5
        face.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        face.backgroundColor = NSColor(white: 0.16, alpha: 0.96).cgColor
        face.contentsGravity = .resizeAspectFill
        addSublayer(face)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        placeholderIcon.contents = card.icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        placeholderIcon.contentsGravity = .resizeAspect
        face.addSublayer(placeholderIcon)

        badge.contents = card.icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        badge.contentsGravity = .resizeAspect
        badge.shadowOpacity = 0.4
        badge.shadowRadius = 4
        badge.shadowOffset = CGSize(width: 0, height: -2)
        addSublayer(badge)

        label.string = card.name
        label.fontSize = 11
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.foregroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        label.contentsScale = scale
        label.truncationMode = .end
        label.shadowOpacity = 0.6
        label.shadowRadius = 3
        label.shadowOffset = .zero
        addSublayer(label)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A drag resting on the card.
    var highlighted = false {
        didSet { if highlighted != oldValue { updateOutline() } }
    }

    /// The pointer over the card: a light outline, and it lifts a little, to show it can be clicked.
    var hovered = false {
        didSet { if hovered != oldValue { updateOutline() } }
    }

    private func updateOutline() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        if highlighted {
            face.borderWidth = 2.5
            face.borderColor = NSColor.controlAccentColor.cgColor
        } else if hovered {
            face.borderWidth = 1.5
            face.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        } else {
            face.borderWidth = 0.5
            face.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        }
        shadowOpacity = highlighted || hovered ? 0.6 : 0.45
        shadowRadius = highlighted || hovered ? 20 : 16
        CATransaction.commit()
    }

    func layoutCard() {
        face.frame = bounds
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: 11, cornerHeight: 11, transform: nil)
        let iconSize = min(64, bounds.height * 0.5)
        placeholderIcon.frame = CGRect(x: bounds.midX - iconSize / 2, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
        badge.frame = CGRect(x: -10, y: -12, width: 30, height: 30)
        label.frame = CGRect(x: 26, y: -17, width: bounds.width - 26, height: 14)
    }

    func setSnapshot(_ image: CGImage) {
        face.contents = image
        placeholderIcon.isHidden = true
    }
}

/// Captures what windows look like, for the shelf's cards and Sort My Windows. Needs the Screen
/// Recording permission; asks for it once (unless `ask` is false), and returns nothing until it's given.
enum Snapshotter {
    static func capture(_ ids: [CGWindowID], ask: Bool = true, completion: @escaping ([CGWindowID: CGImage]) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            if ask, !UserDefaults.standard.bool(forKey: "askedForScreenRecording") {
                UserDefaults.standard.set(true, forKey: "askedForScreenRecording")
                // The system prompt can take a while; never hold up the main thread for it.
                DispatchQueue.global(qos: .utility).async { _ = CGRequestScreenCaptureAccess() }
            }
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            guard let content else { return }
            let targets = content.windows.filter { ids.contains($0.windowID) }
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [CGWindowID: CGImage] = [:]
            for window in targets {
                group.enter()
                let config = SCStreamConfiguration()
                let scale = min(1, 520 / max(1, window.frame.width))
                config.width = max(1, Int(window.frame.width * scale))
                config.height = max(1, Int(window.frame.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                 configuration: config) { image, _ in
                    if let image {
                        lock.lock()
                        images[window.windowID] = image
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(images) }
        }
    }
}
