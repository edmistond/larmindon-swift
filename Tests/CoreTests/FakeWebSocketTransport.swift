import Foundation
@testable import LarmindonKit

actor FakeWebSocketTransport: WebSocketTransport {
    private typealias CountWaiter = (count: Int, continuation: CheckedContinuation<Void, Never>)

    private(set) var connectCount = 0
    private(set) var sentTextMessages: [String] = []
    private(set) var sentBinaryMessages: [Data] = []
    private(set) var pingCount = 0
    private(set) var closeCodes: [WebSocketCloseCode] = []

    private var queuedMessages: [WebSocketMessage] = []
    private var receiveWaiters: [CheckedContinuation<WebSocketMessage, any Error>] = []
    private var binaryCountWaiters: [CountWaiter] = []
    private var textCountWaiters: [CountWaiter] = []
    private var isConnected = false
    private var connectGate: AsyncGate?
    private var textGate: AsyncGate?
    private var binaryGate: AsyncGate?
    private var receiveGate: AsyncGate?
    private var binaryFailure: WebSocketTransportError?
    private var connectFailure: WebSocketTransportError?

    func pauseConnect(on gate: AsyncGate) { connectGate = gate }
    func pauseText(on gate: AsyncGate) { textGate = gate }
    func pauseBinary(on gate: AsyncGate) { binaryGate = gate }
    func pauseReceive(on gate: AsyncGate) { receiveGate = gate }
    func failBinary(with error: WebSocketTransportError) { binaryFailure = error }
    func failConnect(with error: WebSocketTransportError) { connectFailure = error }

    /// What the network dropping out looks like from above: the pending receive fails
    /// with a transport error rather than a close the client asked for.
    func dropConnection(with error: WebSocketTransportError = .connectionFailed("The network connection was lost.")) {
        isConnected = false
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    func connect() async throws {
        connectCount += 1
        await connectGate?.suspend()
        if let connectFailure { throw connectFailure }
        isConnected = true
    }

    func sendText(_ text: String) async throws {
        try requireConnection()
        sentTextMessages.append(text)
        textCountWaiters = Self.resumeSatisfied(textCountWaiters, count: sentTextMessages.count)
        await textGate?.suspend()
    }

    func sendBinary(_ data: Data) async throws {
        try requireConnection()
        sentBinaryMessages.append(data)
        binaryCountWaiters = Self.resumeSatisfied(binaryCountWaiters, count: sentBinaryMessages.count)
        await binaryGate?.suspend()
        if let binaryFailure { throw binaryFailure }
    }

    func receive() async throws -> WebSocketMessage {
        try requireConnection()
        let message: WebSocketMessage
        if !queuedMessages.isEmpty {
            message = queuedMessages.removeFirst()
        } else {
            message = try await withCheckedThrowingContinuation { continuation in
                receiveWaiters.append(continuation)
            }
        }
        await receiveGate?.suspend()
        return message
    }

    func sendPing() async throws {
        try requireConnection()
        pingCount += 1
    }

    func close(code: WebSocketCloseCode) async {
        closeCodes.append(code)
        isConnected = false
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(
                throwing: WebSocketTransportError.closed(
                    WebSocketCloseDetails(code: code.rawValue, reason: nil)
                )
            )
        }
    }

    func enqueue(_ message: WebSocketMessage) {
        if !receiveWaiters.isEmpty {
            receiveWaiters.removeFirst().resume(returning: message)
        } else {
            queuedMessages.append(message)
        }
    }

    func waitForBinaryMessageCount(_ count: Int) async {
        if sentBinaryMessages.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            binaryCountWaiters.append((count, continuation))
        }
    }

    /// The configuration is text message 1, so Soniox's end-of-audio signal is message 2.
    func waitForTextMessageCount(_ count: Int) async {
        if sentTextMessages.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            textCountWaiters.append((count, continuation))
        }
    }

    private func requireConnection() throws {
        guard isConnected else {
            throw WebSocketTransportError.notConnected
        }
    }

    private static func resumeSatisfied(
        _ waiters: [CountWaiter],
        count: Int
    ) -> [CountWaiter] {
        var pending: [CountWaiter] = []
        for waiter in waiters {
            if count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        return pending
    }
}

/// Hands out a fresh transport per connection, the way production does, and records how
/// many connections were attempted.
final class FakeWebSocketTransportSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let transports: [FakeWebSocketTransport]
    private var handedOut = 0

    init(count: Int) {
        transports = (0..<count).map { _ in FakeWebSocketTransport() }
    }

    subscript(index: Int) -> FakeWebSocketTransport { transports[index] }

    var connectionsRequested: Int { lock.withLock { handedOut } }

    func next() -> any WebSocketTransport {
        lock.withLock {
            precondition(handedOut < transports.count, "More connections than the test expected")
            defer { handedOut += 1 }
            return transports[handedOut]
        }
    }
}

/// Network path the test controls. Starts satisfied unless told otherwise.
final class FakeNetworkPath: NetworkPathObserving, @unchecked Sendable {
    private enum WaitKind { case satisfied, change }

    private let lock = NSLock()
    private var isSatisfied: Bool
    private var waiters: [UUID: (kind: WaitKind, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    init(isSatisfied: Bool = true) {
        self.isSatisfied = isSatisfied
    }

    func waitForSatisfiedPath() async throws {
        try await wait(.satisfied)
    }

    func waitForPathChange() async throws {
        try await wait(.change)
    }

    func cancel() {
        let pending = lock.withLock {
            defer { waiters.removeAll() }
            return waiters.values.map(\.continuation)
        }
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    func setSatisfied(_ satisfied: Bool) {
        let ready = lock.withLock {
            isSatisfied = satisfied
            let ready = waiters.filter { $0.value.kind == .change || satisfied }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for waiter in ready { waiter.resume() }
    }

    /// Returns once something is blocked on this path.
    func waitUntilSomeoneIsWaiting() async {
        await withCheckedContinuation { continuation in
            let already: Bool = lock.withLock {
                if !waiters.isEmpty { return true }
                waitingObservers.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    private func wait(_ kind: WaitKind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Outcome { case wait, resume, cancel }
                let outcome: Outcome = lock.withLock {
                    if Task.isCancelled { return .cancel }
                    if kind == .satisfied, isSatisfied { return .resume }
                    waiters[id] = (kind, continuation)
                    return .wait
                }
                switch outcome {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait:
                    let observers = lock.withLock {
                        defer { waitingObservers.removeAll() }
                        return waitingObservers
                    }
                    for observer in observers { observer.resume() }
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}
