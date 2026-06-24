@preconcurrency import AVFoundation
import CoreAudio
import Encoders
import Foundation

public enum TapEngineError: Error, CustomStringConvertible {
    case microphonePermissionDenied
    case systemAudioPermissionDenied(OSStatus)
    case deviceSelectionFailed(OSStatus)
    case converterCreationFailed
    case engineStartFailed(Error)
    case unsupportedBitDepth(Int)
    case tapCreationFailed(OSStatus)
    case tapPropertyReadFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)

    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            return """
                microphone access denied or the permission prompt could not \
                be answered. Enable your terminal in System Settings > \
                Privacy & Security > Microphone, then retry.
                """
        case .systemAudioPermissionDenied(let status):
            return """
                system audio capture was refused (CoreAudio error \(status)). \
                This usually means the "System Audio Recording" permission is \
                missing. macOS attributes it to the terminal application that \
                launched hark and does not show a prompt: open System \
                Settings > Privacy & Security > Screen & System Audio \
                Recording, click "+" under "System Audio Recording Only", add \
                your terminal app, restart it, and retry.
                """
        case .deviceSelectionFailed(let status):
            return "failed to select input device (CoreAudio error \(status))"
        case .converterCreationFailed:
            return "failed to create audio format converter"
        case .engineStartFailed(let error):
            return "failed to start audio engine: \(error.localizedDescription)"
        case .unsupportedBitDepth(let bits):
            return "unsupported bit depth \(bits) (expected 16, 24, or 32)"
        case .tapCreationFailed(let status):
            return "failed to create process tap (CoreAudio error \(status))"
        case .tapPropertyReadFailed(let status):
            return "failed to read tap properties (CoreAudio error \(status))"
        case .aggregateCreationFailed(let status):
            return "failed to create capture device (CoreAudio error \(status))"
        case .ioProcFailed(let status):
            return "failed to start capture I/O (CoreAudio error \(status))"
        }
    }
}

/// A live audio capture source delivering packed PCM chunks.
public protocol CaptureSession: AnyObject, Sendable {
    /// Starts capture; `onAudio` receives packed PCM in the session's
    /// output format on an audio/IO thread.
    func start(onAudio: @escaping @Sendable (Data) -> Void) throws
    /// Stops capture and releases audio resources.
    func stop()
    /// Attempts to re-establish capture after the OS interrupted it (screen
    /// lock, display/system sleep, device/route change), continuing to deliver
    /// to the original `onAudio`. Returns true once capture is running again.
    /// The default returns false (no recovery — the caller then stops cleanly).
    func restart() -> Bool
}

extension CaptureSession {
    public func restart() -> Bool { false }
}

/// One side of a mixed capture, for source attribution ("You" vs "Others").
public enum CaptureSource: String, Sendable {
    case microphone
    case system
}

/// A capture session that can additionally deliver each source as a separate
/// packed-PCM stream (same output format), in parallel with the mixed `onAudio`
/// stream — enabling deterministic source attribution while `--mix` is active
/// (PRD §6.7a). Set `onSourceAudio` before `start`; it is invoked on the same
/// IO thread as `onAudio`. Only meaningful when a microphone is mixed in.
public protocol MultiTrackCaptureSession: CaptureSession {
    var onSourceAudio: (@Sendable (CaptureSource, Data) -> Void)? { get set }
}

