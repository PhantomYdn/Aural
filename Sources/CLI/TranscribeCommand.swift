import ArgumentParser
import CoreAudio
import DeviceManager
import Encoders
import Foundation
import TapEngine

struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe an audio file, stdin stream, or live source.",
        discussion: """
            Input is normalized to 16 kHz mono internally, so any readable \
            audio file (wav, m4a, flac, mp3, aiff, caf) works without prior \
            conversion. Requires a local whisper.cpp installation \
            (brew install whisper-cpp) and a ggml model (--model or \
            AURAL_WHISPER_MODEL).
            """
    )

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Audio file path, '-' for stdin, or an input-device UID to record and transcribe.",
        valueName: "path|-|uid"))
    var input: String

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Transcription engine: whisper (local) or cloud (post-MVP).", valueName: "engine"))
    var engine: String = "whisper"

    @Option(help: ArgumentHelp(
        "Path to a ggml Whisper model (default: $AURAL_WHISPER_MODEL).", valueName: "path"))
    var model: String?

    @Option(help: ArgumentHelp(
        "Spoken language code (e.g. en, de); omit for the model default.", valueName: "code"))
    var language: String?

    @Option(name: .customLong("output-format"), help: ArgumentHelp(
        "Transcript format: txt, srt, or json.", valueName: "format"))
    var outputFormat: TranscriptOutputFormat = .txt

    @Option(name: .customLong("input-rate"), help: ArgumentHelp(
        "Sample rate of raw PCM on stdin (ignored when the stream is WAV).",
        valueName: "hz"))
    var inputRate: Int = 44100

    @Option(name: .customLong("input-bits"), help: ArgumentHelp(
        "Bits per sample of raw PCM on stdin: 16, 24, or 32.", valueName: "bits"))
    var inputBits: Int = 16

    @Option(name: .customLong("input-channels"), help: ArgumentHelp(
        "Channels of raw PCM on stdin: 1 or 2.", valueName: "n"))
    var inputChannels: Int = 1

    @Option(name: [.customShort("t"), .long], help: ArgumentHelp(
        "Stop a device capture after this many seconds (otherwise Ctrl+C).",
        valueName: "sec"))
    var duration: Double?

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard ["whisper", "cloud"].contains(engine) else {
            throw ValidationError("unknown engine '\(engine)' (known: whisper, cloud).")
        }
        guard [16, 24, 32].contains(inputBits) else {
            throw ValidationError("--input-bits must be 16, 24, or 32.")
        }
        guard (1...2).contains(inputChannels) else {
            throw ValidationError("--input-channels must be 1 or 2.")
        }
        guard (1...768_000).contains(inputRate) else {
            throw ValidationError("--input-rate must be between 1 and 768000 Hz.")
        }
        if let duration, duration <= 0 {
            throw ValidationError("--duration must be positive.")
        }
    }

    func run() throws {
        Log.isVerbose = options.verbose
        do {
            try transcribe()
        } catch let error as AuralError {
            Log.error(error.message)
            throw error.code.exitCode
        } catch let error as TranscriptionError {
            Log.error(error.description)
            switch error {
            case .engineNotFound:
                throw AuralExitCode.unavailable.exitCode
            case .modelMissing, .modelNotFound:
                throw AuralExitCode.noInput.exitCode
            case .engineFailed(let code):
                // Propagate the engine's exit code through the pipeline (US03).
                throw ExitCode(code)
            case .outputMissing:
                throw AuralExitCode.software.exitCode
            }
        }
    }

    private func transcribe() throws {
        guard engine == "whisper" else {
            throw AuralError.unavailable(
                "cloud transcription backends are post-MVP (see PRD §4.2); use --engine whisper.")
        }
        guard let binary = WhisperEngine.discover() else {
            throw TranscriptionError.engineNotFound
        }
        let modelPath = try WhisperEngine.resolveModel(flag: model)
        Log.verbose("engine: \(binary.path), model: \(modelPath)")

        let wavFile = try normalizedInput()
        defer { try? FileManager.default.removeItem(at: wavFile) }

        let whisper = WhisperEngine(binary: binary, modelPath: modelPath)
        let transcript = try whisper.transcribe(
            wavFile: wavFile, language: language, format: outputFormat)
        print(transcript, terminator: transcript.hasSuffix("\n") ? "" : "\n")
    }

    /// Resolves `-i` into a whisper-ready WAV file.
    private func normalizedInput() throws -> URL {
        if input == "-" {
            return try normalizedStdin()
        }
        if FileManager.default.fileExists(atPath: input) {
            Log.verbose("normalizing '\(input)' to 16 kHz mono WAV")
            return try AudioPipeline.normalizeFileForWhisper(input)
        }
        if let device = try? DeviceManager.listDevices(scope: .input)
            .first(where: { $0.uid == input })
        {
            return try captureForTranscription(device: device)
        }
        throw AuralError.noInput(
            "input '\(input)' is neither a file, '-', nor a known input-device UID (see 'aural devices').")
    }

    /// Records from the device into memory at whisper's format, then stages
    /// a temporary WAV (PRD §6.6: record in memory, pipe to engine).
    private func captureForTranscription(device: AudioDevice) throws -> URL {
        do {
            try MicCaptureSession.ensureMicrophonePermission()
        } catch let error as TapEngineError {
            throw AuralError.noPermission(error.description)
        }

        let format = AudioPipeline.whisperFormat
        let session = MicCaptureSession(
            deviceID: AudioDeviceID(device.objectID), outputFormat: format)
        let accumulator = CaptureAccumulator()
        let done = DispatchSemaphore(value: 0)
        let budget = duration.map { seconds in
            ByteBudget(
                bytes: UInt64(seconds * Double(format.byteRate)),
                frameSize: format.bytesPerFrame)
        }

        do {
            try session.start { data in
                let (chunk, exhausted) = budget?.consume(data) ?? (data, false)
                if !chunk.isEmpty { accumulator.append(chunk) }
                if exhausted { done.signal() }
            }
        } catch let error as TapEngineError {
            throw AuralError.software(error.description)
        }

        let watcher = SignalWatcher()
        watcher.watch([SIGINT, SIGTERM]) { done.signal() }
        if duration == nil {
            Log.notice("recording from \(device.name) — press Ctrl+C to stop and transcribe")
        }
        done.wait()
        watcher.cancel()
        session.stop()

        let captured = accumulator.take()
        Log.verbose("captured \(captured.count) bytes from \(device.name)")
        guard !captured.isEmpty else {
            throw AuralError.noInput("no audio captured from \(device.name)")
        }

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-capture-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(destination: .file(staged), format: format)
        try writer.write(captured)
        try writer.finalize()
        return staged
    }

    /// Reads audio from stdin (WAV stream or raw PCM) into a temporary WAV
    /// in the original format, then normalizes it for whisper.
    private func normalizedStdin() throws -> URL {
        guard isatty(STDIN_FILENO) == 0 else {
            throw AuralError.usage(
                "refusing to read audio from a terminal; pipe data into 'transcribe -i -'.")
        }
        let reader = StreamReader(handle: .standardInput)

        // Sniff: WAV stream (record --stdout) or raw PCM (record default)?
        let sniff = reader.peek(4)
        let format: PCMFormat
        var remainingPayload: UInt64 = .max
        if sniff == Data("RIFF".utf8) {
            let header: WAVStreamHeader
            do {
                header = try WAVStreamParser.parseHeader { try reader.next($0) }
            } catch let error as WAVParseError {
                throw AuralError.noInput("stdin: \(error.description)")
            }
            format = header.format
            if !header.dataSizeIsUnknown { remainingPayload = UInt64(header.dataSize) }
            Log.verbose(
                "stdin: WAV stream, \(format.sampleRate) Hz, \(format.bitsPerSample)-bit, \(format.channels) ch")
        } else {
            format = PCMFormat(
                sampleRate: inputRate, bitsPerSample: inputBits, channels: inputChannels)
            Log.verbose(
                "stdin: raw PCM assumed \(format.sampleRate) Hz, \(format.bitsPerSample)-bit, \(format.channels) ch")
        }

        // Stage payload into a temp WAV (original format), then reuse the
        // file-normalization path for rate/channel conversion.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-stdin-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staged) }
        let writer = try WAVFileWriter(destination: .file(staged), format: format)
        while remainingPayload > 0 {
            let chunk = try reader.next(Int(min(65536, remainingPayload)))
            if chunk.isEmpty { break }
            try writer.write(chunk)
            remainingPayload -= UInt64(chunk.count)
        }
        try writer.finalize()
        Log.verbose("stdin: staged \(writer.bytesWritten) PCM bytes")
        guard writer.bytesWritten > 0 else {
            throw AuralError.noInput("stdin contained no audio payload")
        }
        return try AudioPipeline.normalizeFileForWhisper(staged.path)
    }
}

/// Thread-safe in-memory capture buffer.
final class CaptureAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Buffered reader with peek support over a FileHandle.
final class StreamReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Returns the next `n` bytes without consuming (fewer at EOF).
    func peek(_ n: Int) -> Data {
        fill(to: n)
        return buffer.prefix(n)
    }

    /// Consumes and returns up to `n` bytes (fewer only at EOF).
    func next(_ n: Int) throws -> Data {
        fill(to: n)
        let take = min(n, buffer.count)
        let chunk = buffer.prefix(take)
        buffer.removeFirst(take)
        return Data(chunk)
    }

    private func fill(to n: Int) {
        while buffer.count < n {
            let chunk = handle.readData(ofLength: max(n - buffer.count, 65536))
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
    }
}
