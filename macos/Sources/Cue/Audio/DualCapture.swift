import Foundation
import AVFoundation
import Accelerate

/// Mixes Core Audio process-tap system audio with optional microphone, then
/// emits 16 kHz mono WAV chunks (~8s, speech-gated).
@available(macOS 14.2, *)
final class DualCapture {
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let tap = ProcessTapCapture()
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var systemBuf: [Float] = []
    private var micBuf: [Float] = []
    private var mixBuf: [Float] = []
    private var usingMic = false
    private var running = false
    private let targetRate: Double = 16_000
    private let chunkSeconds: Double = 8
    private var lastEmit = Date.distantPast

    func start(includeMic: Bool) throws {
        stop()
        usingMic = includeMic
        running = true

        tap.onPCM = { [weak self] ptr, frames, rate in
            self?.ingest(ptr, frames: frames, sourceRate: rate, system: true)
        }
        try tap.start()

        if includeMic {
            try startMic()
        }
    }

    func stop() {
        running = false
        tap.stop()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        systemBuf.removeAll(keepingCapacity: true)
        micBuf.removeAll(keepingCapacity: true)
        mixBuf.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func startMic() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let ok = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { yes in
                granted = yes
                ok.signal()
            }
            _ = ok.wait(timeout: .now() + 20)
            if !granted { throw CaptureError.micPermission }
        default:
            throw CaptureError.micPermission
        }

        let input = engine.inputNode
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
        ingest(resample(mono, from: buffer.format.sampleRate, to: targetRate), sourceRate: targetRate, system: false)
    }

    private func ingest(_ ptr: UnsafePointer<Float>, frames: Int, sourceRate: Double, system: Bool) {
        ingest(Array(UnsafeBufferPointer(start: ptr, count: frames)), sourceRate: sourceRate, system: system)
    }

    private func ingest(_ samples: [Float], sourceRate: Double, system: Bool) {
        guard running, !samples.isEmpty else { return }
        let data = resample(samples, from: sourceRate, to: targetRate)

        lock.lock()
        if system {
            systemBuf.append(contentsOf: data)
            if systemBuf.count > 160_000 { systemBuf.removeFirst(systemBuf.count - 160_000) }
        } else {
            micBuf.append(contentsOf: data)
            if micBuf.count > 160_000 { micBuf.removeFirst(micBuf.count - 160_000) }
        }
        drainLocked()
        lock.unlock()
    }

    private func drainLocked() {
        let needed = Int(targetRate * 0.02) // 20ms mix step
        while true {
            let haveSystem = systemBuf.count >= needed
            let haveMic = !usingMic || micBuf.count >= needed
            guard haveSystem || (usingMic && haveMic) else { break }

            var mix = [Float](repeating: 0, count: needed)
            if haveSystem {
                for i in 0..<needed { mix[i] += systemBuf[i] }
                systemBuf.removeFirst(needed)
            }
            if usingMic, micBuf.count >= needed {
                for i in 0..<needed { mix[i] += micBuf[i] * 0.85 }
                micBuf.removeFirst(needed)
            } else if usingMic, !haveSystem {
                break
            }
            mixBuf.append(contentsOf: mix)

            var peak: Float = 0
            vDSP_maxmgv(mix, 1, &peak, vDSP_Length(mix.count))
            let level = min(max(peak * 2.4, 0), 1)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }

            let target = Int(targetRate * chunkSeconds)
            if mixBuf.count >= target {
                emitLocked(count: target)
            }
        }
    }

    private func emitLocked(count: Int) {
        let slice = Array(mixBuf.prefix(count))
        mixBuf.removeFirst(count)
        var rms: Float = 0
        vDSP_rmsqv(slice, 1, &rms, vDSP_Length(slice.count))
        // Skip near-silence so we don't burn Whisper on dead air.
        guard rms > 0.008 else { return }
        if Date().timeIntervalSince(lastEmit) < 2 { return }
        lastEmit = Date()
        if let wav = WAVWriter.mono16k(pcm: slice) {
            DispatchQueue.main.async { [weak self] in self?.onChunk?(wav) }
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

enum WAVWriter {
    static func mono16k(pcm: [Float]) -> Data? {
        guard !pcm.isEmpty else { return nil }
        var ints = [Int16](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count {
            let s = max(-1, min(1, pcm[i]))
            ints[i] = Int16(s * Float(Int16.max))
        }
        let dataSize = UInt32(ints.count * 2)
        var data = Data()
        func append(_ s: String) { data.append(contentsOf: s.utf8) }
        func append32(_ v: UInt32) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
        func append16(_ v: UInt16) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(16_000)
        append32(16_000 * 2)
        append16(2)
        append16(16)
        append("data")
        append32(dataSize)
        ints.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
