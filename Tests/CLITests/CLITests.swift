import ArgumentParser
import Encoders
import Foundation
import Testing

@testable import CLI

@Suite("Record argument parsing")
struct RecordParsingTests {
    @Test func defaults() throws {
        let record = try Record.parse(["-o", "out.wav"])
        #expect(record.rate == 44100)
        #expect(record.bits == 16)
        #expect(record.channels == nil)
        #expect(record.duration == nil)
        #expect(record.device == nil)
        #expect(!record.wavToStdout)
        #expect(!record.noOutput)
    }

    @Test func parsesAllOptions() throws {
        let record = try Record.parse([
            "-d", "SomeUID", "-o", "x.wav", "-r", "48000", "-b", "24", "-c", "2", "-t", "30.5",
        ])
        #expect(record.device == "SomeUID")
        #expect(record.output == "x.wav")
        #expect(record.rate == 48000)
        #expect(record.bits == 24)
        #expect(record.channels == 2)
        #expect(record.duration == 30.5)
    }

    @Test(arguments: [
        ["-o", "x.wav", "-b", "12"],          // bad bit depth
        ["-o", "x.wav", "-c", "3"],           // bad channel count
        ["-o", "x.wav", "-t", "0"],           // non-positive duration
        ["-o", "x.wav", "-r", "0"],           // bad rate
        ["-o", "x.wav", "--stdout"],          // -o conflicts with --stdout
        ["-o", "x.wav", "--no-output"],       // -o conflicts with --no-output
        ["--stdout", "--no-output"],          // stream conflicts with dry run
        ["-o", "x.wav", "--system", "--app", "foo"],         // system is everything
        ["-o", "x.wav", "--app", "a", "--exclude-app", "b"],  // include vs exclude
        ["-o", "x.wav", "--mix"],                             // mix needs a tap mode
        ["-o", "x.wav", "--system", "-d", "UID"],             // device needs --mix
    ])
    func rejectsInvalidCombinations(_ arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Record.parse(arguments)
        }
    }

    @Test(arguments: [
        ["-o", "x.wav", "--system"],
        ["-o", "x.wav", "--system", "--mix"],
        ["-o", "x.wav", "--system", "--mix", "-d", "SomeUID"],
        ["-o", "x.wav", "--app", "com.example.app", "--app", "123"],
        ["-o", "x.wav", "--app", "123", "--mix"],
        ["-o", "x.wav", "--exclude-app", "com.example.app"],
    ])
    func acceptsTapModeCombinations(_ arguments: [String]) throws {
        _ = try Record.parse(arguments)
    }

    @Test func repeatableAppFlagAccumulates() throws {
        let record = try Record.parse(
            ["-o", "x.wav", "--app", "com.a", "--app", "com.b", "--app", "42"])
        #expect(record.apps == ["com.a", "com.b", "42"])
    }
}

@Suite("Devices argument parsing")
struct DevicesParsingTests {
    @Test func defaultsToAllDevices() throws {
        let devices = try Devices.parse([])
        #expect(!devices.listInputs)
        #expect(!devices.listOutputs)
        #expect(!devices.json)
    }

    @Test func rejectsInputsAndOutputsTogether() {
        #expect(throws: (any Error).self) {
            _ = try Devices.parse(["--list-inputs", "--list-outputs"])
        }
    }
}

@Suite("Exit codes")
struct ExitCodeTests {
    @Test func sysexitsValues() {
        #expect(AuralExitCode.ok.rawValue == 0)
        #expect(AuralExitCode.usage.rawValue == 64)
        #expect(AuralExitCode.noInput.rawValue == 66)
        #expect(AuralExitCode.unavailable.rawValue == 69)
        #expect(AuralExitCode.software.rawValue == 70)
        #expect(AuralExitCode.ioError.rawValue == 74)
        #expect(AuralExitCode.noPermission.rawValue == 77)
    }

