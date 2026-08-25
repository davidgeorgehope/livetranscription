import AppKit
import ApplicationServices

/// Deep-links into System Settings privacy panes. Used when Cue is blocked
/// after a rebuild: ad-hoc (or CDHash-bound) grants leave a stale "Cue"
/// toggle that looks enabled while the new binary is still denied.
enum Permissions {
    private static var didPromptAccessibilityThisProcess = false

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt at most once per process. Re-prompting while a stale Cue row
    /// is still listed in Settings just reopens the pane with nothing to flip.
    @discardableResult
    static func ensureAccessibility(promptIfNeeded: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard promptIfNeeded, !didPromptAccessibilityThisProcess else { return false }
        didPromptAccessibilityThisProcess = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemAudioRecordingSettings() {
        open([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SystemAudioRecording",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ])
    }

    static func openMicrophoneSettings() {
        open([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ])
    }

    static func openAccessibilitySettings() {
        open([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
    }

    static let staleGrantHelp =
        "macOS ties System Audio / Accessibility to Cue’s code signature. After a rebuild the old Cue entry still shows as On, but this binary is a new identity — remove every Cue row in that Privacy pane, then Listen again."

    private static func open(_ urls: [String]) {
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
