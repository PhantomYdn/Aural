@preconcurrency import AVFoundation
import Foundation

/// A stateful, continuous resampler to 16 kHz mono Float — the format the VAD
/// and whisper consume.
///
/// Why this exists: the live VAD segmenter must convert the capture-rate stream
/// (e.g. 44.1 kHz) to 16 kHz to drive the detector. Resampling each captured
/// chunk *independently* (a fresh `AVAudioConverter` per call, flushed to
/// end-of-stream every time) does not preserve the exact input→output sample
/// ratio: each call drops/adds a fraction of a sample (filter priming/flush +
/// rounding), and that error *accumulates* over a recording. Because the
/// segmenter slices speech by sample index, an accumulating offset between the
/// 16 kHz sample clock and the captured audio progressively misaligns segment
/// boundaries — clipping edges first and, once the drift exceeds the idle
/// guard, dropping whole turns (worse the longer you record).
///
/// Feeding one continuous converter the whole stream keeps the cumulative
/// output count locked to the input (the only offset is a one-time, constant
/// filter latency), eliminating the drift.
protocol StreamResampler: AnyObject, Sendable {
    /// Resample the next contiguous block of mono Float samples to 16 kHz.
    func resample(_ samples: [Float]) -> [Float]
    /// Flush samples still buffered inside the resampler (end of stream).
    func flush() -> [Float]
}

/// Pass-through resampler for sources already at 16 kHz (and for tests). Keeps
/// the segmenter's single-clock invariant trivially exact.
final class IdentityResampler: StreamResampler, @unchecked Sendable {
    func resample(_ samples: [Float]) -> [Float] { samples }
    func flush() -> [Float] { [] }
}

/// Continuous `AVAudioConverter`-backed resampler (mono Float, `inputRate` →
/// 16 kHz). One instance is fed the whole capture stream; internal filter state
/// carries across calls, so the cumulative output tracks the input exactly.
///
/// Single-consumer: `VadSegmenter` drives it serially from one Task, so the
/// `pending`-free, per-call input-block pattern needs no locking.
final class AVStreamResampler: StreamResampler, @unchecked Sendable {
    static let outputRate: Double = 16000

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init?(inputRate: Double) {
        guard
            let inFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inFmt, to: outFmt)
        else { return nil }
        // Match the offline/file path's resampling quality.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        self.inputFormat = inFmt
        self.outputFormat = outFmt
    }

    func resample(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let input = makeBuffer(samples)
        // Provide this block once, then report "no data now" so the converter
        // keeps its filter state for the next call instead of flushing.
        nonisolated(unsafe) var provided = false
        return drain { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return input
        }
    }

    func flush() -> [Float] {
        drain { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    /// Pulls converted frames until the converter produces nothing more for the
    /// given input block (input ran dry or end-of-stream).
    private func drain(_ block: @escaping AVAudioConverterInputBlock) -> [Float] {
        var out: [Float] = []
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
                break
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error, withInputFrom: block)
            let frames = Int(buffer.frameLength)
            if frames > 0, let channel = buffer.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
            }
            if status == .error || frames == 0 { break }
            if status == .endOfStream { break }
        }
        return out
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            _ = memcpy(
                buffer.floatChannelData![0], src.baseAddress!,
                samples.count * MemoryLayout<Float>.stride)
        }
        return buffer
    }
}
