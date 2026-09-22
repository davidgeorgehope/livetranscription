import AppKit
import CoreAudio
import Foundation

/// Is another app on a call? CoreAudio's process objects say which processes
/// have the microphone open right now — Zoom, Teams, Chrome for Meet, Slack
/// huddles — with no permission prompt and no per-app hacks. A call starting
/// or ending is simply that set becoming non-empty or empty.
@MainActor
final class CallPresence: ObservableObject {
    /// Display name of the app holding the mic (first one if several), nil when none.
    @Published private(set) var activeApp: String?

    private var timer: Timer?
    private let ownPID = getpid()

    func start(interval: TimeInterval = 2) {
        stop()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pids = Self.processesRunningInput().filter { $0 != ownPID }
        let name = pids.lazy.compactMap { pid -> String? in
            NSRunningApplication(processIdentifier: pid)?.localizedName
        }.first ?? (pids.isEmpty ? nil : "Another app")
        if name != activeApp { activeApp = name }
    }

    nonisolated static func processesRunningInput() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard read(object, kAudioProcessPropertyIsRunningInput, as: UInt32(0)) != 0 else { return nil }
            let pid = read(object, kAudioProcessPropertyPID, as: pid_t(0))
            return pid > 0 ? pid : nil
        }
    }

    private nonisolated static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as zero: T) -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        var value = zero
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : zero
    }
}
