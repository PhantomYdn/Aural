import ArgumentParser
import Encoders
import Foundation
import Testing

@testable import CLI

@Suite("Root argument parsing")
struct RootParsingTests {
    @Test func defaults() throws {
        let aural = try Aural.parse([])
        #expect(aural.input == nil)
        #expect(aural.device == nil)
        #expect(aural.audio == nil)
        #expect(aural.transcript == nil)
        #expect(aural.rate == nil)
        #expect(aural.bits == nil)
        #expect(aural.channels == nil)
        #expect(aural.duration == nil)
        #expect(!aural.raw)
        #expect(!aural.noOutput)
        #expect(aural.engine == "whisper")
    }

    @Test func parsesAllOptions() throws {
        let aural = try Aural.parse([
            "-d", "SomeUID", "-a", "x.wav", "-t", "x.srt",
            "-r", "48000", "-b", "24", "-c", "2", "--duration", "30.5",
        ])
        #expect(aural.device == "SomeUID")
        #expect(aural.audio == "x.wav")
        #expect(aural.transcript == "x.srt")
        #expect(aural.rate == 48000)
        #expect(aural.bits == 24)
        #expect(aural.channels == 2)
        #expect(aural.duration == 30.5)
    }

    @Test(arguments: [
        ["-a", "x.wav", "-b", "12"],          // bad bit depth
        ["-a", "x.wav", "-c", "3"],           // bad channel count
        ["--duration", "0"],                   // non-positive duration
        ["-a", "x.wav", "-r", "0"],           // bad rate
        ["-a", "-", "-t", "-"],               // two outputs cannot share stdout
        ["--raw", "-a", "x.wav"],             // --raw requires -a -
        ["--no-output", "-a", "x.wav"],       // dry run conflicts with an output
        ["-i", "f.wav", "--system"],          // -i excludes live flags
        ["-i", "f.wav", "--duration", "5"],   // duration is live-only
        ["-i", "f.wav", "--split", "duration=2"],  // split is live-only
        ["--system", "--app", "foo"],          // system is everything
        ["--app", "a", "--exclude-app", "b"],  // include vs exclude
        ["--mix"],                             // mix needs a tap mode
        ["--system", "-d", "UID"],             // device needs --mix
        ["--split", "duration=2", "-a", "-"],  // split needs a file
        ["--split", "duration=2"],             // split needs an audio output
        ["-e", "bogus"],                        // unknown engine
    ])
    func rejectsInvalidCombinations(_ arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Aural.parse(arguments)
        }
    }

    @Test(arguments: [
        [],                                     // bare: live mic -> transcript
        ["-a", "rec.m4a"],                      // record only
        ["-a", "rec.m4a", "-t", "notes.txt"],   // record + transcribe
        ["-a", "-"],                            // WAV stream to stdout
        ["--raw", "-a", "-"],                   // raw PCM to stdout
        ["-i", "in.mp3"],                       // transcribe a file
        ["-i", "in.wav", "-a", "out.m4a"],      // convert
        ["--system", "--mix", "-a", "m.m4a", "-t", "m.srt"],
        ["--system", "--mix", "-d", "SomeUID"],
        ["--app", "com.example.app", "--app", "123"],
        ["--exclude-app", "com.example.app"],
    ])
    func acceptsValidCombinations(_ arguments: [String]) throws {
        _ = try Aural.parse(arguments)
    }

    @Test func repeatableAppFlagAccumulates() throws {
        let aural = try Aural.parse(
            ["--app", "com.a", "--app", "com.b", "--app", "42"])
        #expect(aural.apps == ["com.a", "com.b", "42"])
    }
}

@Suite("Output resolution")
struct OutputResolutionTests {
    /// Naming no output transcribes to stdout (the default verb).
    @Test func defaultIsTranscriptToStdout() throws {
        let outputs = try Aural.parse([]).resolveOutputs()
        #expect(outputs.audio == nil)
        guard case .stdout = outputs.transcript else {
            Issue.record("expected transcript -> stdout")
            return
        }
    }

    @Test func audioOnlyHasNoTranscript() throws {
        let outputs = try Aural.parse(["-a", "rec.m4a"]).resolveOutputs()
        #expect(outputs.transcript == nil)
        guard case .file(let path)? = outputs.audio, path == "rec.m4a" else {
            Issue.record("expected audio file rec.m4a")
            return
        }
    }

    @Test func dashAudioIsWavStream() throws {
        let outputs = try Aural.parse(["-a", "-"]).resolveOutputs()
        guard case .stdoutWav? = outputs.audio else {
            Issue.record("expected WAV stream to stdout")
            return
        }
        #expect(outputs.transcript == nil)
    }

    @Test func rawDashAudioIsRawStream() throws {
        let outputs = try Aural.parse(["--raw", "-a", "-"]).resolveOutputs()
        guard case .stdoutRaw? = outputs.audio else {
            Issue.record("expected raw PCM to stdout")
            return
        }
    }

    @Test func explicitTranscriptToStdoutWithAudioFile() throws {
        let outputs = try Aural.parse(["-a", "rec.m4a", "-t", "-"]).resolveOutputs()
        guard case .file? = outputs.audio else {
            Issue.record("expected audio file")
            return
        }
        guard case .stdout = outputs.transcript else {
            Issue.record("expected transcript -> stdout")
            return
        }
    }

    @Test func noOutputDiscardsEverything() throws {
        let outputs = try Aural.parse(["--no-output"]).resolveOutputs()
        #expect(outputs.audio == nil)
        #expect(outputs.transcript == nil)
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

    @Test func splitRequiresAudioFile() {
        #expect(throws: (any Error).self) {
            _ = try Aural.parse(["--split", "duration=10", "--no-output"])
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
