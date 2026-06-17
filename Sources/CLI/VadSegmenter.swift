import Encoders
import Foundation

/// A live segmenter: cuts a capture-format PCM stream into transcription-sized
/// segments and reports each via `onSegment` as `(pcm, startSeconds, endSeconds)`.
/// `StreamSegmenter` (amplitude threshold) and `VadSegmenter` (VAD) both conform,
/// so `LiveTranscriber` can swap the runtime boundary detector transparently.
protocol SpeechSegmenter: AnyObject {
    var onSegment: ((Data, Double, Double) -> Void)? { get set }
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
/// into an unbounded `AsyncStream`; a single consumer `Task` owns all state —
/// it unpacks to mono Float, resamples to 16 kHz, accumulates fixed windows, and
/// drives the injected `VoiceActivityStream`. Speech turns (`speechStart` →
/// `speechEnd`) become segments; a long monologue is force-cut at
/// `maxWindowSeconds`; sub-`minSegmentSeconds` turns are dropped. Timestamps are
/// derived from the byte clock and stay sample-accurate.
final class VadSegmenter: SpeechSegmenter, @unchecked Sendable {
    var onSegment: ((Data, Double, Double) -> Void)?

    private let format: PCMFormat
    private let classifier: VoiceActivityStream
    private let resample: @Sendable ([Float], Double) throws -> [Float]
    private let windowSamples: Int
    private let maxWindowSeconds: Double
    private let minSegmentSeconds: Double
    private let byteRate: Double
    private let frameSize: Int
    private let inputRate: Double
    /// Audio kept ahead of `rawBaseSeconds` while idle, so a back-dated
    /// `speechStart` (VAD padding) still has its leading audio available.
    private let silenceGuardSeconds = 2.0

    private let continuation: AsyncStream<Data>.Continuation
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var task: Task<Void, Never>? = nil

    // State owned exclusively by the consumer Task (no locks).
    private var raw = Data()
    private var rawBaseSeconds = 0.0
    private var floatAccum = [Float]()
    private var processedSamples16k = 0
    private var triggered = false
    private var segmentStartSeconds = 0.0

    init(
        format: PCMFormat,
        classifier: VoiceActivityStream,
        resample: @escaping @Sendable ([Float], Double) throws -> [Float],
        maxWindowSeconds: Double,
        minSegmentSeconds: Double
    ) {
        self.format = format
        self.classifier = classifier
        self.resample = resample
        self.windowSamples = max(1, classifier.windowSamples)
        self.maxWindowSeconds = maxWindowSeconds
        self.minSegmentSeconds = minSegmentSeconds
        self.byteRate = Double(format.byteRate)
        self.frameSize = max(1, format.bytesPerFrame)
        self.inputRate = Double(format.sampleRate)

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
        raw.append(data)
        let mono = VadSegmenter.unpackMono(data, format: format)
        guard let resampled = try? resample(mono, inputRate) else { return }
        floatAccum.append(contentsOf: resampled)
        while floatAccum.count >= windowSamples {
            let window = Array(floatAccum.prefix(windowSamples))
            floatAccum.removeFirst(windowSamples)
            await processWindow(window)
        }
    }

    private func processWindow(_ window: [Float]) async {
        processedSamples16k += window.count
        let event = try? await classifier.process(window)
        switch event {
        case .speechStart(let sample):
            if !triggered {
                triggered = true
                segmentStartSeconds = max(rawBaseSeconds, Double(sample) / 16000.0)
                dropRaw(before: segmentStartSeconds)
            }
        case .speechEnd(let sample):
            if triggered {
                emit(start: segmentStartSeconds, end: Double(sample) / 16000.0)
                triggered = false
            }
        case .none:
            break
        }

        let now = Double(processedSamples16k) / 16000.0
        if triggered {
            // Long monologue with no pause: force a cut at the window cap.
            if now - segmentStartSeconds >= maxWindowSeconds {
                emit(start: segmentStartSeconds, end: now)
                segmentStartSeconds = now
            }
        } else {
            // Idle: bound memory but keep a guard window for back-dated starts.
            dropRaw(before: now - silenceGuardSeconds)
        }
    }

    private func drain() async {
        if !floatAccum.isEmpty {
            let window = floatAccum
            floatAccum.removeAll()
            await processWindow(window)
        }
        if triggered {
            emit(start: segmentStartSeconds, end: Double(processedSamples16k) / 16000.0)
            triggered = false
        }
        raw.removeAll()
    }

    // MARK: Raw-buffer slicing (time → frame-aligned bytes)

    private func frameAlignedBytes(_ seconds: Double) -> Int {
        let n = Int((seconds * byteRate).rounded())
        return max(0, n - (n % frameSize))
    }

    /// Drops buffered audio older than `seconds`, advancing the base clock.
    private func dropRaw(before seconds: Double) {
        guard seconds > rawBaseSeconds else { return }
        let drop = min(raw.count, frameAlignedBytes(seconds - rawBaseSeconds))
        guard drop > 0 else { return }
        raw.removeFirst(drop)
        rawBaseSeconds += Double(drop) / byteRate
    }

    /// Emits the segment spanning `[start, end]` (trimming leading silence).
    /// Turns shorter than `minSegmentSeconds` are dropped, advancing the clock.
    private func emit(start: Double, end: Double) {
        guard end - start >= minSegmentSeconds else {
            dropRaw(before: end)
            return
        }
        dropRaw(before: start)
        let want = frameAlignedBytes(end - rawBaseSeconds)
        let count = min(raw.count, want)
        guard count > 0 else { return }
        let segment = Data(raw.prefix(count))
        let actualEnd = rawBaseSeconds + Double(count) / byteRate
        onSegment?(segment, start, actualEnd)
        raw.removeFirst(count)
        rawBaseSeconds = actualEnd
    }

    // MARK: PCM → mono Float

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
