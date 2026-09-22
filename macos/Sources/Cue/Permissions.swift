import AppKit

/// Deep-links into System Settings privacy panes. Used when Cue is blocked
/// after a rebuild: ad-hoc (or CDHash-bound) grants leave a stale "Cue"
/// toggle that looks enabled while the new binary is still denied.
enum Permissions {
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

    static let staleGrantHelp =
        "macOS ties System Audio Recording to Cue’s code signature. After a rebuild the old Cue entry still shows as On, but this binary is a new identity — remove every Cue row in that Privacy pane, then Listen again."

    private static func open(_ urls: [String]) {
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