    @Test func errorFactoriesCarryCodes() {
        #expect(AuralError.noInput("x").code == .noInput)
        #expect(AuralError.unavailable("x").code == .unavailable)
        #expect(AuralError.ioError("x").code == .ioError)
        #expect(AuralError.noPermission("x").code == .noPermission)
    }
}

@Suite("Byte budget")
struct ByteBudgetTests {
    @Test func trimsFinalChunkToExactBudget() {
        let budget = ByteBudget(bytes: 10, frameSize: 2)
        let first = budget.consume(Data(count: 6))
        #expect(first.chunk.count == 6)
        #expect(!first.exhausted)
        let second = budget.consume(Data(count: 6))
        #expect(second.chunk.count == 4)
        #expect(second.exhausted)
        let third = budget.consume(Data(count: 6))
        #expect(third.chunk.isEmpty)
        #expect(third.exhausted)
    }

    @Test func roundsBudgetDownToFrameBoundary() {
        let budget = ByteBudget(bytes: 7, frameSize: 4)
        let result = budget.consume(Data(count: 8))
        #expect(result.chunk.count == 4)  // 7 rounded down to one 4-byte frame
        #expect(result.exhausted)
    }
}

@Suite("Split parsing")
struct SplitSpecTests {
    @Test func parsesDurationAndSilence() throws {
        let duration = try SplitSpec.parse("duration=300")
        #expect(duration == .duration(300))
        let silence = try SplitSpec.parse("silence=1.5")
        #expect(silence == .silence(1.5))
    }

    @Test(arguments: ["duration", "duration=", "duration=0", "duration=-5",
                      "gap=3", "=5", "duration=abc"])
    func rejectsMalformedSpecs(_ raw: String) {
        #expect(throws: AuralError.self) { _ = try SplitSpec.parse(raw) }
    }

    @Test func chunkPathNumbering() {
        #expect(chunkPath(base: "/x/rec.m4a", index: 1) == "/x/rec_001.m4a")
        #expect(chunkPath(base: "/x/rec.m4a", index: 42) == "/x/rec_042.m4a")
        #expect(chunkPath(base: "rec.wav", index: 1000) == "rec_1000.wav")
        #expect(chunkPath(base: "noext", index: 2) == "noext_002")
    }

    @Test func splitRequiresOutput() {
        #expect(throws: (any Error).self) {
            _ = try Record.parse(["--split", "duration=10", "--no-output"])
        }
    }
}

/// Records writes/finalizes for SplittingSink tests.
private final class RecordingSinkSpy: AudioSink, @unchecked Sendable {
    let label = "spy"
    private(set) var written = Data()
    private(set) var finalized = false
    func write(_ data: Data) throws { written.append(data) }
    func finalize() throws { finalized = true }
    var bytesWritten: UInt64 { UInt64(written.count) }
}

