import ArgumentParser

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List running applications whose audio can be captured."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            throw AuralError.unavailable("'apps' is not implemented yet")
        }
    }
}
