import AppKit
import SwiftUI

@available(macOS 14.2, *)
@main
enum CueMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
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
final class CueAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var window: NSWindow?
    private var listenTarget: CueListenTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(Data("cue: didFinishLaunching\n".utf8))
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cue"
        window.isReleasedWhenClosed = false
        WindowPin.apply(to: window, pinned: WindowPin.isPinned)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
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
            window.makeKeyAndOrderFront(nil)
            FileHandle.standardError.write(Data("cue: hosted \(NSStringFromRect(window.frame))\n".utf8))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
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
