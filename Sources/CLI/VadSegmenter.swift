import Encoders
import Foundation

/// A live segmenter: cuts a capture-format PCM stream into transcription-sized
/// segments and reports each via `onSegment` as `(pcm, format, startSeconds,
/// endSeconds)`. The emitted `format` is the segment's own PCM format —
/// `StreamSegmenter` (amplitude threshold) passes the capture format through
/// unchanged, while `VadSegmenter` emits already-resampled 16 kHz mono audio —
/// so `LiveTranscriber` can stage each segment correctly regardless of which
/// boundary detector produced it.
protocol SpeechSegmenter: AnyObject {
    var onSegment: ((Data, PCMFormat, Double, Double) -> Void)? { get set }
    /// Feed captured PCM (called serially from the capture I/O queue).
    func consume(_ data: Data)
    /// Flush any trailing speech and release resources.
    func finish()
}

/// A speech boundary in the 16 kHz sample domain, abstracting a voice-activity
/// model so `VadSegmenter` stays free of any engine SDK and is unit-testable
/// with a synthetic stream.
enum VoiceActivityEvent: Sendable {
    case speechStart(sample: Int)
    case speechEnd(sample: Int)
}

/// A streaming voice-activity detector over 16 kHz mono Float windows. Maintains
/// its own state across calls (Silero-style hysteresis) and emits start/end
/// boundary events. `windowSamples` is the fixed window the detector consumes.
protocol VoiceActivityStream: AnyObject, Sendable {
    var windowSamples: Int { get }
    func process(_ window: [Float]) async throws -> VoiceActivityEvent?
}

/// VAD-driven live segmenter (PRD §6.7 — the runtime fix for the amplitude-only
/// "delay in a sound" heuristic). Captured PCM is fed (cheaply) on the I/O queue
/// into an unbounded `AsyncStream`; a single consumer `Task` owns all state.
///
/// The consumer unpacks each chunk to mono Float and resamples it to 16 kHz
/// through one **continuous** resampler, appending to a single retained 16 kHz
/// buffer (the "slab"). The VAD is driven from that same buffer, and speech
/// turns are sliced **directly out of it by 16 kHz sample index** — so there is
/// exactly one clock and segment boundaries can never drift from the audio (the
/// earlier two-clock design, which mapped VAD sample indices back onto a
/// separate capture-rate byte buffer, accumulated resampler drift and dropped
/// whole turns on long recordings). Segments are emitted as 16 kHz mono 16-bit
/// PCM — already in whisper's native format, so no second resample is needed.
///
/// A speech turn (`speechStart` → `speechEnd`) becomes a segment; a long
/// monologue is force-cut at `maxWindowSeconds`; sub-`minSegmentSeconds` turns
/// are dropped. While idle, the slab is trimmed to a short guard window so a
/// back-dated `speechStart` (VAD padding) still has its leading audio.
final class VadSegmenter: SpeechSegmenter, @unchecked Sendable {
    var onSegment: ((Data, PCMFormat, Double, Double) -> Void)?

    /// The PCM format every VAD segment is emitted in (whisper's native format).
    static let segmentFormat = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
    private static let outputRate = 16000

    private let captureFormat: PCMFormat
    private let classifier: VoiceActivityStream
    private let resampler: StreamResampler
    private let windowSamples: Int
    private let maxWindowSamples: Int
    private let minSegmentSamples: Int
    /// Audio kept ahead of the live point while idle, so a back-dated
    /// `speechStart` (VAD padding) still has its leading audio available.
    private let guardSamples = 2 * 16000

    private let continuation: AsyncStream<Data>.Continuation
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var task: Task<Void, Never>? = nil

    // State owned exclusively by the consumer Task (no locks). A single 16 kHz
    // clock: `slabBase + windowOffset` is the absolute count of 16 kHz samples
    // fed to the VAD, the same index space VAD events report in.
    private var slab = [Float]()  // retained 16 kHz samples
    private var slabBase = 0  // absolute 16 kHz index of slab[0]
    private var windowOffset = 0  // index within slab of the next sample to feed the VAD
    private var triggered = false
    private var segmentStart = 0  // absolute 16 kHz index of the open turn

