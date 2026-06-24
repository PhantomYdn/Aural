import Foundation

/// Stall-recovery tuning, resolved from the environment for production and set
/// directly in tests. `HARK_NO_RECOVER` disables recovery; `HARK_STALL_SECONDS`
/// sets how long a silence is tolerated before resuming (default 3 s);
/// `HARK_RECOVER_TIMEOUT` (default 0 = never) bounds retries before a clean stop.
struct RecoverySettings: Sendable, Equatable {
    var enabled: Bool
    var stallSeconds: Double
    var giveUpSeconds: Double

    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> RecoverySettings {
        func truthy(_ v: String?) -> Bool {
            guard let v = v?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(v)
        }
        return RecoverySettings(
            enabled: !truthy(env["HARK_NO_RECOVER"]),
            stallSeconds: env["HARK_STALL_SECONDS"].flatMap(Double.init) ?? 3,
            giveUpSeconds: env["HARK_RECOVER_TIMEOUT"].flatMap(Double.init) ?? 0)
    }
}

/// Detects capture stalls — the OS interrupting the audio stream on screen lock,
/// display/system sleep, or a device/route change — and drives recovery.
///
/// Pure decision logic over an injected clock so it is unit-testable; the owner
/// (`CaptureEngine.run`) wires the timer, the session `restart()`, the user
/// notices, and the clean-stop. The contract:
///   * `audioArrived()` whenever a (non-paused) chunk is delivered.
///   * `setPaused(_:)` so an intentional `--pause` gap is never seen as a stall.
///   * `tick()` on a fixed cadence; act on the returned `Action`.
///
/// Policy: once audio has been flowing and then stops for `stallSeconds`, ask
/// the owner to `restart()` and keep retrying every `retrySeconds` (auto-resume,
/// so a long lock never loses the recording). If `giveUpSeconds > 0` and the
/// stall persists that long without recovery, ask the owner to stop cleanly
/// (the bounded clean-stop fallback; disabled by default).
final class StallWatchdog: @unchecked Sendable {
    enum Action: Equatable {
        case none
        /// Stalled; attempt `session.restart()`. `first` is true on the first
        /// detection of this stall episode (so the owner announces it once).
        case restart(first: Bool)
        /// Audio returned after a stall.
        case resumed
        /// Stalled past `giveUpSeconds` without recovery; stop cleanly.
        case giveUp
    }

    private let stallSeconds: Double
    private let retrySeconds: Double
    private let giveUpSeconds: Double  // 0 = never give up
    private let now: () -> Date
    private let lock = NSLock()

    private var sawAudio = false
    private var lastAudioAt: Date
    private var paused = false
    private var stalledSince: Date?
    private var lastRestartAt: Date?

    init(
        stallSeconds: Double,
        retrySeconds: Double = 3,
        giveUpSeconds: Double = 0,
        now: @escaping () -> Date = Date.init
    ) {
        self.stallSeconds = max(0.5, stallSeconds)
        self.retrySeconds = max(0.5, retrySeconds)
        self.giveUpSeconds = max(0, giveUpSeconds)
        self.now = now
        self.lastAudioAt = now()
    }

    /// Records that captured audio was delivered (resets the stall timer).
    func audioArrived() {
        lock.lock()
        defer { lock.unlock() }
        sawAudio = true
        lastAudioAt = now()
    }

    /// Tracks pause state; a paused stream legitimately produces no audio. Only
    /// acts on a transition (callers may invoke this every tick), so unpausing
    /// resets the stall timer exactly once rather than continuously.
    func setPaused(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard value != paused else { return }
        paused = value
        if value {
            stalledSince = nil
            lastRestartAt = nil
        } else {
            lastAudioAt = now()
        }
    }

    /// Evaluates the stream's liveness and returns the action to take.
    func tick() -> Action {
        lock.lock()
        defer { lock.unlock() }
        // Don't evaluate before capture has produced its first audio (engine
        // spin-up), or while paused.
        guard sawAudio, !paused else { return .none }

        let t = now()
        let elapsed = t.timeIntervalSince(lastAudioAt)
        if elapsed < stallSeconds {
            if stalledSince != nil {
                stalledSince = nil
                lastRestartAt = nil
                return .resumed
            }
            return .none
        }

        // Stalled.
        let first = stalledSince == nil
        if first { stalledSince = t }
        if giveUpSeconds > 0, let since = stalledSince,
            t.timeIntervalSince(since) >= giveUpSeconds
        {
            return .giveUp
        }
        if !first, let last = lastRestartAt, t.timeIntervalSince(last) < retrySeconds {
            return .none
        }
        lastRestartAt = t
        return .restart(first: first)
    }
}
