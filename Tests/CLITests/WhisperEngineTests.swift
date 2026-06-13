import Foundation
import Testing

@testable import CLI

@Suite("WhisperEngine discovery")
struct WhisperDiscoveryTests {
    private func makeExecutable(named name: String, in dir: URL) throws {
        let path = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func findsWhisperCliOnPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-cli", in: dir)
        let found = WhisperEngine.discover(environment: ["PATH": dir.path])
        #expect(found?.lastPathComponent == "whisper-cli")
    }

    @Test func prefersWhisperCliOverWhisperCpp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-cli", in: dir)
        try makeExecutable(named: "whisper-cpp", in: dir)
        let found = WhisperEngine.discover(environment: ["PATH": dir.path])
        #expect(found?.lastPathComponent == "whisper-cli")
    }

    @Test func fallsBackToWhisperCpp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-cpp", in: dir)
        let found = WhisperEngine.discover(environment: ["PATH": dir.path])
        #expect(found?.lastPathComponent == "whisper-cpp")
    }

    @Test func returnsNilWhenAbsent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WhisperEngine.discover(environment: ["PATH": dir.path]) == nil)
    }

    @Test func binOverrideWins() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "my-whisper", in: dir)
        let env = [
            "PATH": "/nonexistent",
            "AURAL_WHISPER_BIN": dir.appendingPathComponent("my-whisper").path,
        ]
        #expect(WhisperEngine.discover(environment: env)?.lastPathComponent == "my-whisper")
    }
}

@Suite("Whisper model resolution")
struct WhisperModelTests {
    @Test func flagWinsOverEnvironment() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-model-\(UUID().uuidString).bin")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolved = try WhisperEngine.resolveModel(
            flag: file.path, environment: ["AURAL_WHISPER_MODEL": "/other.bin"])
        #expect(resolved == file.path)
    }

    @Test func environmentFallback() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-model-\(UUID().uuidString).bin")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolved = try WhisperEngine.resolveModel(
            flag: nil, environment: ["AURAL_WHISPER_MODEL": file.path])
        #expect(resolved == file.path)
    }

    @Test func missingModelThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try WhisperEngine.resolveModel(flag: nil, environment: [:])
        }
    }

    @Test func nonexistentModelPathThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try WhisperEngine.resolveModel(flag: "/no/such/model.bin", environment: [:])
        }
    }
}

@Suite("Whisper arguments")
struct WhisperArgumentTests {
    @Test func buildsBaseArguments() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: nil, format: .txt, outputBase: "/tmp/out")
        #expect(args == ["-m", "/m.bin", "-f", "/a.wav", "-np", "-otxt", "-of", "/tmp/out"])
    }

    @Test func includesLanguageWhenSet() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: "de", format: .srt, outputBase: "/o")
        #expect(args.contains("-osrt"))
        #expect(args.suffix(2) == ["-l", "de"])
    }

    @Test func jsonFormatFlag() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: nil, format: .json, outputBase: "/o")
        #expect(args.contains("-oj"))
    }
}
