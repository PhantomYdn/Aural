@preconcurrency import AVFoundation
import Foundation

/// Writes a packed-PCM capture stream into an encoded audio file (M4A/AAC
/// or FLAC) using the native CoreAudio encoders via AVAudioFile.
///
/// Accepts the same interleaved little-endian signed PCM byte stream the
/// capture sessions produce; chunks need not be frame-aligned (a carry
/// buffer reassembles partial frames).
///
/// Thread-safety: writes are serialized by an internal lock.
public final class EncodedFileWriter: @unchecked Sendable {
    public enum WriterError: Error, CustomStringConvertible {
        case unsupportedFormat(AudioFileFormat)
        case cannotCreateFile(String, underlying: Error?)
        case bufferAllocationFailed
        case alreadyFinalized
        case recordingTooShortForFLAC(frames: UInt64)

        public var description: String {
            switch self {
            case .unsupportedFormat(let format):
                return "format '\(format.rawValue)' has no native encoder support"
            case .cannotCreateFile(let path, let underlying):
                let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
                return "cannot create encoded file at \(path)\(detail)"
            case .bufferAllocationFailed:
                return "failed to allocate conversion buffer"
            case .alreadyFinalized:
                return "writer is already finalized"
            case .recordingTooShortForFLAC(let frames):
                return """
                    FLAC output needs at least \(EncodedFileWriter.flacMinimumFrames) \
                    audio frames (~0.1 s); got \(frames). The CoreAudio FLAC encoder \
                    silently produces an unreadable file below one encoder block — \
                    use WAV or M4A for very short recordings.
                    """
            }
        }
    }

    /// The CoreAudio FLAC encoder never flushes a lone partial first block:
    /// files shorter than one encoder block (4608 frames, determined
    /// empirically; FLAC streamable-subset block size) come out as
    /// unreadable 42-byte stubs. Guarded in `finalize()`.
    public static let flacMinimumFrames: UInt64 = 4608

    private let lock = NSLock()
    private var file: AVAudioFile?
    private let processingFormat: AVAudioFormat
    private let pcmFormat: PCMFormat
    private let fileFormat: AudioFileFormat
    private let url: URL
    private var carry = Data()
    private var pcmBytes: UInt64 = 0
    private var finalized = false

    /// Total PCM payload bytes consumed so far.
    public var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return pcmBytes
    }

    public init(url: URL, fileFormat: AudioFileFormat, pcmFormat: PCMFormat) throws {
        self.pcmFormat = pcmFormat
        self.fileFormat = fileFormat
        self.url = url

        let settings: [String: Any]
        switch fileFormat {
        case .m4a:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(pcmFormat.sampleRate),
                AVNumberOfChannelsKey: pcmFormat.channels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .flac:
            settings = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: Double(pcmFormat.sampleRate),
                AVNumberOfChannelsKey: pcmFormat.channels,
                // FLAC tops out at 24-bit; 32-bit captures are stored as 24.
                AVLinearPCMBitDepthKey: min(pcmFormat.bitsPerSample, 24),
            ]
        case .wav, .mp3, .opus:
            throw WriterError.unsupportedFormat(fileFormat)
        }

        // Buffers are handed over as Int16 (16-bit) or Int32 (24/32-bit);
        // AVAudioFile converts to the file's codec internally.
        let commonFormat: AVAudioCommonFormat =
            pcmFormat.bitsPerSample == 16 ? .pcmFormatInt16 : .pcmFormatInt32
        guard
            let processing = AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: Double(pcmFormat.sampleRate),
                channels: AVAudioChannelCount(pcmFormat.channels),
                interleaved: true)
        else {
            throw WriterError.bufferAllocationFailed
        }
        self.processingFormat = processing

        do {
            self.file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: commonFormat,
                interleaved: true)
        } catch {
            throw WriterError.cannotCreateFile(url.path, underlying: error)
        }
    }

    /// Appends packed PCM bytes (any chunking; partial frames are carried).
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { throw WriterError.alreadyFinalized }
        guard let file else { throw WriterError.alreadyFinalized }

        carry.append(data)
        let frameBytes = pcmFormat.bytesPerFrame
        let frames = carry.count / frameBytes
        guard frames > 0 else { return }

        let consumed = frames * frameBytes
        let chunk = carry.prefix(consumed)

        guard let buffer = makeBuffer(from: chunk, frames: frames) else {
            throw WriterError.bufferAllocationFailed
        }
        try file.write(from: buffer)
        pcmBytes += UInt64(consumed)
        carry.removeFirst(consumed)
    }

    /// Flushes the encoder and closes the file. Safe to call repeatedly.
    public func finalize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        // Dropping the last reference flushes and closes the underlying
        // ExtAudioFile (AVAudioFile has no public close on macOS 14).
        file = nil
        carry.removeAll()

        let frames = pcmBytes / UInt64(pcmFormat.bytesPerFrame)
        if fileFormat == .flac && frames < Self.flacMinimumFrames {
            // The encoder left an unreadable stub; remove it and report.
            try? FileManager.default.removeItem(at: url)
            throw WriterError.recordingTooShortForFLAC(frames: frames)
        }
    }

    /// Unpacks packed little-endian PCM into a processing-format buffer.
    private func makeBuffer(from chunk: Data, frames: Int) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let sampleCount = frames * pcmFormat.channels

        switch pcmFormat.bitsPerSample {
        case 16:
            guard let target = buffer.int16ChannelData else { return nil }
            chunk.withUnsafeBytes { raw in
                target[0].update(
                    from: raw.bindMemory(to: Int16.self).baseAddress!, count: sampleCount)
            }
        case 32:
            guard let target = buffer.int32ChannelData else { return nil }
            chunk.withUnsafeBytes { raw in
                target[0].update(
                    from: raw.bindMemory(to: Int32.self).baseAddress!, count: sampleCount)
            }
        case 24:
            guard let target = buffer.int32ChannelData else { return nil }
            chunk.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for sample in 0..<sampleCount {
                    let base = sample * 3
                    let value =
                        UInt32(bytes[base]) << 8
                        | UInt32(bytes[base + 1]) << 16
                        | UInt32(bytes[base + 2]) << 24
                    target[0][sample] = Int32(bitPattern: value)
                }
            }
        default:
            return nil
        }
        return buffer
    }

    deinit {
        try? finalize()
    }
}
