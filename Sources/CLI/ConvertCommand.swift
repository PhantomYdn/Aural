@preconcurrency import AVFoundation
import ArgumentParser
import Encoders
import Foundation
import TapEngine

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert an audio file between formats.",
        discussion: """
            Reads WAV, AIFF, CAF, M4A, FLAC, and MP3; writes WAV, M4A, or \
            FLAC. Sample rate, bit depth, and channel count default to the \
            source values (capped at 2 channels).
            """
    )

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Input audio file.", valueName: "path"))
    var input: String

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Output file path; the extension picks the format (.wav, .m4a, .flac).",
        valueName: "path"))
    var output: String

    @Option(name: .customLong("format"), help: ArgumentHelp(
        "Force the output format (wav, m4a, flac), overriding the file extension.",
        valueName: "format"))
    var forcedFormat: String?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Output sample rate in Hz (default: source rate).", valueName: "hz"))
    var rate: Int?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Output bits per sample: 16, 24, or 32 (default: source depth or 16).",
        valueName: "bits"))
    var bits: Int?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Output channels: 1 or 2 (default: source, capped at 2).", valueName: "n"))
    var channels: Int?

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        if let bits, ![16, 24, 32].contains(bits) {
            throw ValidationError("--bits must be 16, 24, or 32.")
        }
        if let rate, !(1...768_000).contains(rate) {
            throw ValidationError("--rate must be between 1 and 768000 Hz.")
        }
        if let channels, !(1...2).contains(channels) {
            throw ValidationError("--channels must be 1 or 2.")
        }
        if let forcedFormat, AudioFileFormat(rawValue: forcedFormat.lowercased()) == nil {
            let known = AudioFileFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("unknown format '\(forcedFormat)' (known: \(known)).")
        }
    }

    func run() throws {
        try runMapped(verbose: options.verbose) {
            guard FileManager.default.fileExists(atPath: input) else {
                throw AuralError.noInput("no such file: \(input)")
            }
            let source: AVAudioFile
            do {
                source = try AVAudioFile(forReading: URL(fileURLWithPath: input))
            } catch {
                throw AuralError.noInput(
                    "cannot read '\(input)' as audio: \(error.localizedDescription)")
            }

            // Output parameters default to the source's.
            let sourceFormat = source.processingFormat
            let sourceBits = Int(source.fileFormat.streamDescription.pointee.mBitsPerChannel)
            let pcmFormat = PCMFormat(
                sampleRate: rate ?? Int(sourceFormat.sampleRate),
                bitsPerSample: bits ?? ([16, 24, 32].contains(sourceBits) ? sourceBits : 16),
                channels: channels ?? min(2, max(1, Int(sourceFormat.channelCount)))
            )

            let fileFormat: AudioFileFormat
            if let forcedFormat {
                fileFormat = AudioFileFormat(rawValue: forcedFormat.lowercased())!
            } else if let detected = AudioFileFormat.detect(fromPath: output) {
                fileFormat = detected
            } else {
                let known = AudioFileFormat.allCases.map(\.rawValue).joined(separator: ", ")
                throw AuralError.usage(
                    "cannot infer format from '\(output)'; use a known extension (\(known)) or --format.")
            }
            Log.verbose("""
                \(input) (\(Int(sourceFormat.sampleRate)) Hz, \(sourceFormat.channelCount) ch) -> \
                \(output) (\(fileFormat.rawValue), \(pcmFormat.sampleRate) Hz, \
                \(pcmFormat.bitsPerSample)-bit, \(pcmFormat.channels) ch)
                """)

            let sink = try RecordingSession.makeFileSink(
                path: output, fileFormat: fileFormat, format: pcmFormat)
            let converter: PCMStreamConverter
            do {
                converter = try PCMStreamConverter(
                    inputFormat: sourceFormat, outputFormat: pcmFormat)
            } catch let error as TapEngineError {
                throw AuralError.software(error.description)
            }

            // Decode -> convert -> encode in 32k-frame chunks.
            let chunkFrames: AVAudioFrameCount = 32768
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat, frameCapacity: chunkFrames)
            else {
                throw AuralError.software("failed to allocate read buffer")
            }
            do {
                // Note: read(into:) at EOF throws nilError on current macOS
                // instead of returning 0 frames; bound by framePosition.
                while source.framePosition < source.length {
                    try source.read(into: buffer, frameCount: chunkFrames)
                    if buffer.frameLength == 0 { break }
                    if let data = converter.convert(buffer) {
                        try sink.write(data)
                    }
                }
                if let tail = converter.finish() {
                    try sink.write(tail)
                }
                try sink.finalize()
            } catch let error as AuralError {
                throw error
            } catch {
                throw AuralError.ioError("conversion failed: \(error)")
            }
            Log.verbose("wrote \(sink.bytesWritten) PCM bytes to \(sink.label)")
        }
    }
}
