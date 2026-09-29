import Foundation
import Network

/// What a reconnecting provider needs to know about the network, and nothing else.
///
/// A seam rather than `NWPathMonitor` directly so the reconnect loop's "wait for the
/// network to come back" behavior is testable without toggling a real radio.
protocol NetworkPathObserving: Sendable {
    /// Returns once the system reports a usable path. Throws `CancellationError` if the
    /// calling task is cancelled while waiting.
    func waitForSatisfiedPath() async throws
    /// Returns on the next change in path status or interface set — for example Wi-Fi
    /// joining in the garage while a reconnect is backing off.
    func waitForPathChange() async throws
    /// Stops observing and fails any pending waits.
    func cancel()
}

/// `NWPathMonitor`-backed path observation for one provider lifetime. Call `cancel()` when
/// done; the monitor keeps its dispatch queue alive until then.
final class NetworkPathMonitor: NetworkPathObserving, @unchecked Sendable {
    /// `NWPathMonitor` fires for changes that don't matter here — the diagnostics bundle
    /// shows an unchanged interface list reported every few seconds — so waiters compare
    /// only status and interface types.
    private struct Signature: Equatable {
        let isSatisfied: Bool
        let interfaces: [String]
    }

    private enum WaitKind {
        case satisfied
        case change
    }

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var signature: Signature?
    private var isCancelled = false
    private var waiters: [UUID: (kind: WaitKind, continuation: CheckedContinuation<Void, any Error>)] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(
                Signature(
                    isSatisfied: path.status == .satisfied,
                    interfaces: path.availableInterfaces
                        .map { String(describing: $0.type) }
                        .sorted()
                )
            )
        }
        monitor.start(queue: DispatchQueue(label: "com.davidedmiston.larmindon.soniox-path"))
    }

    func cancel() {
        monitor.cancel()
        let pending = lock.withLock {
            isCancelled = true
            let pending = waiters.values.map(\.continuation)
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    func waitForSatisfiedPath() async throws {
        try await wait(for: .satisfied)
    }

    func waitForPathChange() async throws {
        try await wait(for: .change)
    }

    private func wait(for kind: WaitKind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Outcome { case wait, resume, cancel }
                let outcome: Outcome = lock.withLock {
                    if isCancelled || Task.isCancelled { return .cancel }
                    // Before the first update arrives the status is unknown. Treat that as
                    // usable: an attempt that fails fast is cheaper than stalling a
                    // reconnect on a monitor that hasn't reported yet.
                    if kind == .satisfied, signature?.isSatisfied ?? true { return .resume }
                    waiters[id] = (kind, continuation)
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private func update(_ next: Signature) {
        let ready = lock.withLock {
            let previous = signature
            signature = next
            guard previous != next else { return [CheckedContinuation<Void, any Error>]() }
            let ready = waiters.filter { $0.value.kind == .change || next.isSatisfied }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for waiter in ready { waiter.resume() }
    }
}
