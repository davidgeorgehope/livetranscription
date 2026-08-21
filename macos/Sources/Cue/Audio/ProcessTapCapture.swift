import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

enum CaptureError: LocalizedError {
    case tapCreate(OSStatus)
    case aggregateCreate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)
    case micPermission
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .tapCreate(let s):
            return "Could not create system audio tap (\(s)). Grant Audio Capture / System Audio Recording for Cue, then retry."
        case .aggregateCreate(let s):
            return "Could not create aggregate tap device (\(s))."
        case .ioProc(let s):
            return "Could not attach audio callback (\(s))."
        case .start(let s):
            return "Could not start system audio tap (\(s))."
        case .micPermission:
            return "Microphone permission denied."
        case .engine(let s):
            return s
        }
    }
}

/// Native system-audio capture via Core Audio process tap. No BlackHole.
@available(macOS 14.2, *)
final class ProcessTapCapture {
    var onPCM: ((UnsafePointer<Float>, Int, Double) -> Void)?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var running = false
    private var sampleRate: Double = 48_000

    deinit { stop() }

    func start() throws {
        stop()

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "CueSystemTap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        tapDescription = desc

        var tap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr, tap != 0 else { throw CaptureError.tapCreate(tapStatus) }
        tapID = tap
        sampleRate = Self.readSampleRate(tapID) ?? 48_000

        let tapUID = desc.uuid.uuidString
        let tapList: [[String: Any]] = [[
            kAudioSubTapUIDKey as String: tapUID,
            kAudioSubTapDriftCompensationKey as String: true
        ]]
        let aggUID = "com.davidgeorgehope.cue.aggregate.\(UUID().uuidString)"
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "CueAggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: false,
            kAudioAggregateDeviceTapListKey as String: tapList
        ]

        var agg: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &agg)
        guard aggStatus == noErr, agg != 0 else {
            cleanup()
            throw CaptureError.aggregateCreate(aggStatus)
        }
        aggregateID = agg

        let unmanaged = Unmanaged.passUnretained(self)
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(
            aggregateID,
            ProcessTapCapture.ioProc,
            unmanaged.toOpaque(),
            &procID
        )
        guard procStatus == noErr, let procID else {
            cleanup()
            throw CaptureError.ioProc(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            cleanup()
            throw CaptureError.start(startStatus)
        }
        running = true
    }

    func stop() {
        running = false
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        cleanup()
    }

    private func cleanup() {
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        ioProcID = nil
        tapDescription = nil
    }

    private static let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, clientData in
        guard let clientData else { return noErr }
        let capture = Unmanaged<ProcessTapCapture>.fromOpaque(clientData).takeUnretainedValue()
        capture.handle(list: inInputData)
        return noErr
    }

    private static func readSampleRate(_ tap: AudioObjectID) -> Double? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd.mSampleRate
    }

    private func handle(list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        for buffer in buffers {
            guard let raw = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frames = floatCount / channels
            guard frames > 0 else { continue }
            let src = raw.bindMemory(to: Float.self, capacity: floatCount)
            let rate = sampleRate
            if channels == 1 {
                onPCM?(src, frames, rate)
            } else {
                var mono = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[i * channels + ch] }
                    mono[i] = sum / Float(channels)
                }
                mono.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress { onPCM?(base, frames, rate) }
                }
            }
        }
    }
}
