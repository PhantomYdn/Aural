import ArgumentParser

// Stubs for commands scheduled in later phases (see PLAN.md).
// They exit with code 69 (EX_UNAVAILABLE) until implemented.

struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe an audio file, stdin stream, or live source."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            throw AuralError.unavailable("'transcribe' is not implemented yet (planned: Phase 4)")
        }
    }
}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert an audio file between formats."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            throw AuralError.unavailable("'convert' is not implemented yet (planned: Phase 3)")
        }
    }
}


