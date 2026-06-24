import Encoders
import Foundation
import TapEngine
import Testing

@testable import CLI

@Suite("Stall watchdog")
struct StallWatchdogTests {
    /// Mutable clock the watchdog reads through its injected `now`.
    private final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1000)
        var now: @Sendable () -> Date { { [self] in t } }
    }

    @Test func noStallBeforeFirstAudio() {
        let clock = Clock()
        let w = StallWatchdog(stallSeconds: 3, now: clock.now)
        clock.t += 100  // long gap, but no audio has ever arrived
        #expect(w.tick() == .none)
    }

    @Test func detectsStallThenRetriesThenResumes() {
        let clock = Clock()
        let w = StallWatchdog(stallSeconds: 3, retrySeconds: 3, now: clock.now)
        w.audioArrived()

        clock.t += 2
        #expect(w.tick() == .none)  // within tolerance
        clock.t += 1.0  // total 3 s since audio
        #expect(w.tick() == .restart(first: true))
        clock.t += 1
        #expect(w.tick() == .none)  // within retry interval
        clock.t += 2  // 3 s since last restart
        #expect(w.tick() == .restart(first: false))

        w.audioArrived()  // recovered
        #expect(w.tick() == .resumed)
        #expect(w.tick() == .none)
    }

    @Test func pauseIsNotAStall() {
        let clock = Clock()
        let w = StallWatchdog(stallSeconds: 3, now: clock.now)
        w.audioArrived()
        w.setPaused(true)
        clock.t += 100
        #expect(w.tick() == .none)
        w.setPaused(false)  // resets the timer
        clock.t += 1
        #expect(w.tick() == .none)
        clock.t += 3
        #expect(w.tick() == .restart(first: true))
    }

    @Test func givesUpAfterTimeout() {
        let clock = Clock()
        let w = StallWatchdog(stallSeconds: 1, retrySeconds: 3, giveUpSeconds: 5, now: clock.now)
        w.audioArrived()
        clock.t += 1
        #expect(w.tick() == .restart(first: true))  // stall begins here
        clock.t += 5  // 5 s into the stall
        #expect(w.tick() == .giveUp)
    }
}

/// A capture session whose audio delivery and restart outcome the test drives,
/// so `CaptureEngine.run`'s watchdog wiring can be exercised end to end.
private final class RecoveryStubSession: CaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onAudio: (@Sendable (Data) -> Void)?
    private(set) var restartCount = 0
    private(set) var stopped = false
    var restartSucceeds = true

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func restart() -> Bool {
        lock.lock(); restartCount += 1; let ok = restartSucceeds; lock.unlock()
        return ok
    }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    func emit(_ data: Data) {
        lock.lock(); let cb = onAudio; lock.unlock()
        cb?(data)
    }
}

private final class CountingSink: AudioSink, @unchecked Sendable {
    let label = "count"
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private(set) var finalized = false
    func write(_ data: Data) throws { lock.lock(); bytes += UInt64(data.count); lock.unlock() }
    func finalize() throws { lock.lock(); finalized = true; lock.unlock() }
    var bytesWritten: UInt64 { lock.lock(); defer { lock.unlock() }; return bytes }
}

@Suite("Capture recovery", .serialized)
struct CaptureRecoveryTests {
    private func engine() -> CaptureEngine {
        CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: false, apps: [], excludeApps: [], mix: false)
    }
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    /// A stalled stream that can restart resumes (no clean-stop): the watchdog
    /// asks the session to restart, audio resumes, and the run ends only on the
    /// explicit stop.
    @Test func resumesWhenRestartSucceeds() {
        let control = CaptureControl()
        let session = RecoveryStubSession()
        session.restartSucceeds = true
        var eng = engine()
        eng.control = control
        eng.recovery = RecoverySettings(enabled: true, stallSeconds: 0.5, giveUpSeconds: 0)
        let sink = CountingSink()

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (eng, session, sink))
        Thread.detachNewThread {
            let (eng, session, sink) = box.value
            try? eng.run(session: session, format: format, into: [sink], duration: nil, warnOnSilence: false)
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(Data(repeating: 1, count: 320))  // audio flows
        usleep(1_600_000)  // go silent past the stall threshold → restart attempted
        #expect(session.restartCount >= 1)
        session.emit(Data(repeating: 1, count: 320))  // audio resumes
        usleep(300_000)
        #expect(finished.wait(timeout: .now() + 1) == .timedOut)  // still running

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(session.stopped)
        #expect(sink.finalized)
    }

    /// When restart keeps failing and a recovery timeout is set, the run stops
    /// cleanly on its own (clean-stop fallback) and finalizes the sink.
    @Test func cleanStopWhenRecoveryFails() {
        let session = RecoveryStubSession()
        session.restartSucceeds = false
        var eng = engine()
        eng.recovery = RecoverySettings(enabled: true, stallSeconds: 0.5, giveUpSeconds: 1.5)
        let sink = CountingSink()

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (eng, session, sink))
        Thread.detachNewThread {
            let (eng, session, sink) = box.value
            try? eng.run(session: session, format: format, into: [sink], duration: nil, warnOnSilence: false)
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(Data(repeating: 1, count: 320))  // audio, then permanent silence
        // No stop() from the test: the watchdog must end the run by itself.
        #expect(finished.wait(timeout: .now() + 6) == .success)
        #expect(session.restartCount >= 1)
        #expect(session.stopped)
        #expect(sink.finalized)
    }
}
