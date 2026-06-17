@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Sums microphone stream(s) into the tap stream inside an aggregate
/// device's IO callback (`--mix`).
///
/// Stream layout: an aggregate's input buffer list contains one buffer per
/// input stream — sub-device (mic) streams first, tap streams last. All
/// streams arrive clock-synced at the aggregate rate as float32, so mixing
/// is a frame-wise sum with clamping; mono mic channels are duplicated
/// across tap channels.
final class StreamMixer {
    private let tapChannels: Int
    private var scratch: AVAudioPCMBuffer?
    private var systemScratch: AVAudioPCMBuffer?
    private var micScratch: AVAudioPCMBuffer?

    init(tapChannels: Int) {
        self.tapChannels = max(1, tapChannels)
    }

    /// Mic summed into the tap signal (the `--mix` output).
    func mixedBuffer(
        from inputData: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        produce(from: inputData, tapFormat: tapFormat, scratch: &scratch, includeTap: true)
    }

    /// The tap (system) signal alone, in tap layout — for source attribution.
    func systemBuffer(
        from inputData: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        produce(
            from: inputData, tapFormat: tapFormat, scratch: &systemScratch,
            includeTap: true, includeMic: false)
    }

    /// The microphone signal alone, upmixed into tap layout — for source attribution.
    func micBuffer(
        from inputData: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        produce(
            from: inputData, tapFormat: tapFormat, scratch: &micScratch,
            includeTap: false, includeMic: true)
    }

    /// Builds a tap-layout buffer from the aggregate input list. `includeTap`
    /// seeds it with the tap (system) signal; `includeMic` sums every mic
    /// sub-device stream (mono channels duplicated across tap channels) with
    /// clamping. Frame count comes from the tap stream (the last buffer).
    private func produce(
        from inputData: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat,
        scratch: inout AVAudioPCMBuffer?, includeTap: Bool, includeMic: Bool = true
    ) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let tapBuffer = buffers.last else { return nil }

        let bytesPerFrame = tapChannels * MemoryLayout<Float32>.size
        let frames = Int(tapBuffer.mDataByteSize) / bytesPerFrame
        guard frames > 0,
            let tapSamples = tapBuffer.mData?.assumingMemoryBound(to: Float32.self)
        else { return nil }

        guard let output = Self.reuse(&scratch, format: tapFormat, capacity: AVAudioFrameCount(frames)),
            let outputSamples = output.floatChannelData?[0]  // interleaved
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        if includeTap {
            outputSamples.update(from: tapSamples, count: frames * tapChannels)
        } else {
            for index in 0..<(frames * tapChannels) { outputSamples[index] = 0 }
        }

        guard includeMic else { return output }

        // Sum every mic stream (all buffers except the last) on top.
        for index in 0..<(buffers.count - 1) {
            let micBuffer = buffers[index]
            let micChannels = max(1, Int(micBuffer.mNumberChannels))
            let micFrames = Int(micBuffer.mDataByteSize) / (micChannels * MemoryLayout<Float32>.size)
            guard let micSamples = micBuffer.mData?.assumingMemoryBound(to: Float32.self)
            else { continue }

            let mixFrames = min(frames, micFrames)
            for frame in 0..<mixFrames {
                for channel in 0..<tapChannels {
                    let micChannel = min(channel, micChannels - 1)
                    let index = frame * tapChannels + channel
                    let sum = outputSamples[index] + micSamples[frame * micChannels + micChannel]
                    outputSamples[index] = max(-1.0, min(1.0, sum))
                }
            }
        }
        return output
    }

    private static func reuse(
        _ buffer: inout AVAudioPCMBuffer?, format: AVAudioFormat, capacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        if let buffer, buffer.frameCapacity >= capacity {
            return buffer
        }
        let new = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 4096))
        buffer = new
        return new
    }
}
