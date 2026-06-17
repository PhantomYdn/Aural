@preconcurrency import AVFoundation
import CoreAudio
import Encoders
import Foundation
import Testing

@testable import TapEngine

@Suite("StreamMixing.sum")
struct StreamMixingTests {
    // MARK: packing helpers

    private func pack16(_ samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    private func unpack16(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map {
            Int16(littleEndian: data.subdata(in: $0..<($0 + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
        }
    }

    private func pack32(_ samples: [Int32]) -> Data {
        var d = Data(capacity: samples.count * 4)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    private func unpack32(_ data: Data) -> [Int32] {
        stride(from: 0, to: data.count, by: 4).map {
            Int32(littleEndian: data.subdata(in: $0..<($0 + 4)).withUnsafeBytes { $0.load(as: Int32.self) })
        }
    }

    private func pack24(_ samples: [Int32]) -> Data {
        var d = Data(capacity: samples.count * 3)
        for s in samples {
            let u = UInt32(bitPattern: s)
            d.append(UInt8(u & 0xFF))
            d.append(UInt8((u >> 8) & 0xFF))
            d.append(UInt8((u >> 16) & 0xFF))
        }
        return d
    }

    private func unpack24(_ data: Data) -> [Int32] {
        stride(from: 0, to: data.count, by: 3).map { base in
            let v = UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16
            return Int32(bitPattern: (v & 0x80_0000) != 0 ? v | 0xFF00_0000 : v)
        }
    }

    private func format(_ bits: Int) -> PCMFormat {
        PCMFormat(sampleRate: 48000, bitsPerSample: bits, channels: 2)
    }

    // MARK: 16-bit

    @Test func sums16Bit() {
        let a = pack16([100, -200, 0, 30000])
        let b = pack16([50, -300, 0, 1000])
        let out = unpack16(StreamMixing.sum(a, b, format: format(16)))
        #expect(out == [150, -500, 0, 31000])
    }

    @Test func clamps16BitPositiveAndNegative() {
        let a = pack16([30000, -30000])
        let b = pack16([30000, -30000])
        let out = unpack16(StreamMixing.sum(a, b, format: format(16)))
        #expect(out == [32767, -32768])
    }

    // MARK: 32-bit

    @Test func sumsAndClamps32Bit() {
        let a = pack32([1000, Int32.max, Int32.min])
        let b = pack32([2000, 1, -1])
        let out = unpack32(StreamMixing.sum(a, b, format: format(32)))
        #expect(out == [3000, Int32.max, Int32.min])
    }

    // MARK: 24-bit

    @Test func sums24BitWithSignAndClamp() {
        let a = pack24([100, -100, 8_000_000, -8_000_000])
        let b = pack24([50, -50, 8_000_000, -8_000_000])
        let out = unpack24(StreamMixing.sum(a, b, format: format(24)))
        #expect(out == [150, -150, 8_388_607, -8_388_608])
    }

    // MARK: edges

    @Test func usesShorterLengthOnMismatch() {
        let a = pack16([100, 200, 300])
        let b = pack16([1, 2])
        let out = unpack16(StreamMixing.sum(a, b, format: format(16)))
        #expect(out == [101, 202])
    }

    @Test func emptyInputsYieldEmpty() {
        #expect(StreamMixing.sum(Data(), Data(), format: format(16)).isEmpty)
    }
}

/// Source attribution (PRD §6.7a): from one aggregate input list (mic + tap),
/// `StreamMixer` produces the mix, the system-only signal, and the mic-only
/// signal (mono upmixed across tap channels).
@Suite("StreamMixer per-source")
struct StreamMixerSourceTests {
    private let tapFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!

    /// Runs `body` with an aggregate-style buffer list: a mono mic stream first,
    /// the stereo tap stream last (matching the IOProc layout).
    private func withList(
        mic: [Float], tapStereo: [Float], _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        var micData = mic
        var tapData = tapStereo
        micData.withUnsafeMutableBytes { micRaw in
            tapData.withUnsafeMutableBytes { tapRaw in
                let abl = AudioBufferList.allocate(maximumBuffers: 2)
                abl[0] = AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(micRaw.count),
                    mData: micRaw.baseAddress)
                abl[1] = AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(tapRaw.count),
                    mData: tapRaw.baseAddress)
                body(UnsafePointer(abl.unsafeMutablePointer))
                free(abl.unsafeMutablePointer)
            }
        }
    }

    private func interleaved(_ buffer: AVAudioPCMBuffer?, frames: Int) -> [Float] {
        guard let buffer, let p = buffer.floatChannelData?[0] else { return [] }
        return (0..<(frames * 2)).map { p[$0] }
    }

    private func approxEqual(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 }
    }

    @Test func separatesSystemAndMicAndMix() {
        let mixer = StreamMixer(tapChannels: 2)
        // 2 frames: tap (L,R,L,R), mic mono (m0, m1).
        let tap: [Float] = [0.1, 0.2, 0.3, 0.4]
        let mic: [Float] = [0.5, 0.6]
        withList(mic: mic, tapStereo: tap) { list in
            let system = interleaved(mixer.systemBuffer(from: list, tapFormat: tapFormat), frames: 2)
            #expect(approxEqual(system, [0.1, 0.2, 0.3, 0.4]))  // tap only

            let micOnly = interleaved(mixer.micBuffer(from: list, tapFormat: tapFormat), frames: 2)
            #expect(approxEqual(micOnly, [0.5, 0.5, 0.6, 0.6]))  // mono upmixed

            let mixed = interleaved(mixer.mixedBuffer(from: list, tapFormat: tapFormat), frames: 2)
            #expect(approxEqual(mixed, [0.6, 0.7, 0.9, 1.0]))  // tap + mic
        }
    }
}
