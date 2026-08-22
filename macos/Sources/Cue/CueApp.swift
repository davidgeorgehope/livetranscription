import AppKit
import SwiftUI

@available(macOS 14.2, *)
@main
enum CueMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = CueAppDelegate()
        app.delegate = delegate
        FileHandle.standardError.write(Data("cue: starting NSApp.run\n".utf8))
        app.run()
    }
}

@available(macOS 14.2, *)
final class CueAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var window: NSWindow?

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
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
            let button = NSButton(title: "Listen", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 860, y: 640, width: 100, height: 28)
            button.keyEquivalent = "l"
            button.keyEquivalentModifierMask = [.command]
            button.setButtonType(.momentaryPushIn)
            let target = CueListenTarget(model: model)
            objc_setAssociatedObject(button, "cue.listen.target", target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            button.target = target
            button.action = #selector(CueListenTarget.toggle)
            controller.view.addSubview(button)
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
