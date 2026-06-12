import Foundation

/// Conversions from converter-native sample layouts to packed wire formats.
public enum PCMPacker {
    /// Packs interleaved Int32 samples (24-bit audio left-justified in the
    /// high 3 bytes, as produced by AVAudioConverter) into packed little-endian
    /// 24-bit PCM: 3 bytes per sample, LSB dropped.
    public static func pack24(fromInt32 samples: UnsafeBufferPointer<Int32>) -> Data {
        var data = Data(capacity: samples.count * 3)
        for sample in samples {
            let value = UInt32(bitPattern: sample)
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }
        return data
    }
}
