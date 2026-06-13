import Encoders
import Foundation

/// Peak amplitude (0…1) of packed little-endian signed PCM.
func peakAmplitude(of data: Data, format: PCMFormat) -> Double {
    switch format.bitsPerSample {
    case 16:
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var peak: Int32 = 0
            for s in samples { peak = max(peak, abs(Int32(s))) }
            return Double(peak) / 32768.0
        }
    case 32:
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int32.self)
            var peak: Int64 = 0
            for s in samples { peak = max(peak, abs(Int64(s))) }
            return Double(peak) / 2147483648.0
        }
    case 24:
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var peak: Int64 = 0
            var i = 0
            while i + 2 < bytes.count {
                let value =
                    UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]) << 16
                    | UInt32(bytes[i + 2]) << 24
                peak = max(peak, abs(Int64(Int32(bitPattern: value)) >> 8))
                i += 3
            }
            return Double(peak) / 8388608.0
        }
    default:
        return 1.0  // unknown depth: treat as non-silent
    }
}

/// Splits a PCM stream into numbered files on sustained silence
/// (PRD §6.5, US04: `--split silence=SEC`).
///
/// Semantics: once `silenceSeconds` of continuous audio below the
/// threshold accumulates, the current chunk is finalized (it keeps that
/// silence — no audio is ever dropped). The next chunk opens with the
/// next write, but re-splitting stays disarmed until sound resumes, so a
/// long pause yields one follow-up chunk, not many.
final class SilenceSplittingSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private let silenceByteThreshold: UInt64
    private let linearThreshold: Double
    private let format: PCMFormat
    private let makeChunkSink: (Int) throws -> AudioSink
    private var current: AudioSink?
    private var chunkIndex = 0
    private var silentRunBytes: UInt64 = 0
    private var armed = false
    private var totalBytes: UInt64 = 0
    let label: String

    /// - Parameters:
    ///   - silenceSeconds: continuous silence that triggers a split.
    ///   - thresholdDBFS: peak level below which audio counts as silent.
    init(
        silenceSeconds: Double,
        thresholdDBFS: Double,
        format: PCMFormat,
        label: String,
        makeChunkSink: @escaping (Int) throws -> AudioSink
    ) {
        self.silenceByteThreshold = max(1, UInt64(silenceSeconds * Double(format.byteRate)))
        self.linearThreshold = pow(10.0, thresholdDBFS / 20.0)
        self.format = format
        self.makeChunkSink = makeChunkSink
        self.label = label
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return }

        if current == nil {
            chunkIndex += 1
            current = try makeChunkSink(chunkIndex)
            silentRunBytes = 0
            armed = false
        }
        try current?.write(data)
        totalBytes += UInt64(data.count)

        let silent = peakAmplitude(of: data, format: format) < linearThreshold
        if silent {
            guard armed else { return }
            silentRunBytes += UInt64(data.count)
            if silentRunBytes >= silenceByteThreshold {
                try current?.finalize()
                current = nil
            }
        } else {
            armed = true
            silentRunBytes = 0
        }
    }

    func finalize() throws {
        lock.lock()
        defer { lock.unlock() }
        try current?.finalize()
        current = nil
    }

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }
}
