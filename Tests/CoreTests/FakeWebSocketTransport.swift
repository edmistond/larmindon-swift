import Foundation
@testable import LarmindonKit

actor FakeWebSocketTransport: WebSocketTransport {
    private(set) var connectCount = 0
    private(set) var sentTextMessages: [String] = []
    private(set) var sentBinaryMessages: [Data] = []
    private(set) var pingCount = 0
    private(set) var closeCodes: [WebSocketCloseCode] = []

    private var queuedMessages: [WebSocketMessage] = []
    private var receiveWaiters: [CheckedContinuation<WebSocketMessage, any Error>] = []
    private var binaryCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isConnected = false
    private var connectGate: AsyncGate?
    private var textGate: AsyncGate?
    private var binaryGate: AsyncGate?
    private var receiveGate: AsyncGate?
    private var binaryFailure: WebSocketTransportError?

    func pauseConnect(on gate: AsyncGate) { connectGate = gate }
    func pauseText(on gate: AsyncGate) { textGate = gate }
    func pauseBinary(on gate: AsyncGate) { binaryGate = gate }
    func pauseReceive(on gate: AsyncGate) { receiveGate = gate }
    func failBinary(with error: WebSocketTransportError) { binaryFailure = error }

    func connect() async throws {
        connectCount += 1
        await connectGate?.suspend()
        isConnected = true
    }

    func sendText(_ text: String) async throws {
        try requireConnection()
        sentTextMessages.append(text)
        await textGate?.suspend()
    }

    func sendBinary(_ data: Data) async throws {
        try requireConnection()
        sentBinaryMessages.append(data)
        resumeSatisfiedBinaryWaiters()
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

    private func requireConnection() throws {
        guard isConnected else {
            throw WebSocketTransportError.notConnected
        }
    }

    private func resumeSatisfiedBinaryWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in binaryCountWaiters {
            if sentBinaryMessages.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        binaryCountWaiters = pending
    }
}
