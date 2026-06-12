/// Interleaved linear-PCM stream parameters.
public struct PCMFormat: Equatable, Sendable {
    /// Samples per second (Hz).
    public let sampleRate: Int
    /// Bits per sample: 16, 24, or 32 (signed integer, little-endian).
    public let bitsPerSample: Int
    /// Channel count (1 = mono, 2 = stereo).
    public let channels: Int

    public init(sampleRate: Int, bitsPerSample: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.channels = channels
    }

    /// Bytes per sample frame (all channels).
    public var bytesPerFrame: Int { channels * bitsPerSample / 8 }

    /// Bytes per second of audio.
    public var byteRate: Int { sampleRate * bytesPerFrame }
}
