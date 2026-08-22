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
        let model = AppModel()
        self.model = model
        FileHandle.standardError.write(Data("cue: model ready\n".utf8))
        let controller = NSHostingController(rootView: ContentView().environmentObject(model))
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
        let window = NSWindow(contentViewController: controller)
        window.title = "Cue"
        window.setContentSize(NSSize(width: 980, height: 680))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write(Data("cue: window \(NSStringFromRect(window.frame))\n".utf8))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}
