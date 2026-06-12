import Encoders
import Foundation

/// Destination for captured PCM data.
protocol AudioSink: Sendable {
    func write(_ data: Data) throws
    func finalize() throws
    var bytesWritten: UInt64 { get }
    /// Human-readable destination for verbose stats.
    var label: String { get }
}

/// WAV container output (file or stdout stream).
final class WAVSink: AudioSink, @unchecked Sendable {
    private let writer: WAVFileWriter
    let label: String

    init(writer: WAVFileWriter, label: String) {
        self.writer = writer
        self.label = label
    }

    func write(_ data: Data) throws { try writer.write(data) }
    func finalize() throws { try writer.finalize() }
    var bytesWritten: UInt64 { writer.bytesWritten }
}

/// Headerless PCM to a file handle (default for piped stdout).
final class RawStreamSink: AudioSink, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var count: UInt64 = 0
    let label: String

    init(handle: FileHandle, label: String) {
        self.handle = handle
        self.label = label
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
        count += UInt64(data.count)
    }

    func finalize() throws {}

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Counts and discards audio (--no-output dry run).
final class DiscardSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    let label = "discarded (--no-output)"

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        count += UInt64(data.count)
    }

    func finalize() throws {}

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Returns true if the error chain bottoms out in EPIPE (downstream pipe
/// closed) — treated as graceful completion, matching Unix conventions.
func isBrokenPipe(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    while let nsError = current {
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPIPE) {
            return true
        }
        current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}
