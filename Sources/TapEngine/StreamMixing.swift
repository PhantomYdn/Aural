import Encoders
import Foundation

/// Sums two same-format packed-PCM buffers sample-wise with clamping. Used to
/// mix the ScreenCaptureKit system and microphone streams (already converted to
/// the same output format) in software.
enum StreamMixing {
    static func sum(_ a: Data, _ b: Data, format: PCMFormat) -> Data {
        let n = min(a.count, b.count)
        guard n > 0 else { return Data() }
        var out = Data(count: n)
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                out.withUnsafeMutableBytes { po in
                    switch format.bitsPerSample {
                    case 16:
                        let sa = pa.bindMemory(to: Int16.self)
                        let sb = pb.bindMemory(to: Int16.self)
                        let so = po.bindMemory(to: Int16.self)
                        for i in 0..<(n / 2) {
                            let s = Int32(sa[i]) + Int32(sb[i])
                            so[i] = Int16(max(-32768, min(32767, s)))
                        }
                    case 32:
                        let sa = pa.bindMemory(to: Int32.self)
                        let sb = pb.bindMemory(to: Int32.self)
                        let so = po.bindMemory(to: Int32.self)
                        for i in 0..<(n / 4) {
                            let s = Int64(sa[i]) + Int64(sb[i])
                            so[i] = Int32(max(Int64(Int32.min), min(Int64(Int32.max), s)))
                        }
                    case 24:
                        // 3-byte little-endian samples.
                        func read(_ p: UnsafeRawBufferPointer, _ base: Int) -> Int32 {
                            let v = UInt32(p[base]) | UInt32(p[base + 1]) << 8 | UInt32(p[base + 2]) << 16
                            return Int32(bitPattern: (v & 0x80_0000) != 0 ? v | 0xFF00_0000 : v)
                        }
                        for i in 0..<(n / 3) {
                            let base = i * 3
                            let s = max(-8_388_608, min(8_388_607, read(pa, base) + read(pb, base)))
                            let u = UInt32(bitPattern: s)
                            po[base] = UInt8(u & 0xFF)
                            po[base + 1] = UInt8((u >> 8) & 0xFF)
                            po[base + 2] = UInt8((u >> 16) & 0xFF)
                        }
                    default:
                        for i in 0..<n { po[i] = pa[i] }
                    }
                }
            }
        }
        return out
    }
}
