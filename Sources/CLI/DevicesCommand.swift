import ArgumentParser

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List audio input and output devices."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            throw AuralError.unavailable("'devices' is not implemented yet")
        }
    }
}
