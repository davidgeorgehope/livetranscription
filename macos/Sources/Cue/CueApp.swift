import AppKit
import Combine
import ServiceManagement
import SwiftUI

@available(macOS 14.2, *)
@main
enum CueMain {
    static func main() {
        let app = NSApplication.shared
        // LSUIElement launches Cue as a menu bar app; the delegate makes it a
        // regular app (Dock icon, menu bar) whenever the window is showing.
        // The UI hardcodes a dark palette; in system Light Mode the AppKit
        // split view paints white over it and the text becomes unreadable.
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = CueAppDelegate()
        app.delegate = delegate
        app.mainMenu = buildMainMenu()
        FileHandle.standardError.write(Data("cue: starting NSApp.run\n".utf8))
        app.run()
    }

    /// The app runs NSApplication manually, so without an explicit main menu
    /// there are no Edit key equivalents — Cmd+V etc. silently do nothing.
    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Cue", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let controlsItem = NSMenuItem(title: "Controls", action: nil, keyEquivalent: "")
        mainMenu.addItem(controlsItem)
        let controlsMenu = NSMenu(title: "Controls")
        let listenItem = NSMenuItem(title: "Toggle Listen", action: #selector(CueListenTarget.toggle), keyEquivalent: "l")
        controlsMenu.addItem(listenItem)
        controlsItem.submenu = controlsMenu

        return mainMenu
    }
}

enum WindowPin {
    static let defaultsKey = "keepOnTop"

    static var isPinned: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func apply(to window: NSWindow, pinned: Bool) {
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }
}

@available(macOS 14.2, *)
final class CueAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var window: NSWindow?
    private var listenTarget: CueListenTarget?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(Data("cue: didFinishLaunching\n".utf8))
        let atLogin = Self.launchedAtLogin
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cue"
        window.isReleasedWhenClosed = false
        window.delegate = self
        WindowPin.apply(to: window, pinned: WindowPin.isPinned)
        window.center()
        self.window = window
        if !atLogin { showWindow(activate: true) }
        FileHandle.standardError.write(Data("cue: bare window \(NSStringFromRect(window.frame))\n".utf8))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let model = AppModel()
            self.model = model
            FileHandle.standardError.write(Data("cue: model ready\n".utf8))
            let controller = NSHostingController(rootView: ContentView().environmentObject(model))
            controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 980, height: 680))
            let target = CueListenTarget(model: model)
            self.listenTarget = target
            if let listenItem = NSApp.mainMenu?.item(withTitle: "Controls")?.submenu?.item(withTitle: "Toggle Listen") {
                listenItem.target = target
            }
            if !atLogin { window.makeKeyAndOrderFront(nil) }
            self.statusBar = StatusBarController(model: model) { [weak self] activate in
                self?.showWindow(activate: activate)
            }
            Self.openAtLoginOnce()
            FileHandle.standardError.write(Data("cue: hosted \(NSStringFromRect(window.frame))\n".utf8))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(activate: true)
        return true
    }

    /// Closing the window leaves Cue running in the menu bar.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// `activate: false` puts the window up without taking focus from the meeting app.
    func showWindow(activate: Bool) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    /// Login launches stay in the menu bar; the window opens on demand or when a call starts.
    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Cue is meant to be always on, so it adds itself to login items once;
    /// after that the menu toggle and System Settings own the choice.
    @MainActor private static func openAtLoginOnce() {
        let key = "cue.openAtLoginOffered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do {
            try SMAppService.mainApp.register()
            AppModel.answerLog("open at login: registered, status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            AppModel.answerLog("open at login failed: \(error.localizedDescription)")
        }
    }
}

/// The menu bar item: there whenever Cue runs, red while it's listening.
@available(macOS 14.2, *)
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let showWindow: (_ activate: Bool) -> Void
    private var phaseSink: AnyCancellable?

    init(model: AppModel, showWindow: @escaping (_ activate: Bool) -> Void) {
        self.model = model
        self.showWindow = showWindow
        super.init()
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Cue")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        phaseSink = model.$phase.sink { [weak self] phase in
            guard let self else { return }
            let listening = phase == .listening
            self.item.button?.contentTintColor = listening ? .systemRed : nil
            self.item.button?.toolTip = listening ? "Cue — listening" : "Cue"
            // A call that starts while Cue is only in the menu bar still needs its cards on screen.
            if listening { self.showWindow(false) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.menuBarStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(action(model.phase == .listening ? "Stop Listening" : "Start Listening", #selector(toggleListen)))
        menu.addItem(action("Show Cue", #selector(showCue)))
        menu.addItem(.separator())
        let login = action("Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleListen() { model.toggleListen() }

    @objc private func showCue() { showWindow(true) }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            AppModel.answerLog("open at login toggle failed: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

@available(macOS 14.2, *)
final class CueListenTarget: NSObject {
    private let model: AppModel
    init(model: AppModel) { self.model = model }
    @objc func toggle() {
        Task { @MainActor in
            self.model.menuToggleListen()
        }
    }
}
