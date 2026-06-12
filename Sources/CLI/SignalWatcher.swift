import Dispatch
import Foundation

/// Watches termination signals and invokes a handler once, allowing the
/// recording loop to shut down gracefully (PRD §4.1.6: finalize the output
/// header on SIGINT/SIGTERM so the file remains playable).
final class SignalWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var fired = false

    /// Installs handlers for the given signals. The handler runs at most
    /// once, on a global queue.
    func watch(_ signals: [Int32], handler: @escaping @Sendable () -> Void) {
        for signalNumber in signals {
            // Default disposition must be ignored for DispatchSource delivery.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let alreadyFired = self.fired
                self.fired = true
                self.lock.unlock()
                if !alreadyFired { handler() }
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }
}
