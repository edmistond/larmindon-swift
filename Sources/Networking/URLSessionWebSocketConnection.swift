import Foundation

/// Only the Foundation socket/session operations are replaceable. The transport
/// still owns connection state, cancellation, delegate events, and error mapping.
protocol WebSocketConnection: Sendable {
    var closeDetails: WebSocketCloseDetails? { get }
    func resume()
    func cancel(code: WebSocketCloseCode)
    func invalidate()
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func sendPing() async throws
}

enum WebSocketConnectionEvent: Sendable {
    case opened
    case closed(WebSocketCloseDetails)
    case completed(errorDescription: String?)
}

// URLSession and URLSessionWebSocketTask support concurrent access; these references
// are immutable, and mutable lifecycle state lives in URLSessionWebSocketTransport.
final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, onEvent: @escaping @Sendable (WebSocketConnectionEvent) async -> Void) {
        let delegate = WebSocketDelegate(onEvent: onEvent)
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
    }

    var closeDetails: WebSocketCloseDetails? {
        guard task.closeCode != .invalid else { return nil }
        return WebSocketCloseDetails(
            code: task.closeCode.rawValue,
            reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        )
    }

    func resume() { task.resume() }

    func cancel(code: WebSocketCloseCode) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code.rawValue) ?? .goingAway, reason: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> WebSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw WebSocketTransportError.unsupportedMessage
        }
    }

    func sendPing() async throws {
        let resumption = SingleResumption()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                // URLSession can call the pong handler twice when the connection fails: crash
                // reports from 2026-09-28 show a second call resuming with an error after the
                // first had already resumed, which traps. Only the first call counts.
                guard resumption.claim() else { return }
                if let error {
                    continuation.resume(throwing: WebSocketTransportError.operationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let onEvent: @Sendable (WebSocketConnectionEvent) async -> Void

    init(onEvent: @escaping @Sendable (WebSocketConnectionEvent) async -> Void) {
        self.onEvent = onEvent
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        Task { await onEvent(.opened) }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let details = WebSocketCloseDetails(
            code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) }
        )
        Task { await onEvent(.closed(details)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let message = error?.localizedDescription
        Task { await onEvent(.completed(errorDescription: message)) }
    }
}

/// Lets exactly one of several callbacks resume a continuation.
final class SingleResumption: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