@Suite("SplittingSink")
struct SplittingSinkTests {
    @Test func splitsAtFrameAlignedThreshold() throws {
        // 2-byte frames, threshold 5s at 1 Hz "byte rate" 2 -> 10 bytes.
        let format = PCMFormat(sampleRate: 1, bitsPerSample: 16, channels: 1)
        var chunks: [RecordingSinkSpy] = []
        let sink = SplittingSink(chunkSeconds: 5, format: format, label: "t") { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        try sink.write(Data(count: 25))
        try sink.finalize()

        #expect(chunks.count == 3)
        #expect(chunks[0].written.count == 10)
        #expect(chunks[1].written.count == 10)
        #expect(chunks[2].written.count == 5)
        let allFinalized = chunks.allSatisfy { $0.finalized }
        #expect(allFinalized)
        #expect(sink.bytesWritten == 25)
    }

    @Test func exactMultipleDoesNotOpenEmptyChunk() throws {
        let format = PCMFormat(sampleRate: 1, bitsPerSample: 16, channels: 1)
        var chunks: [RecordingSinkSpy] = []
        let sink = SplittingSink(chunkSeconds: 5, format: format, label: "t") { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        try sink.write(Data(count: 20))  // exactly 2 chunks
        try sink.finalize()
        #expect(chunks.count == 2)
        let allComplete = chunks.allSatisfy { $0.written.count == 10 && $0.finalized }
        #expect(allComplete)
    }

    @Test func chunkIndicesAreSequential() throws {
        let format = PCMFormat(sampleRate: 1, bitsPerSample: 16, channels: 1)
        var indices: [Int] = []
        let sink = SplittingSink(chunkSeconds: 5, format: format, label: "t") { index in
            indices.append(index)
            return RecordingSinkSpy()
        }
        try sink.write(Data(count: 21))
        try sink.finalize()
        #expect(indices == [1, 2, 3])
    }
}

@Suite("Silence splitting")
struct SilenceSplittingTests {
    // 1000 Hz 16-bit mono -> byteRate 2000; 0.5 s blocks are 1000 bytes.
    private let format = PCMFormat(sampleRate: 1000, bitsPerSample: 16, channels: 1)

    private func loud(_ bytes: Int = 1000) -> Data {
        var data = Data(capacity: bytes)
        for i in 0..<(bytes / 2) {
            withUnsafeBytes(of: Int16(i % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }

    private func quiet(_ bytes: Int = 1000) -> Data { Data(count: bytes) }

    @Test func peakAmplitudeByDepth() {
        #expect(peakAmplitude(of: loud(), format: format) > 0.4)
        #expect(peakAmplitude(of: quiet(), format: format) == 0)
        let f24 = PCMFormat(sampleRate: 1000, bitsPerSample: 24, channels: 1)
        // One 24-bit sample at half scale: 0x400000 -> bytes [00, 00, 40].
        #expect(abs(peakAmplitude(of: Data([0x00, 0x00, 0x40]), format: f24) - 0.5) < 0.01)
        let f32 = PCMFormat(sampleRate: 1000, bitsPerSample: 32, channels: 1)
        var d32 = Data()
        withUnsafeBytes(of: Int32(1 << 30).littleEndian) { d32.append(contentsOf: $0) }
        #expect(abs(peakAmplitude(of: d32, format: f32) - 0.5) < 0.01)
    }

    @Test func splitsOnSustainedSilence() throws {
        var chunks: [RecordingSinkSpy] = []
        let sink = SilenceSplittingSink(
            silenceSeconds: 1.5, thresholdDBFS: -50, format: format, label: "t"
        ) { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        // loud 1s, silence 2s, loud 1s (0.5 s blocks)
        for block in [loud(), loud(), quiet(), quiet(), quiet(), quiet(), loud(), loud()] {
            try sink.write(block)
        }
        try sink.finalize()

        #expect(chunks.count == 2)
        // Chunk 1: 2 loud + 3 quiet blocks (split at 1.5s of silence).
        #expect(chunks[0].written.count == 5000)
        // Chunk 2: trailing quiet + 2 loud blocks; nothing dropped.
        #expect(chunks[1].written.count == 3000)
        #expect(sink.bytesWritten == 8000)
    }

    @Test func longSilenceYieldsSingleFollowUpChunk() throws {
        var chunks: [RecordingSinkSpy] = []
        let sink = SilenceSplittingSink(
            silenceSeconds: 1.0, thresholdDBFS: -50, format: format, label: "t"
        ) { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        try sink.write(loud())
        for _ in 0..<10 { try sink.write(quiet()) }  // 5s of silence
        try sink.write(loud())
        try sink.finalize()
        // Disarmed after the split: one follow-up chunk, not five.
        #expect(chunks.count == 2)
    }

    @Test func leadingSilenceDoesNotSplit() throws {
        var chunks: [RecordingSinkSpy] = []
        let sink = SilenceSplittingSink(
            silenceSeconds: 1.0, thresholdDBFS: -50, format: format, label: "t"
        ) { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        for _ in 0..<6 { try sink.write(quiet()) }  // 3s leading silence
        try sink.write(loud())
        try sink.finalize()
        // Splitter is disarmed until sound first appears.
        #expect(chunks.count == 1)
    }
}
