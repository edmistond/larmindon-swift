import Foundation

/// An explicit suspension point for reproducing cancellation between lifecycle steps.
actor AsyncGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
