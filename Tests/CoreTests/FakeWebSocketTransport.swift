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

    func connect() async throws {
        connectCount += 1
        isConnected = true
    }

    func sendText(_ text: String) async throws {
        try requireConnection()
        sentTextMessages.append(text)
    }

    func sendBinary(_ data: Data) async throws {
        try requireConnection()
        sentBinaryMessages.append(data)
        resumeSatisfiedBinaryWaiters()
    }

    func receive() async throws -> WebSocketMessage {
        try requireConnection()
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
        }
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
