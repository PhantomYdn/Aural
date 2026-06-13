import Foundation
import Testing

@testable import Encoders

@Suite("PCMFormat")
struct PCMFormatTests {
    @Test func derivedValues() {
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)
        #expect(format.bytesPerFrame == 4)
        #expect(format.byteRate == 176400)
    }

    @Test func mono24Bit() {
        let format = PCMFormat(sampleRate: 48000, bitsPerSample: 24, channels: 1)
        #expect(format.bytesPerFrame == 3)
        #expect(format.byteRate == 144000)
    }
}

@Suite("WAV header")
struct WAVHeaderTests {
    @Test func golden44ByteHeader() {
        // 44100 Hz, 16-bit, mono, 4 bytes of payload.
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let header = WAVFileWriter.header(format: format, dataSize: 4)
        let expected: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,  // "RIFF"
            0x28, 0x00, 0x00, 0x00,  // riff size = 4 + 44 - 8 = 40
            0x57, 0x41, 0x56, 0x45,  // "WAVE"
            0x66, 0x6D, 0x74, 0x20,  // "fmt "
            0x10, 0x00, 0x00, 0x00,  // fmt chunk size 16
            0x01, 0x00,              // PCM
            0x01, 0x00,              // 1 channel
            0x44, 0xAC, 0x00, 0x00,  // 44100
            0x88, 0x58, 0x01, 0x00,  // byte rate 88200
            0x02, 0x00,              // block align 2
            0x10, 0x00,              // 16 bits
            0x64, 0x61, 0x74, 0x61,  // "data"
            0x04, 0x00, 0x00, 0x00,  // data size 4
        ]
        #expect(header.count == WAVFileWriter.headerSize)
        #expect([UInt8](header) == expected)
    }

    @Test func streamingHeaderUsesUnknownSize() {
        let format = PCMFormat(sampleRate: 48000, bitsPerSample: 16, channels: 2)
        let header = WAVFileWriter.header(format: format, dataSize: .max)
        #expect([UInt8](header[4..<8]) == [0xFF, 0xFF, 0xFF, 0xFF])
        #expect([UInt8](header[40..<44]) == [0xFF, 0xFF, 0xFF, 0xFF])
    }
}

@Suite("WAVFileWriter")
struct WAVFileWriterTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-test-\(UUID().uuidString).wav")
    }

    @Test func finalizePatchesSizes() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try WAVFileWriter(destination: .file(url), format: format)
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        try writer.write(payload)
        try writer.finalize()

        let contents = try Data(contentsOf: url)
        #expect(contents.count == WAVFileWriter.headerSize + payload.count)
        // RIFF size = total - 8.
        #expect([UInt8](contents[4..<8]) == [0x2A, 0x00, 0x00, 0x00])
        // data size = 6.
        #expect([UInt8](contents[40..<44]) == [0x06, 0x00, 0x00, 0x00])
        // Payload intact.
        #expect(contents[44...] == payload)
    }

    @Test func writeAfterFinalizeThrows() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try WAVFileWriter(destination: .file(url), format: format)
        try writer.finalize()
        #expect(throws: WAVFileWriter.WriterError.self) {
            try writer.write(Data([0x00]))
        }
    }

    @Test func doubleFinalizeIsSafe() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try WAVFileWriter(destination: .file(url), format: format)
        try writer.finalize()
        try writer.finalize()  // must not throw or corrupt
    }

    @Test func rejectsUnsupportedBitDepth() {
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 12, channels: 1)
        #expect(throws: WAVFileWriter.WriterError.self) {
            _ = try WAVFileWriter(destination: .file(temporaryFile()), format: format)
        }
    }
}

@Suite("PCMPacker")
struct PCMPackerTests {
    @Test func packs24BitDroppingLowByte() {
        let samples: [Int32] = [
            Int32(bitPattern: 0x12_34_56_78),
            Int32(bitPattern: 0xFF_FF_FF_00 as UInt32),  // -256 -> 24-bit 0xFFFFFF
        ]
        let data = samples.withUnsafeBufferPointer { PCMPacker.pack24(fromInt32: $0) }
        #expect([UInt8](data) == [0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF])
    }
}

@Suite("AudioFileFormat")
struct AudioFileFormatTests {
    @Test func detectsByExtension() {
        #expect(AudioFileFormat.detect(fromPath: "/tmp/a.wav") == .wav)
        #expect(AudioFileFormat.detect(fromPath: "/tmp/a.M4A") == .m4a)
        #expect(AudioFileFormat.detect(fromPath: "rec.flac") == .flac)
        #expect(AudioFileFormat.detect(fromPath: "x.mp3") == .mp3)
        #expect(AudioFileFormat.detect(fromPath: "x.opus") == .opus)
        #expect(AudioFileFormat.detect(fromPath: "noext") == nil)
        #expect(AudioFileFormat.detect(fromPath: "a.ogg") == nil)
    }

    @Test func writabilityMatrix() {
        #expect(AudioFileFormat.wav.isWritable)
        #expect(AudioFileFormat.m4a.isWritable)
        #expect(AudioFileFormat.flac.isWritable)
        #expect(!AudioFileFormat.mp3.isWritable)
        #expect(!AudioFileFormat.opus.isWritable)
    }
}
