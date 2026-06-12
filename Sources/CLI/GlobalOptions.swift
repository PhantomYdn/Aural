import ArgumentParser
import Foundation

/// Options shared by every subcommand.
struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Log diagnostic details to stderr.")
    var verbose = false
}

/// Stderr logging (PRD §7 Auditability: paths/durations logged when -v is on).
enum Log {
    nonisolated(unsafe) static var isVerbose = false

    /// Diagnostic output, shown only with `--verbose`.
    static func verbose(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        FileHandle.standardError.write(Data("aural: \(message())\n".utf8))
    }

    /// Error output, always shown.
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("aural: error: \(message)\n".utf8))
    }
}

extension ParsableCommand {
    /// Runs `body`, mapping thrown `AuralError`s to stderr output + exit code.
    func runMapped(verbose: Bool, _ body: () throws -> Void) throws {
        Log.isVerbose = verbose
        do {
            try body()
        } catch let error as AuralError {
            Log.error(error.message)
            throw error.code.exitCode
        }
    }
}
