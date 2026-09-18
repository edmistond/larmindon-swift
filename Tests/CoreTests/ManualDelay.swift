import Foundation
@testable import LarmindonKit

/// Time advances only when the test asks. Waiters expose registration milestones,
/// so advancing time cannot race ahead of the task that is supposed to be asleep.
actor ManualDelay {
    private struct Waiter {
        let deadline: Duration
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var now = Duration.zero
    private var waiters: [UUID: Waiter] = [:]
    private var registrations: [(Duration, CheckedContinuation<Void, Never>)] = []

    nonisolated var dependency: AsyncDelay {
        AsyncDelay { try await self.sleep(for: $0) }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(deadline: now + duration, duration: duration, continuation: continuation)
                let ready = registrations.filter { $0.0 == duration }
                registrations.removeAll { $0.0 == duration }
                for (_, registration) in ready { registration.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitUntilScheduled(_ duration: Duration) async {
        if waiters.values.contains(where: { $0.duration == duration }) { return }
        await withCheckedContinuation { registrations.append((duration, $0)) }
    }

    func advance(by duration: Duration) {
        now += duration
        let ready = waiters.filter { $0.value.deadline <= now }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
