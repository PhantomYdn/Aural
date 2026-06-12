import ArgumentParser
import CoreAudio
import DeviceManager
import Encoders
import Foundation
import TapEngine

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record audio from a microphone or input device.",
        discussion: """
            Records from the default input device, or from a specific device \
            selected with -d/--device (UIDs are listed by 'aural devices'). \
            Recording stops after -t/--duration seconds, or on Ctrl+C \
            (SIGINT/SIGTERM), finalizing the file so it remains playable.
            """
    )

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Input device UID (see 'aural devices'). Defaults to the system default input.",
        valueName: "uid"))
    var device: String?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Output file path (.wav).", valueName: "path"))
    var output: String?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Sample rate in Hz.", valueName: "hz"))
    var rate: Int = 44100

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Bits per sample: 16, 24, or 32.", valueName: "bits"))
    var bits: Int = 16

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Channel count: 1 or 2. Defaults to the device's input channels (capped at 2).",
        valueName: "n"))
    var channels: Int?

    @Option(name: [.customShort("t"), .long], help: ArgumentHelp(
        "Stop recording after this many seconds.", valueName: "sec"))
    var duration: Double?

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard [16, 24, 32].contains(bits) else {
            throw ValidationError("--bits must be 16, 24, or 32.")
        }
        guard (1...768_000).contains(rate) else {
            throw ValidationError("--rate must be between 1 and 768000 Hz.")
        }
        if let channels, !(1...2).contains(channels) {
            throw ValidationError("--channels must be 1 or 2.")
        }
        if let duration, duration <= 0 {
            throw ValidationError("--duration must be positive.")
        }
        guard output != nil else {
            throw ValidationError("-o/--output is required (stdout streaming lands later in Phase 1).")
        }
    }

    func run() throws {
        try runMapped(verbose: options.verbose) {
            try RecordingSession(
                deviceUID: device,
                outputPath: output,
                rate: rate,
                bits: bits,
                channels: channels,
                duration: duration
            ).run()
        }
    }
}

/// Drives a capture session: device resolution, writer setup, lifetime
/// control (duration/signals), and final stats.
struct RecordingSession {
    let deviceUID: String?
    let outputPath: String?
    let rate: Int
    let bits: Int
    let channels: Int?
    let duration: Double?

    func run() throws {
        // 1. Resolve the input device.
        let inputDevice = try resolveInputDevice()
        let deviceID: AudioDeviceID? = deviceUID.map { _ in AudioDeviceID(inputDevice.objectID) }
        let channelCount = channels ?? min(2, max(1, inputDevice.inputChannels))
        let format = PCMFormat(sampleRate: rate, bitsPerSample: bits, channels: channelCount)
        Log.verbose(
            "source: \(inputDevice.name) [\(inputDevice.uid)] -> \(rate) Hz, \(bits)-bit, \(channelCount) ch")

        // 2. Microphone permission (TCC).
        do {
            try MicCaptureSession.ensureMicrophonePermission()
        } catch let error as TapEngineError {
            throw AuralError.noPermission(error.description)
        }

        // 3. Set up the output writer.
        guard let outputPath else {
            throw AuralError.usage("output path missing")
        }
        let url = URL(fileURLWithPath: outputPath)
        let writer: WAVFileWriter
        do {
            writer = try WAVFileWriter(destination: .file(url), format: format)
        } catch {
            throw AuralError.ioError("cannot open output file: \(error)")
        }

        // 4. Capture.
        let session = MicCaptureSession(deviceID: deviceID, outputFormat: format)
        let ioQueue = DispatchQueue(label: "aural.record.io")
        let failure = FailureBox()
        let done = DispatchSemaphore(value: 0)

        do {
            try session.start { data in
                ioQueue.async {
                    do {
                        try writer.write(data)
                    } catch {
                        if failure.store(error) { done.signal() }
                    }
                }
            }
        } catch let error as TapEngineError {
            throw AuralError.software(error.description)
        }
        Log.verbose("recording started (hardware: \(session.hardwareFormatDescription))")

        // 5. Wait for duration elapse or a write failure.
        let startedAt = Date()
        if let duration {
            _ = done.wait(timeout: .now() + duration)
        } else {
            done.wait()
        }

        // 6. Tear down: stop capture, drain pending writes, finalize header.
        session.stop()
        ioQueue.sync {}
        try? writer.finalize()

        if let error = failure.take() {
            throw AuralError.ioError("write failed: \(error)")
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        Log.verbose(
            "wrote \(writer.bytesWritten) bytes (\(String(format: "%.1f", elapsed)) s) to \(url.path)")
    }

    private func resolveInputDevice() throws -> AudioDevice {
        if let deviceUID {
            let devices: [AudioDevice]
            do {
                devices = try DeviceManager.listDevices(scope: .all)
            } catch {
                throw AuralError.software("failed to enumerate devices: \(error)")
            }
            guard let device = devices.first(where: { $0.uid == deviceUID }) else {
                throw AuralError.noInput(
                    "no device with UID '\(deviceUID)' (see 'aural devices')")
            }
            guard device.inputChannels > 0 else {
                throw AuralError.noInput(
                    "device '\(device.name)' has no input channels")
            }
            return device
        }
        do {
            guard let device = try DeviceManager.defaultInputDevice() else {
                throw AuralError.noInput("no default input device available")
            }
            return device
        } catch let error as AuralError {
            throw error
        } catch {
            throw AuralError.noInput("no default input device available (\(error))")
        }
    }
}

/// Thread-safe single-error container.
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    /// Stores the first error; returns true if this call stored it.
    func store(_ newError: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil else { return false }
        error = newError
        return true
    }

    func take() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
