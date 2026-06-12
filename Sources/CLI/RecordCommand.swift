import ArgumentParser

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record audio from a microphone or input device."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            throw AuralError.unavailable("'record' is not implemented yet")
        }
    }
}
