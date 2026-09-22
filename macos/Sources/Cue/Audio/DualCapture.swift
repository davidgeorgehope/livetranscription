import Foundation
import AVFoundation
import Accelerate

enum AudioSource: String {
    case system
    case mic
}

/// Captures Core Audio process-tap system audio and (optionally) the
/// microphone as two separate streams, emitting tagged 16 kHz mono PCM16
/// frames per source. Keeping the streams apart is what makes speaker
/// attribution (Them vs Me) possible downstream.
@available(macOS 14.2, *)
final class DualCapture {
    var onPCM16: ((AudioSource, Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let tap = ProcessTapCapture()
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var pending: [AudioSource: [Float]] = [.system: [], .mic: []]
    private var micOnly = false
    private var echoCancellation = true
    private var running = false
    private let targetRate: Double = 16_000
    private let frameSamples = 1_600 // 100ms at 16 kHz

    // Echo gate state: smoothed RMS of what's currently playing on system
    // audio, used to reject mic frames that are just speaker bleed.
    private var systemRMS: Float = 0
    private let micNoiseFloor: Float = 0.004
    /// Was 0.6 — too aggressive: during a loud Zoom call it zeroed the mic
    /// stream, so every line became "Them" and Cue answered the user's
    /// own questions (or nothing useful). Prefer AEC; gate only clear bleed.
    private let bleedRatio: Float = 0.28

    func start(includeMic: Bool, echoCancellation: Bool = true) throws {
        stop()
        running = true
        micOnly = ProcessInfo.processInfo.environment["CUE_MIC_ONLY"] == "1"
        self.echoCancellation = echoCancellation

        tap.onPCM = { [weak self] ptr, frames, rate in
            guard let self else { return }
            self.ingest(Array(UnsafeBufferPointer(start: ptr, count: frames)), sourceRate: rate, source: .system)
        }
        if micOnly {
            FileHandle.standardError.write(Data("cue: mic-only capture\n".utf8))
            if includeMic {
                try startMic()
            }
            return
        }
        try tap.start()

        if includeMic {
            try startMic()
        }
    }

    func stop() {
        running = false
        tap.stop()
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
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
        self.engine = engine
        let input = engine.inputNode
        // Echo cancellation: without this, the mic hears the customer through
        // the speakers and their speech gets attributed to "Me". Apple's voice
        // processing subtracts the system output reference from the mic signal.
        // Trade-off: VoiceProcessingIO ducks other audio (Zoom/speaker volume)
        // and runs AGC that can crush mic levels — hence the settings toggle.
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
                Self.diagLog("mic voice processing (AEC) on")
            } catch {
                Self.diagLog("AEC unavailable: \(error.localizedDescription)")
            }
        } else {
            Self.diagLog("mic voice processing (AEC) off")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CaptureError.engine("Microphone format unavailable.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.ingestMic(buffer)
        }
        try engine.start()
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
            // Echo gate: while the customer is playing through the speakers,
            // only pass mic audio that is clearly louder than the bleed. AEC
            // handles most of it; this catches the residue (e.g. while muted
            // in Zoom the OS mic still hears the speakers).
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
    /// a file so AEC engagement can be verified after the fact.
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
