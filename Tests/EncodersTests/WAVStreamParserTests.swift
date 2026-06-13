import Foundation
import Testing

@testable import Encoders

@Suite("WAVStreamParser")
struct WAVStreamParserTests {
    /// Reader over an in-memory Data.
    private func reader(for data: Data) -> (Int) throws -> Data {
        var offset = 0
        return { n in
            let take = min(n, data.count - offset)
            defer { offset += take }
            return data.subdata(in: offset..<(offset + take))
        }
    }

    @Test func parsesCanonicalHeader() throws {
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)
        var stream = WAVFileWriter.header(format: format, dataSize: 1000)
        stream.append(Data(count: 1000))
        let header = try WAVStreamParser.parseHeader(read: reader(for: stream))
        #expect(header.format == format)
        #expect(header.dataSize == 1000)
        #expect(!header.dataSizeIsUnknown)
    }

    @Test func parsesStreamingHeader() throws {
        let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
        let stream = WAVFileWriter.header(format: format, dataSize: .max)
        let header = try WAVStreamParser.parseHeader(read: reader(for: stream))
        #expect(header.format == format)
        #expect(header.dataSizeIsUnknown)
    }

    @Test func skipsUnknownChunksBeforeData() throws {
        let format = PCMFormat(sampleRate: 48000, bitsPerSample: 24, channels: 1)
        let canonical = WAVFileWriter.header(format: format, dataSize: 4)
        // Rebuild: RIFF/WAVE + LIST chunk + fmt + data.
        var stream = canonical.prefix(12)  // RIFF + size + WAVE
        stream.append(Data("LIST".utf8))
        stream.append(WAVFileWriter.le32(6))
        stream.append(Data("INFOab".utf8))  // 6 bytes (even)
        stream.append(canonical[12...])  // fmt + data chunks
        let header = try WAVStreamParser.parseHeader(read: reader(for: stream))
        #expect(header.format == format)
        #expect(header.dataSize == 4)
    }

    @Test func rejectsNonRIFF() {
        #expect(throws: WAVParseError.self) {
            _ = try WAVStreamParser.parseHeader(read: reader(for: Data("not audio".utf8)))
        }
    }

    @Test func rejectsFloatCodec() throws {
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 32, channels: 1)
        var stream = WAVFileWriter.header(format: format, dataSize: 0)
        stream[20] = 3  // format tag: IEEE float
        #expect(throws: WAVParseError.self) {
            _ = try WAVStreamParser.parseHeader(read: reader(for: stream))
        }
    }

    @Test func rejectsTruncatedStream() {
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let header = WAVFileWriter.header(format: format, dataSize: 100)
        #expect(throws: WAVParseError.self) {
            _ = try WAVStreamParser.parseHeader(read: reader(for: header.prefix(20)))
        }
    }
}
