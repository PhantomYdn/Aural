import AppKit
import Foundation

/// Writes text to the system clipboard. Abstracted so the interactive yank
/// feature (PRD §6.9) can be unit-tested with a fake.
protocol ClipboardWriter: Sendable {
    /// Replaces the clipboard contents with `text`. Returns whether the write
    /// succeeded.
    @discardableResult
    func copy(_ text: String) -> Bool
}

/// The real clipboard: NSPasteboard first, falling back to piping into
/// `/usr/bin/pbcopy` if the pasteboard write fails (e.g. no window-server
/// connection). Both target the same macOS pasteboard.
struct SystemClipboard: ClipboardWriter {
    @discardableResult
    func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            return true
        }
        return Self.pbcopy(text)
    }

    /// Fallback: write `text` to `pbcopy`'s stdin.
    private static func pbcopy(_ text: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            let handle = pipe.fileHandleForWriting
            handle.write(Data(text.utf8))
            try? handle.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
