import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Borderless floating panel that can take keyboard focus without activating the app.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Glaude has no main menu (it's a menu-bar app), so nothing routes the standard
    /// edit shortcuts. Send them to the focused text field ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift] {
            let action: Selector?
            switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
            case ("v", false): action = #selector(NSText.paste(_:))
            case ("c", false): action = #selector(NSText.copy(_:))
            case ("x", false): action = #selector(NSText.cut(_:))
            case ("a", false): action = #selector(NSText.selectAll(_:))
            case ("z", false): action = Selector(("undo:"))
            case ("z", true): action = Selector(("redo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Hosting view that accepts the first click even though the app isn't active.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The chat panel's size, which the panel's expand button reads and toggles.
final class PanelSizeModel: ObservableObject {
    static let compact = NSSize(width: 340, height: 460)
    static let large = NSSize(width: 520, height: 720)
    static let minimum = NSSize(width: 300, height: 360)

    @Published var isLarge = false

    func update(from size: NSSize) {
        let large = size.width >= 430 || size.height >= 600
        if large != isLarge { isLarge = large }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = SessionStore()
    private let panelSize = PanelSizeModel()
    private var server: GlaudeServer!
    private var bubble: FloatingPanel!
    private var chat: FloatingPanel!
    private var peek: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var peekHide: DispatchWorkItem?
    /// The session a "needs you" peek is about, so it can go once that's resolved.
    private var needsYouPeekSession: String?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var outsideClickMonitor: Any?
    private let hotkeys = Hotkeys()
    private var notifier: Notifier!
    /// Sessions with a "needs you" notification up, to take down once they're answered.
    private var notifiedNeedsYou: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    private var soundsOn: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = GlaudeServer(token: GlaudeFiles.loadOrCreateToken(), store: store)
        server.start()

        setUpChat()
        setUpBubble()
        peek = FloatingPanel(size: NSSize(width: 288, height: 120))
        peek.hasShadow = false
        setUpStatusItem()

        store.onDone = { [weak self] session in self?.sessionFinished(session) }
        store.onNeedsYou = { [weak self] session, message in self?.sessionNeedsYou(session, message: message) }
        store.$selectedID.sink { [weak self] _ in DispatchQueue.main.async { self?.store.markSeen() } }
            .store(in: &cancellables)
        store.$sessions.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.dropResolvedNeedsYouPeek()
                self?.dropResolvedNotifications()
            }
        }
        .store(in: &cancellables)

        notifier = Notifier(store: store)
        notifier.onOpen = { [weak self] id in self?.showChat(sessionID: id) }
        notifier.onOpenTerminal = { [weak self] id in
            if let session = self?.store.session(id) { TerminalFocus.reveal(session) }
        }
        notifier.start()

        hotkeys.onPress = { [weak self] action in
            switch action {
            case .togglePanel: self?.toggleChat()
            case .jumpToSession: self?.jumpToSession()
            }
        }
        hotkeys.register()
    }

    /// ⌃⌥J: the session that needs you (else the latest one), in its terminal and the panel.
    private func jumpToSession() {
        let target = store.sessions.first { $0.pending != nil || $0.state == .needsYou }
            ?? store.sessions.max { $0.lastActivity < $1.lastActivity }
        guard let target else { return NSSound.beep() }
        TerminalFocus.reveal(target)
        showChat(sessionID: target.id)
    }

    // MARK: Bubble

    private func setUpBubble() {
        bubble = FloatingPanel(size: NSSize(width: 64, height: 64))
        bubble.hasShadow = false
        let view = BubbleView(store: store)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { [weak self] _ in self?.dragChanged() }
                .onEnded { [weak self] _ in self?.dragEnded() })
            .onTapGesture { [weak self] in self?.toggleChat() }
        bubble.contentView = ClickThroughHostingView(rootView: view)

        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = UserDefaults.standard.string(forKey: "bubbleOrigin").map(NSPointFromString)
        let origin = saved ?? NSPoint(x: frame.maxX - 76, y: frame.minY + 120)
        bubble.setFrameOrigin(origin)
        snapBubble(animated: false)
        bubble.orderFrontRegardless()
    }

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, bubble.frame.origin) }
        guard let start = dragStart else { return }
        bubble.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                      y: start.origin.y + mouse.y - start.mouse.y))
        if chat.isVisible { positionNextToBubble(chat) }
    }

    private func dragEnded() {
        dragStart = nil
        snapBubble(animated: true)
    }

    /// Snap to the nearest left/right edge of the screen the bubble is on.
    private func snapBubble(animated: Bool) {
        let center = NSPoint(x: bubble.frame.midX, y: bubble.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = bubble.frame.size
        let x = center.x < visible.midX ? visible.minX + 4 : visible.maxX - size.width - 4
        let y = min(max(bubble.frame.minY, visible.minY + 4), visible.maxY - size.height - 4)
        let target = NSRect(origin: NSPoint(x: x, y: y), size: size)
        bubble.setFrame(target, display: true, animate: animated)
        UserDefaults.standard.set(NSStringFromPoint(target.origin), forKey: "bubbleOrigin")
        if chat.isVisible { positionNextToBubble(chat) }
    }

    // MARK: Chat panel

    private func setUpChat() {
        let saved = UserDefaults.standard.string(forKey: "chatSize").map(NSSizeFromString)
        chat = FloatingPanel(size: saved ?? PanelSizeModel.compact)
        chat.styleMask.insert(.resizable)  // drag any edge or corner
        chat.minSize = PanelSizeModel.minimum
        chat.delegate = self
        let view = ChatView(
            store: store,
            panelSize: panelSize,
            onClose: { [weak self] in self?.hideChat() },
            onOpenTerminal: { session in TerminalFocus.reveal(session) },
            onToggleSize: { [weak self] in self?.toggleChatSize() }
        )
        let host = ClickThroughHostingView(rootView: view)
        host.sizingOptions = []  // the window's size drives the view, not the other way round
        chat.contentView = host
        panelSize.update(from: chat.frame.size)
    }

    private func toggleChatSize() {
        let target = panelSize.isLarge ? PanelSizeModel.compact : PanelSizeModel.large
        chat.setFrame(frameNextToBubble(size: target), display: true, animate: true)
        chatSizeChanged()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === chat else { return }
        chatSizeChanged()
        positionNextToBubble(chat)  // re-attach if the edge beside the bubble was dragged
    }

    private func chatSizeChanged() {
        panelSize.update(from: chat.frame.size)
        UserDefaults.standard.set(NSStringFromSize(chat.frame.size), forKey: "chatSize")
    }

    private func toggleChat() {
        chat.isVisible ? hideChat() : showChat(sessionID: nil)
    }

    private func showChat(sessionID: String?) {
        hidePeek()
        if let sessionID {
            store.selectedID = sessionID
        } else if let urgent = store.sessions.first(where: { $0.pending != nil || $0.state == .needsYou })
                    ?? store.sessions.first(where: { $0.unseenDone }) {
            store.selectedID = urgent.id
        }
        store.chatVisible = true
        store.markSeen()
        positionNextToBubble(chat)
        chat.makeKeyAndOrderFront(nil)
        // A click in any other app closes the panel. Clicks on Glaude's own windows
        // (the bubble toggles it) never reach a global monitor.
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in self?.hideChat() }
        }
    }

    private func hideChat() {
        store.chatVisible = false
        chat.orderOut(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Place a panel beside the bubble, on the side facing the middle of the screen.
    private func positionNextToBubble(_ panel: NSPanel) {
        panel.setFrame(frameNextToBubble(size: panel.frame.size), display: true)
    }

    /// The frame beside the bubble for a panel of `size`, shrunk to fit the screen.
    private func frameNextToBubble(size wanted: NSSize) -> NSRect {
        let b = bubble.frame
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: b.midX, y: b.midY)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: wanted) }
        let onRight = b.midX > visible.midX
        let room = onRight ? b.minX + 4 - visible.minX - 4 : visible.maxX - 4 - (b.maxX - 4)
        let size = NSSize(width: min(wanted.width, room), height: min(wanted.height, visible.height - 8))
        let x = onRight ? b.minX - size.width + 4 : b.maxX - 4
        let y = min(max(b.maxY - size.height, visible.minY + 4), visible.maxY - size.height - 4)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    // MARK: Peek

    private func sessionFinished(_ session: Session) {
        if soundsOn { NSSound(named: "Glass")?.play() }
        let text = session.items.reversed().compactMap { item -> String? in
            if case .assistant(let text) = item.kind { return text }
            return nil
        }.first ?? ""
        var footer: [String] = []
        if !session.turnFiles.isEmpty { footer.append("\(session.turnFiles.count) file\(session.turnFiles.count == 1 ? "" : "s") changed") }
        if session.turnCommands > 0 { footer.append("\(session.turnCommands) command\(session.turnCommands == 1 ? "" : "s")") }
        if session.turnAdded + session.turnRemoved > 0 { footer.append("+\(session.turnAdded) −\(session.turnRemoved)") }
        if !chat.isVisible { notifier.sessionFinished(session, text: plain(text), footer: footer.joined(separator: " · ")) }
        guard !(chat.isVisible && store.selected?.id == session.id) else { return }
        needsYouPeekSession = nil
        showPeek(title: "\(session.name) finished", detail: plain(text), footer: footer.joined(separator: " · "),
                 tint: .glaudeDone, sessionID: session.id)
    }

    private func sessionNeedsYou(_ session: Session, message: String) {
        if soundsOn { NSSound(named: "Funk")?.play() }
        if !chat.isVisible {
            notifier.sessionNeedsYou(session, title: message)
            notifiedNeedsYou.insert(session.id)
        }
        guard !(chat.isVisible && store.selected?.id == session.id) else { return }
        needsYouPeekSession = session.id
        showPeek(title: "\(session.name) needs you", detail: message, footer: "Click to answer",
                 tint: .glaudeAccent, sessionID: session.id, duration: 12)
    }

    private func showPeek(title: String, detail: String, footer: String, tint: Color, sessionID: String,
                          duration: TimeInterval = 7) {
        let view = PeekView(title: title, detail: detail, footer: footer, tint: tint) { [weak self] in
            self?.showChat(sessionID: sessionID)
        }
        let host = ClickThroughHostingView(rootView: view)
        peek.contentView = host
        peek.setContentSize(host.fittingSize)
        positionNextToBubble(peek)
        peek.orderFrontRegardless()

        peekHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in self?.hidePeek() }
        peekHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hide)
    }

    /// A "needs you" peek goes as soon as its session stops waiting (answered in the
    /// terminal, or the classifier decided), instead of lingering for its full time.
    private func dropResolvedNeedsYouPeek() {
        guard let id = needsYouPeekSession, peek.isVisible else { return }
        let session = store.session(id)
        if session == nil || (session?.pending == nil && session?.state != .needsYou) { hidePeek() }
    }

    /// Take a "needs you" notification down once its session stops waiting.
    private func dropResolvedNotifications() {
        for id in notifiedNeedsYou {
            let session = store.session(id)
            if session == nil || (session?.pending == nil && session?.state != .needsYou) {
                notifier.clearNeedsYou(id)
                notifiedNeedsYou.remove(id)
            }
        }
    }

    private func hidePeek() {
        needsYouPeekSession = nil
        peekHide?.cancel()
        peek.orderOut(nil)
    }

    /// Strip the most common markdown so the peek reads as plain text.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Terminal

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Glaude")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, state: Bool? = nil, shortcut: Hotkeys.Action? = nil) {
            var label = title
            if let shortcut, hotkeys.unavailable.contains(shortcut) { label += " (\(shortcut.display) unavailable)" }
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            if let shortcut, !hotkeys.unavailable.contains(shortcut) {
                item.keyEquivalent = shortcut.keyEquivalent  // shown in the menu; the hot key does the work
                item.keyEquivalentModifierMask = [.control, .option]
            }
            item.target = action == nil ? nil : self
            item.isEnabled = action != nil
            if let state { item.state = state ? .on : .off }
            menu.addItem(item)
        }
        add(bubble.isVisible ? "Hide Bubble" : "Show Bubble", #selector(toggleBubble))
        add("Open Chat", #selector(openChat), shortcut: .togglePanel)
        add("Jump to Session", #selector(jumpToSessionFromMenu), shortcut: .jumpToSession)
        menu.addItem(.separator())
        add("Copy Plugin Install Command", #selector(copyInstallCommand))
        menu.addItem(.separator())
        add("Sounds", #selector(toggleSounds), state: soundsOn)
        if store.notifyMode == "claude" {
            add("Notifications: sent by Claude Code", nil)
        } else if !notifier.isInstalled {
            add("Notifications need Glaude in Applications", nil)
        } else {
            add("Notifications", #selector(toggleNotifications), state: notifier.isEnabled && notifier.isAuthorized)
        }
        add("Launch at Login", #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Quit Glaude", #selector(quit))
    }

    @objc private func toggleBubble() {
        if bubble.isVisible { bubble.orderOut(nil); hideChat(); hidePeek() } else { bubble.orderFrontRegardless() }
    }

    @objc private func openChat() {
        bubble.orderFrontRegardless()
        showChat(sessionID: nil)
    }

    /// What to type at a Claude Code prompt to connect it to Glaude.
    static let installCommand = "/plugin install glaude --marketplace vaseemcholakkan123/Glaude"

    @objc private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    @objc private func toggleSounds() { soundsOn.toggle() }
    @objc private func toggleNotifications() { notifier.isEnabled.toggle() }
    @objc private func jumpToSessionFromMenu() { jumpToSession() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
