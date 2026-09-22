import Foundation
import AVFoundation
import Accelerate
import CoreAudio

enum AudioSource: String {
    case system
    case mic
}

/// Captures Core Audio process-tap system audio and the microphone as two
/// separate streams, emitting tagged 16 kHz mono PCM16 frames per source.
/// Keeping the streams apart is what makes speaker attribution (Them vs Me)
/// possible downstream.
@available(macOS 14.2, *)
final class DualCapture {
    var onPCM16: ((AudioSource, Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// A message while the mic is down and being retried; nil once it's back.
    var onMicTrouble: ((String?) -> Void)?

    private let tap = ProcessTapCapture()
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var micRestart: DispatchWorkItem?
    private let lock = NSLock()
    private var pending: [AudioSource: [Float]] = [.system: [], .mic: []]
    private var micOnly = false
    private var running = false
    private let targetRate: Double = 16_000
    private let frameSamples = 1_600 // 100ms at 16 kHz

    // Echo gate state: smoothed RMS of what's currently playing on system
    // audio, used to reject mic frames that are just speaker bleed.
    private var systemRMS: Float = 0
    private let micNoiseFloor: Float = 0.004
    /// Was 0.6 — too aggressive: during a loud Zoom call it zeroed the mic
    /// stream, so every line became "Them" and Cue answered the user's
    /// own questions (or nothing useful). Gate only clear bleed; the
    /// transcript's text dedupe catches the rest.
    private let bleedRatio: Float = 0.28

    func start() throws {
        stop()
        running = true
        micOnly = ProcessInfo.processInfo.environment["CUE_MIC_ONLY"] == "1"

        tap.onPCM = { [weak self] ptr, frames, rate in
            guard let self else { return }
            self.ingest(Array(UnsafeBufferPointer(start: ptr, count: frames)), sourceRate: rate, source: .system)
        }
        if micOnly {
            FileHandle.standardError.write(Data("cue: mic-only capture\n".utf8))
        } else {
            try tap.start()
        }
        try startMic()
    }

    func stop() {
        running = false
        tap.stop()
        stopMic()
        lock.lock()
        pending[.system]?.removeAll(keepingCapacity: true)
        pending[.mic]?.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func startMic() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        default:
            throw CaptureError.micPermission
        }

        let engine = AVAudioEngine()
        // Plain input tap, like a QuickTime recording. Never enable voice
        // processing here: VoiceProcessingIO ducks every other app's output
        // and applies its own gain control, which turns the call itself down.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CaptureError.engine("Microphone format unavailable.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.ingestMic(buffer)
        }
        // A device or format change (headset plugged in, AirPods connecting)
        // stops the engine, and it never restarts on its own.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.scheduleMicRestart(reason: "audio device changed")
        }
        self.engine = engine
        try engine.start()
        Self.diagLog("mic on: \(Self.defaultInputName()), \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    private func stopMic() {
        micRestart?.cancel()
        micRestart = nil
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        engineObserver = nil
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }

    /// Coalesces a burst of change notifications, then rebuilds the engine on
    /// whatever input device is current, retrying until the mic is back.
    private func scheduleMicRestart(reason: String, after delay: TimeInterval = 1) {
        guard running else { return }
        micRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.stopMic()
            do {
                try self.startMic()
                Self.diagLog("mic restarted (\(reason))")
                self.onMicTrouble?(nil)
            } catch {
                Self.diagLog("mic restart failed (\(reason)): \(error.localizedDescription)")
                self.onMicTrouble?("Microphone stopped (\(reason)) — retrying. \(error.localizedDescription)")
                self.scheduleMicRestart(reason: reason, after: 3)
            }
        }
        micRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ingestMic(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        if channels <= 1 {
            memcpy(&mono, src[0], frames * MemoryLayout<Float>.size)
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += src[ch][i] }
                mono[i] = sum / Float(channels)
            }
        }
        // In mic-only test mode the mic stands in for the customer stream.
        let source: AudioSource = micOnly ? .system : .mic
        ingest(mono, sourceRate: buffer.format.sampleRate, source: source)
    }

    private func ingest(_ samples: [Float], sourceRate: Double, source: AudioSource) {
        guard running, !samples.isEmpty else { return }
        let resampled = resample(samples, from: sourceRate, to: targetRate)

        var rms: Float = 0
        vDSP_rmsqv(resampled, 1, &rms, vDSP_Length(resampled.count))

        if source == .system {
            lock.lock()
            systemRMS = max(rms, systemRMS * 0.92)
            lock.unlock()
        } else if !micOnly {
            // Echo gate: while the call plays through the speakers, only pass
            // mic audio clearly louder than the bleed (e.g. while muted in
            // Zoom the OS mic still hears the speakers). There is no echo
            // cancellation (see startMic), so text dedupe handles the rest.
            lock.lock()
            let sys = systemRMS
            lock.unlock()
            let threshold = max(micNoiseFloor, sys * bleedRatio)
            if rms < threshold { return }
        }

        var frames: [[Float]] = []
        lock.lock()
        pending[source, default: []].append(contentsOf: resampled)
        while let count = pending[source]?.count, count >= frameSamples {
            frames.append(Array(pending[source]!.prefix(frameSamples)))
            pending[source]!.removeFirst(frameSamples)
        }
        lock.unlock()

        for frame in frames {
            emit(frame, source: source)
        }
    }

    private func emit(_ slice: [Float], source: AudioSource) {
        var peak: Float = 0
        vDSP_maxmgv(slice, 1, &peak, vDSP_Length(slice.count))
        let level = min(max(peak * 2.4, 0), 1)

        var ints = [Int16](repeating: 0, count: slice.count)
        for i in 0..<slice.count {
            let s = max(-1, min(1, slice[i]))
            ints[i] = Int16(s * Float(Int16.max))
        }
        let data = ints.withUnsafeBytes { Data($0) }
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
            self?.onPCM16?(source, data)
        }
    }

    /// stderr is lost when launched via `open`; append key capture events to
    /// a file so the mic device and any restarts can be checked after a call.
    static func diagLog(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        FileHandle.standardError.write(Data("cue: \(line)\n".utf8))
        guard let data = stamped.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/cue-capture.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// The engine records the system default input through its own private
    /// aggregate device, so name the default input rather than the engine's.
    private static func defaultInputName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return "unknown input" }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name
        else { return "device \(device)" }
        return name.takeRetainedValue() as String
    }

    private func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, abs(from - to) > 1, !input.isEmpty else { return input }
        let ratio = to / from
        let outCount = max(Int(Double(input.count) * ratio), 1)
        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let src = Double(i) / ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, input.count - 1)
            let frac = Float(src - Double(i0))
            output[i] = input[min(i0, input.count - 1)] * (1 - frac) + input[i1] * frac
        }
        return output
    }
}
