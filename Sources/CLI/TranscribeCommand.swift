import ArgumentParser
import Foundation

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

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard ["whisper", "cloud"].contains(engine) else {
            throw ValidationError("unknown engine '\(engine)' (known: whisper, cloud).")
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
            throw AuralError.unavailable(
                "stdin transcription lands later in Phase 4; pass a file path for now.")
        }
        if FileManager.default.fileExists(atPath: input) {
            Log.verbose("normalizing '\(input)' to 16 kHz mono WAV")
            return try AudioPipeline.normalizeFileForWhisper(input)
        }
        throw AuralError.noInput(
            "input '\(input)' is neither a file, '-', nor a known device UID (see 'aural devices').")
    }
}
