import Foundation

/// Minimal Ogg bitstream muxer: frames packets into Ogg pages (RFC 3533) for
/// Opus output. Handles the lacing/segment table, page sequencing, and the Ogg
/// CRC. Pages are emitted to a `FileHandle`.
final class OggMuxer {
    /// Ogg page header type flags.
    struct PageType {
        static let continued: UInt8 = 0x01
        static let beginStream: UInt8 = 0x02
        static let endStream: UInt8 = 0x04
    }

    private let serial: UInt32
    private let handle: FileHandle
    private var pageSequence: UInt32 = 0

    init(serial: UInt32, handle: FileHandle) {
        self.serial = serial
        self.handle = handle
    }

    /// Writes one Ogg page carrying `packets` (each a whole Opus packet). The
    /// caller must keep the total segment count ≤ 255 (≈ ≤255 small packets).
    func writePage(packets: [Data], granulePosition: UInt64, headerType: UInt8) throws {
        precondition(!packets.isEmpty, "an Ogg page needs at least one packet")

        // Lacing: each packet -> N*255-byte segments + one terminal segment
        // (0–254); a length that is a multiple of 255 gets a trailing 0.
        var segments: [UInt8] = []
        var body = Data()
        for packet in packets {
            var remaining = packet.count
            while remaining >= 255 {
                segments.append(255)
                remaining -= 255
            }
            segments.append(UInt8(remaining))
            body.append(packet)
        }
        precondition(segments.count <= 255, "too many segments for one Ogg page")

        var page = Data()
        page.append(contentsOf: Array("OggS".utf8))  // capture pattern
        page.append(0)  // stream structure version
        page.append(headerType)
        appendLE(&page, granulePosition)  // 8 bytes
        appendLE(&page, serial)  // 4 bytes
        appendLE(&page, pageSequence)  // 4 bytes
        let crcOffset = page.count
        appendLE(&page, UInt32(0))  // CRC placeholder
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(body)

        // CRC is computed over the whole page with the CRC field zeroed.
        let crc = Self.crc32(page)
        withUnsafeBytes(of: crc.littleEndian) { raw in
            for i in 0..<4 { page[crcOffset + i] = raw[i] }
        }

        try handle.write(contentsOf: page)
        pageSequence &+= 1
    }

    private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Ogg CRC-32: polynomial 0x04C11DB7, MSB-first, no reflection, init 0.
    static let crcTable: [UInt32] = (0..<256).map { index in
        var r = UInt32(index) << 24
        for _ in 0..<8 {
            r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : (r << 1)
        }
        return r
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            let index = Int(((crc >> 24) & 0xFF) ^ UInt32(byte))
            crc = (crc << 8) ^ crcTable[index]
        }
        return crc
    }
}