    init(
        format: PCMFormat,
        classifier: VoiceActivityStream,
        resampler: StreamResampler,
        maxWindowSeconds: Double,
        minSegmentSeconds: Double
    ) {
        self.captureFormat = format
        self.classifier = classifier
        self.resampler = resampler
        self.windowSamples = max(1, classifier.windowSamples)
        self.maxWindowSamples = max(1, Int(maxWindowSeconds * Double(Self.outputRate)))
        self.minSegmentSamples = max(0, Int(minSegmentSeconds * Double(Self.outputRate)))

        let (stream, continuation) = AsyncStream<Data>.makeStream(
            of: Data.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.task = Task { [self] in
            for await data in stream { await consumeAsync(data) }
            await drain()
            done.signal()
        }
    }

    func consume(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        if finished { return }
        finished = true
        continuation.finish()
        done.wait()
    }

    // MARK: Consumer (single Task)

    private func consumeAsync(_ data: Data) async {
        guard !data.isEmpty else { return }
        let mono = VadSegmenter.unpackMono(data, format: captureFormat)
        let resampled = resampler.resample(mono)
        guard !resampled.isEmpty else { return }
        slab.append(contentsOf: resampled)
        await processReadyWindows()
    }

    /// Feeds every full window now available in the slab to the VAD.
    private func processReadyWindows() async {
        while slab.count - windowOffset >= windowSamples {
            let window = Array(slab[windowOffset..<windowOffset + windowSamples])
            windowOffset += windowSamples
            await processWindow(window)
        }
    }

    private func processWindow(_ window: [Float]) async {
        let event = try? await classifier.process(window)
        switch event {
        case .speechStart(let sample):
            if !triggered {
                triggered = true
                // Can't predate audio we still hold (idle trim may have dropped
                // earlier samples); clamp to the slab base.
                segmentStart = max(slabBase, sample)
                dropSlab(before: segmentStart)
            }
        case .speechEnd(let sample):
            if triggered {
                emit(start: segmentStart, end: max(segmentStart, sample))
                triggered = false
            }
        case .none:
            break
        }

        let now = slabBase + windowOffset
        if triggered {
            // Long monologue with no pause: force a cut at the window cap.
            if now - segmentStart >= maxWindowSamples {
                emit(start: segmentStart, end: now)
                segmentStart = now
            }
        } else {
            // Idle: bound memory but keep a guard window for back-dated starts.
            dropSlab(before: now - guardSamples)
        }
    }

    private func drain() async {
        // Flush the resampler tail so the final words aren't lost, then process
        // whatever windows (full or partial) remain.
        let tail = resampler.flush()
        if !tail.isEmpty { slab.append(contentsOf: tail) }
        await processReadyWindows()
        if slab.count > windowOffset {
            let window = Array(slab[windowOffset...])
            windowOffset = slab.count
            await processWindow(window)
        }
        if triggered {
            emit(start: segmentStart, end: slabBase + windowOffset)
            triggered = false
        }
        slab.removeAll()
    }

    // MARK: Slab management (single 16 kHz clock)

    /// Drops 16 kHz samples older than the absolute `index`, never discarding
    /// audio not yet fed to the VAD.
    private func dropSlab(before index: Int) {
        let drop = min(windowOffset, index - slabBase)
        guard drop > 0 else { return }
        slab.removeFirst(drop)
        slabBase += drop
        windowOffset -= drop
    }

    /// Emits the segment spanning the absolute 16 kHz range `[start, end)`,
    /// sliced directly from the slab. Turns shorter than `minSegmentSeconds`
    /// are dropped. Advances the slab past the emitted audio.
    private func emit(start: Int, end: Int) {
        guard end - start >= minSegmentSamples else {
            dropSlab(before: end)
            return
        }
        let lo = max(0, start - slabBase)
        let hi = min(slab.count, end - slabBase)
        guard hi > lo else {
            dropSlab(before: end)
            return
        }
        let pcm = VadSegmenter.packInt16(slab[lo..<hi])
        let startSeconds = Double(slabBase + lo) / Double(Self.outputRate)
        let endSeconds = Double(slabBase + hi) / Double(Self.outputRate)
        onSegment?(pcm, Self.segmentFormat, startSeconds, endSeconds)
        dropSlab(before: slabBase + hi)
    }

    // MARK: PCM packing/unpacking

    /// Packs 16 kHz mono Float samples (-1…1) into little-endian Int16 PCM.
    static func packInt16(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            var i = 0
            for sample in samples {
                let scaled = (Double(sample) * 32767.0).rounded()
                out[i] = Int16(max(-32768.0, min(32767.0, scaled)))
                i += 1
            }
        }
        return data
    }

    /// Unpacks packed little-endian PCM to mono Float (channels averaged,
    /// normalized to -1…1). Mirrors `peakAmplitude`'s bit-depth handling.
    static func unpackMono(_ data: Data, format: PCMFormat) -> [Float] {
        let channels = max(1, format.channels)
        switch format.bitsPerSample {
        case 16:
            return data.withUnsafeBytes { raw -> [Float] in
                let samples = raw.bindMemory(to: Int16.self)
                let frames = samples.count / channels
                var out = [Float](); out.reserveCapacity(frames)
                var i = 0
                for _ in 0..<frames {
                    var acc: Int32 = 0
                    for c in 0..<channels { acc += Int32(samples[i + c]) }
                    out.append(Float(acc) / Float(channels) / 32768.0)
                    i += channels
                }
                return out
            }
        case 32:
            return data.withUnsafeBytes { raw -> [Float] in
                let samples = raw.bindMemory(to: Int32.self)
                let frames = samples.count / channels
                var out = [Float](); out.reserveCapacity(frames)
                var i = 0
                for _ in 0..<frames {
                    var acc: Double = 0
                    for c in 0..<channels { acc += Double(samples[i + c]) }
                    out.append(Float(acc / Double(channels) / 2147483648.0))
                    i += channels
                }
                return out
            }
        case 24:
            return data.withUnsafeBytes { raw -> [Float] in
                let bytes = raw.bindMemory(to: UInt8.self)
                let bytesPerFrame = 3 * channels
                let frames = bytes.count / bytesPerFrame
                var out = [Float](); out.reserveCapacity(frames)
                var i = 0
                for _ in 0..<frames {
                    var acc: Double = 0
                    for c in 0..<channels {
                        let b = i + c * 3
                        let value = UInt32(bytes[b]) << 8 | UInt32(bytes[b + 1]) << 16
                            | UInt32(bytes[b + 2]) << 24
                        acc += Double(Int32(bitPattern: value) >> 8)
                    }
                    out.append(Float(acc / Double(channels) / 8388608.0))
                    i += bytesPerFrame
                }
                return out
            }
        default:
            return []
        }
    }
}
