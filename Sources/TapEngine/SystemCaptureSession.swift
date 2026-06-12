@preconcurrency import AVFoundation
import CoreAudio
import Encoders
import Foundation

/// Captures system or per-application audio through a Core Audio process
/// tap (macOS 14.4+), delivering packed PCM in the requested format.
///
/// Pipeline: process tap -> private aggregate device (tap in the tap list,
/// optionally the microphone as a drift-compensated sub-device for `--mix`)
/// -> IOProc -> PCMStreamConverter -> packed PCM bytes.
///
/// Reading a tap requires the "System Audio Recording" TCC permission; for
/// command-line tools macOS attributes it to the launching terminal.
public final class SystemCaptureSession: CaptureSession, @unchecked Sendable {
    private let scope: TapScope
    private let micDeviceUID: String?
    private let outputFormat: PCMFormat

    private var tap: ProcessTap?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: PCMStreamConverter?
    private var mixer: StreamMixer?
    private let ioQueue = DispatchQueue(label: "aural.tap.io")
    private var started = false

    /// - Parameters:
    ///   - scope: what to capture (global system audio or specific processes).
    ///   - micDeviceUID: input device to mix in (`--mix`); nil for tap only.
    ///   - outputFormat: desired PCM stream format.
    public init(scope: TapScope, micDeviceUID: String?, outputFormat: PCMFormat) {
        self.scope = scope
        self.micDeviceUID = micDeviceUID
        self.outputFormat = outputFormat
    }

    /// Tap stream format, for diagnostics. Empty before `start`.
    public private(set) var sourceFormatDescription = ""

    public func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        precondition(!started, "session already started")
        started = true

        // 1. Create the tap. A TCC denial surfaces here or at IO start.
        let tap = try ProcessTap(scope: scope)
        self.tap = tap
        let tapASBD = tap.format
        sourceFormatDescription =
            "\(Int(tapASBD.mSampleRate)) Hz, \(tapASBD.mChannelsPerFrame) ch (tap)"

        // 2. Build the private aggregate device hosting the tap (and the
        // mic as a drift-compensated sub-device when mixing).
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "aural-capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        if let micDeviceUID {
            // The mic joins as a drift-compensated sub-device. The tap is
            // the preferred timebase so system audio keeps its native rate
            // (a 16 kHz Bluetooth mic must not downclock the whole capture).
            composition[kAudioAggregateDeviceSubDeviceListKey] = [
                [
                    kAudioSubDeviceUIDKey: micDeviceUID,
                    kAudioSubDeviceDriftCompensationKey: true,
                ]
            ]
            composition[kAudioAggregateDeviceMainSubDeviceKey] = tap.uid
        }

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            teardown()
            throw TapEngineError.aggregateCreationFailed(status)
        }
        aggregateID = newAggregateID

        // 3. Pin the aggregate clock to the tap's native rate. When a
        // sub-device (e.g., a 16 kHz Bluetooth mic) joins, the HAL may
        // otherwise clock the whole aggregate at the mic's rate, degrading
        // the system-audio capture. Failure is tolerated; the actual rate
        // is read back below either way.
        Self.setNominalSampleRate(of: newAggregateID, to: tapASBD.mSampleRate)
        let actualRate = Self.nominalSampleRate(of: newAggregateID) ?? tapASBD.mSampleRate

        // Converter input = tap stream's channel layout at the aggregate's
        // *actual* clock rate. Neither the tap's own ASBD (pre-aggregate)
        // nor the stream's virtual format (not clock-adjusted) can be
        // trusted alone. The tap stream is the last input stream
        // (sub-devices come first).
        let streamFormats = try Self.inputStreamFormats(of: newAggregateID)
        guard var liveASBD = streamFormats.last else {
            teardown()
            throw TapEngineError.aggregateCreationFailed(noErr)
        }
        liveASBD.mSampleRate = actualRate
        sourceFormatDescription =
            "\(Int(liveASBD.mSampleRate)) Hz, \(liveASBD.mChannelsPerFrame) ch (tap stream)"
        guard let tapFormat = AVAudioFormat(streamDescription: &liveASBD) else {
            teardown()
            throw TapEngineError.converterCreationFailed
        }
        let converter = try PCMStreamConverter(
            inputFormat: tapFormat, outputFormat: outputFormat)
        self.converter = converter

        // When mixing, mic stream(s) are summed into the tap stream before
        // conversion.
        let mixer = micDeviceUID != nil ? StreamMixer(tapChannels: Int(liveASBD.mChannelsPerFrame)) : nil
        self.mixer = mixer

        // 4. IO callback: wrap tap bytes, convert, deliver.
        let debug = ProcessInfo.processInfo.environment["AURAL_DEBUG"] != nil
        nonisolated(unsafe) var callbackCount = 0
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let converter = self.converter else { return }

            let ablPointer = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            if debug {
                callbackCount += 1
                if callbackCount <= 3 {
                    var info = "AURAL_DEBUG cb#\(callbackCount): buffers=\(ablPointer.count)"
                    for (i, b) in ablPointer.enumerated() {
                        var nonZero = false
                        if let p = b.mData?.assumingMemoryBound(to: Float32.self) {
                            let n = Int(b.mDataByteSize) / 4
                            for j in 0..<min(n, 4096) where p[j] != 0 { nonZero = true; break }
                        }
                        info += " [\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize) nonzero=\(nonZero)"
                    }
                    FileHandle.standardError.write(Data((info + "\n").utf8))
                }
            }
            guard ablPointer.count > 0 else { return }

            let buffer: AVAudioPCMBuffer?
            if let mixer = self.mixer {
                buffer = mixer.mixedBuffer(from: inInputData, tapFormat: tapFormat)
            } else {
                buffer = AVAudioPCMBuffer(
                    pcmFormat: tapFormat,
                    bufferListNoCopy: inInputData,
                    deallocator: nil)
            }
            guard let buffer, buffer.frameLength > 0 else { return }
            if let data = converter.convert(buffer) {
                onAudio(data)
            }
        }
        guard status == noErr, ioProcID != nil else {
            teardown()
            throw TapEngineError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw TapEngineError.ioProcFailed(status)
        }
    }

    public func stop() {
        guard started else { return }
        teardown()
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        tap?.destroy()
        tap = nil
    }

    deinit {
        teardown()
    }

    private static func nominalRateAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func setNominalSampleRate(of deviceID: AudioObjectID, to rate: Double) {
        var address = nominalRateAddress()
        var value = rate
        _ = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
        var address = nominalRateAddress()
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
            value > 0
        else { return nil }
        return value
    }

    /// Virtual formats of a device's input streams, in stream order
    /// (matching the IOProc buffer list).
    private static func inputStreamFormats(
        of deviceID: AudioObjectID
    ) throws -> [AudioStreamBasicDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { throw TapEngineError.tapPropertyReadFailed(status) }
        let count = Int(size) / MemoryLayout<AudioStreamID>.stride
        guard count > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: count)
        status = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw TapEngineError.tapPropertyReadFailed(status) }

        return try streams.map { stream in
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(
                stream, &formatAddress, 0, nil, &asbdSize, &asbd)
            guard status == noErr else { throw TapEngineError.tapPropertyReadFailed(status) }
            return asbd
        }
    }
}
