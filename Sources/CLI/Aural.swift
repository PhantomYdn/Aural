import ArgumentParser

@main
struct Aural: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aural",
        abstract: "Capture microphone and system audio on macOS.",
        discussion: """
            Aural records from microphones and, via Core Audio process taps, \
            from the system or individual applications. Output is written to \
            transcription-friendly audio files or streamed to stdout for use \
            in Unix pipelines.
            """,
        version: "0.1.0",
        subcommands: [
            Devices.self,
            Apps.self,
            Record.self,
            Transcribe.self,
            Convert.self,
            Info.self,
        ]
    )
}
