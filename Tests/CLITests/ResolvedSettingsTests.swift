import Foundation
import Testing

@testable import CLI

@Suite("Resolved settings")
struct ResolvedSettingsTests {
    private func settings(
        _ args: [String] = [], env: [String: String] = [:], config: Configuration = Configuration()
    ) throws -> ResolvedSettings {
        try ResolvedSettings.resolve(from: try Aural.parse(args), environment: env, config: config)
    }

    @Test func builtInDefaultsWhenNothingSet() throws {
        let s = try settings()
        #expect(s.engine == "whisper")
        #expect(s.language == "auto")
        #expect(s.translate == false)
        #expect(s.silenceThreshold == -50)
        #expect(s.micDevice == nil)
        #expect(s.captureBackend == "auto")
        #expect(s.rate == nil)  // contextual (live 44100 / convert source)
        #expect(s.bits == nil)
        #expect(s.useVad == true)
        #expect(s.useGain == true)
        #expect(s.vadThreshold == nil)
        #expect(s.speakers == false)
        #expect(s.speakerMode == .auto)
        #expect(s.diarizeEngine == .auto)
        #expect(s.speakerLabels == SpeakerLabels(you: "You", others: "Others"))
        #expect(s.maxSpeakers == nil)
        #expect(s.speakerThreshold == nil)
    }

    @Test func configProvidesDefaults() throws {
        var config = Configuration()
        config.engine = "whisperkit"
        config.language = "de"
        config.translate = true
        config.silenceThreshold = -42
        config.device = "MicUID"
        config.rate = 48000
        config.vad = false
        config.speakers = true
        config.speakerMode = "source"
        config.diarizeEngine = "offline"
        config.maxSpeakers = 4
        config.speakerThreshold = 0.6
        let s = try settings(config: config)
        #expect(s.engine == "whisperkit")
        #expect(s.language == "de")
        #expect(s.translate == true)
        #expect(s.silenceThreshold == -42)
        #expect(s.micDevice == "MicUID")
        #expect(s.rate == 48000)
        #expect(s.useVad == false)
        #expect(s.speakers == true)
        #expect(s.speakerMode == .source)
        #expect(s.diarizeEngine == .offline)
        #expect(s.maxSpeakers == 4)
        #expect(s.speakerThreshold == 0.6)
    }

    @Test func envOverridesConfig() throws {
        var config = Configuration()
        config.engine = "whisper"
        config.rate = 44100
        config.vad = true
        config.speakerMode = "auto"
        let env = [
            "AURAL_ENGINE": "whisperkit", "AURAL_RATE": "48000",
            "AURAL_VAD": "0", "AURAL_SPEAKER_MODE": "source",
        ]
        let s = try settings(env: env, config: config)
        #expect(s.engine == "whisperkit")
        #expect(s.rate == 48000)
        #expect(s.useVad == false)  // AURAL_VAD=0 back-compat
        #expect(s.speakerMode == .source)
    }

    @Test func flagOverridesEverything() throws {
        var config = Configuration()
        config.engine = "whisper"
        config.rate = 44100
        config.vad = true
        let env = ["AURAL_ENGINE": "apple", "AURAL_RATE": "16000", "AURAL_VAD": "1"]
        let s = try settings(
            ["--engine", "whisperkit", "--rate", "48000", "--no-vad",
             "--silence-threshold=-25", "--speaker-mode", "acoustic"],
            env: env, config: config)
        #expect(s.engine == "whisperkit")
        #expect(s.rate == 48000)
        #expect(s.useVad == false)  // --no-vad beats env/config
        #expect(s.silenceThreshold == -25)
        #expect(s.speakerMode == .acoustic)
    }

    @Test func emptyEnvValuesAreIgnored() throws {
        var config = Configuration()
        config.engine = "whisperkit"
        config.language = "de"
        let s = try settings(env: ["AURAL_ENGINE": "", "AURAL_LANGUAGE": ""], config: config)
        #expect(s.engine == "whisperkit")
        #expect(s.language == "de")
    }

    @Test func malformedEnvThrows() {
        #expect(throws: AuralError.self) { _ = try settings(env: ["AURAL_TRANSLATE": "maybe"]) }
        #expect(throws: AuralError.self) { _ = try settings(env: ["AURAL_SILENCE_THRESHOLD": "loud"]) }
        #expect(throws: AuralError.self) { _ = try settings(env: ["AURAL_SILENCE_THRESHOLD": "5"]) }
        #expect(throws: AuralError.self) { _ = try settings(env: ["AURAL_RATE": "abc"]) }
        #expect(throws: AuralError.self) { _ = try settings(env: ["AURAL_VAD_THRESHOLD": "2"]) }
        #expect(throws: AuralError.self) { _ = try settings(env: ["AURAL_CAPTURE": "bogus"]) }
    }

    @Test func validateRejectsMergedConflicts() throws {
        var unknownEngine = Configuration(); unknownEngine.engine = "bogus"
        #expect(throws: AuralError.self) { try settings(config: unknownEngine).validate() }

        var appleTranslate = Configuration()
        appleTranslate.engine = "apple"
        appleTranslate.translate = true
        #expect(throws: AuralError.self) { try settings(config: appleTranslate).validate() }

        var badThreshold = Configuration(); badThreshold.silenceThreshold = 0
        #expect(throws: AuralError.self) { try settings(config: badThreshold).validate() }
    }

    @Test func validateAcceptsValidMerged() throws {
        var config = Configuration()
        config.language = "de"
        config.translate = true  // whisper supports translate
        try settings(config: config).validate()
    }
}
