import Foundation

/// How aggressively to keep the machine awake while capturing (`--keep-awake`).
/// Display sleep alone doesn't stop audio capture, so the headless default only
/// blocks idle *system* sleep (which does); interactive runs also keep the
/// display on since the user is watching live captions.
enum SleepPreventionMode: Equatable, Sendable {
    /// Don't interfere with power management (default).
    case off
    /// Prevent idle system sleep only.
    case system
    /// Prevent idle system *and* display sleep.
    case systemAndDisplay

    /// Resolves the mode from the keep-awake setting and whether the run is
    /// interactive (interactive adds display-sleep prevention).
    static func resolve(keepAwake: Bool, interactive: Bool) -> SleepPreventionMode {
        guard keepAwake else { return .off }
        return interactive ? .systemAndDisplay : .system
    }

    /// The `ProcessInfo` activity options for this mode (empty when `.off`).
    var activityOptions: ProcessInfo.ActivityOptions {
        switch self {
        case .off: return []
        case .system: return [.idleSystemSleepDisabled]
        case .systemAndDisplay: return [.idleSystemSleepDisabled, .idleDisplaySleepDisabled]
        }
    }

    /// Short description for the startup status line; nil when `.off`.
    var statusDescription: String? {
        switch self {
        case .off: return nil
        case .system: return "system"
        case .systemAndDisplay: return "system+display"
        }
    }
}

/// Holds a power assertion for the lifetime of a capture so the machine doesn't
/// idle-sleep mid-recording (`--keep-awake`). Backed by
/// `ProcessInfo.beginActivity` (no IOKit, no entitlement); the assertion is
/// released by `end()` or on dealloc, so it never outlives the capture.
///
/// `begin`/`end` are idempotent and serialized by a lock so the capture path and
/// teardown can call them from different threads.
final class SleepPreventer: @unchecked Sendable {
    private let processInfo: ProcessInfo
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    /// Acquires the assertion for `mode` (no-op when `.off` or already held).
    func begin(_ mode: SleepPreventionMode, reason: String = "hark audio capture") {
        guard mode != .off else { return }
        lock.lock()
        defer { lock.unlock() }
        guard token == nil else { return }
        token = processInfo.beginActivity(options: mode.activityOptions, reason: reason)
    }

    /// Releases the assertion if held.
    func end() {
        lock.lock()
        defer { lock.unlock() }
        if let token {
            processInfo.endActivity(token)
            self.token = nil
        }
    }

    /// Whether the assertion is currently held (for diagnostics/tests).
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    deinit { end() }
}