/// Captures audio from a microphone/input device and delivers interleaved
/// little-endian signed PCM in the requested format.
///
/// Capture pipeline: AVAudioEngine input tap (hardware format) ->
/// PCMStreamConverter (rate/width/channel conversion) -> packed PCM bytes.
public final class MicCaptureSession: CaptureSession, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let deviceID: AudioDeviceID?
    private let outputFormat: PCMFormat
    private var converter: PCMStreamConverter?
    private var started = false
    // Stored so the tap can be reinstalled after an interruption (sleep/route
    // change) without the caller's involvement.
    private var onAudio: (@Sendable (Data) -> Void)?
    private let reconfigureQueue = DispatchQueue(label: "hark.mic.reconfigure")
    private var configObserver: NSObjectProtocol?
    private var reconfiguring = false

    /// - Parameters:
    ///   - deviceID: HAL device to capture from; `nil` uses the default input.
    ///   - outputFormat: desired PCM stream format (rate/bits/channels).
    public init(deviceID: AudioDeviceID?, outputFormat: PCMFormat) {
        self.deviceID = deviceID
        self.outputFormat = outputFormat
    }

    /// Requests microphone permission if needed; throws if denied.
    ///
    /// The wait is bounded: for terminal-attributed CLIs macOS sometimes
    /// cannot display the permission prompt at all, in which case the
    /// `requestAccess` callback never fires — failing with guidance beats
    /// hanging forever.
    public static func ensureMicrophonePermission(timeout: TimeInterval = 30) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            FileHandle.standardError.write(Data("""
                hark: requesting microphone access — if a permission \
                prompt appeared, please respond to it…\n
                """.utf8))
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + timeout) == .success else {
                throw TapEngineError.microphonePermissionDenied
            }
            if !granted { throw TapEngineError.microphonePermissionDenied }
        case .denied, .restricted:
            throw TapEngineError.microphonePermissionDenied
        @unknown default:
            throw TapEngineError.microphonePermissionDenied
        }
    }

    /// The hardware format of the selected input, for diagnostics.
    public var hardwareFormatDescription: String {
        let format = engine.inputNode.inputFormat(forBus: 0)
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.commonFormat == .pcmFormatFloat32 ? "float32" : "pcm")"
    }

    /// Starts capture. `onAudio` is invoked on an audio/render thread with
    /// packed PCM chunks in the requested output format; keep it fast and
    /// hand data off to another queue for I/O.
    public func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        precondition(!started, "session already started")
        started = true
        self.onAudio = onAudio
        try installAndStart()

        // AVAudioEngine stops its input tap on device/route changes and on
        // sleep/wake; it posts this notification when that happens. Reinstall
        // the tap and restart the engine so capture survives a screen lock or
        // display/system sleep without the caller doing anything.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.reconfigureQueue.async {
                guard let self, self.started, !self.reconfiguring else { return }
                _ = self.reinstall()
            }
        }
    }

    /// Points the engine's input at the selected device (no-op for default).
    private func selectDeviceIfNeeded() throws {
        guard let deviceID else { return }
        var id = deviceID
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw TapEngineError.deviceSelectionFailed(-1)
        }
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw TapEngineError.deviceSelectionFailed(status) }
    }

    /// Builds the converter for the current hardware format, installs the tap,
    /// and starts the engine. Used by `start` and by recovery.
    private func installAndStart() throws {
        let inputNode = engine.inputNode
        try selectDeviceIfNeeded()
        // Re-read the hardware format every time — it can change across a route
        // change (e.g. internal mic → Bluetooth). The output format is constant,
        // so downstream sinks/segmenter are unaffected.
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        let converter = try PCMStreamConverter(
            inputFormat: hardwareFormat, outputFormat: outputFormat)
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self, let converter = self.converter, let onAudio = self.onAudio else { return }
            if let data = converter.convert(buffer) {
                onAudio(data)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw TapEngineError.engineStartFailed(error)
        }
    }

    /// Tears down and re-establishes the tap/engine. Serialized on
    /// `reconfigureQueue`; returns whether the engine is running again.
    @discardableResult
    private func reinstall() -> Bool {
        guard started else { return false }
        reconfiguring = true
        defer { reconfiguring = false }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        do {
            try installAndStart()
            return engine.isRunning
        } catch {
            return false
        }
    }

    /// Re-establishes capture after an external interruption (driven by the
    /// stall watchdog). Returns true once the engine is running again.
    public func restart() -> Bool {
        guard started else { return false }
        return reconfigureQueue.sync { reinstall() }
    }

    /// Stops capture and tears down the tap.
    public func stop() {
        guard started else { return }
        started = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
