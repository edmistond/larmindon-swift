import Foundation

public actor URLSessionWebSocketTransport: WebSocketTransport {
    private let endpoint: URL
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var delegate: WebSocketDelegate?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var closeDetails: WebSocketCloseDetails?

    public init(endpoint: URL) {
        self.endpoint = endpoint
    }

    public func connect() async throws {
        guard webSocketTask == nil else {
            throw WebSocketTransportError.connectionFailed("A connection is already active.")
        }

        closeDetails = nil
        let delegate = WebSocketDelegate(owner: self)
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: endpoint)
        self.delegate = delegate
        self.session = session
        webSocketTask = task

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connectContinuation = continuation
                    task.resume()
                }
            } onCancel: {
                Task {
                    await self.cancelConnectionAttempt()
                }
            }
        } catch {
            tearDown()
            throw error
        }
    }

    public func sendText(_ text: String) async throws {
        let task = try connectedTask()
        do {
            try await task.send(.string(text))
        } catch {
            throw resolvedError(error)
        }
    }

    public func sendBinary(_ data: Data) async throws {
        let task = try connectedTask()
        do {
            try await task.send(.data(data))
        } catch {
            throw resolvedError(error)
        }
    }

    public func receive() async throws -> WebSocketMessage {
        let task = try connectedTask()
        do {
            switch try await task.receive() {
            case .string(let text):
                return .text(text)
            case .data(let data):
                return .binary(data)
            @unknown default:
                throw WebSocketTransportError.unsupportedMessage
            }
        } catch {
            throw resolvedError(error)
        }
    }

    public func sendPing() async throws {
        let task = try connectedTask()
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(
                            throwing: WebSocketTransportError.operationFailed(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            throw resolvedError(error)
        }
    }

    public func close(code: WebSocketCloseCode) async {
        guard let task = webSocketTask else { return }
        let foundationCode =
            URLSessionWebSocketTask.CloseCode(rawValue: code.rawValue)
            ?? .goingAway
        task.cancel(with: foundationCode, reason: nil)
        tearDown()
    }

    fileprivate func didOpen() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    fileprivate func didClose(code: Int, reason: Data?) {
        closeDetails = WebSocketCloseDetails(
            code: code,
            reason: reason.flatMap { String(data: $0, encoding: .utf8) }
        )
        if let connectContinuation {
            connectContinuation.resume(
                throwing: WebSocketTransportError.closed(closeDetails!)
            )
            self.connectContinuation = nil
        }
    }

    fileprivate func didComplete(errorDescription: String?) {
        guard let connectContinuation else { return }
        if let errorDescription {
            connectContinuation.resume(
                throwing: WebSocketTransportError.connectionFailed(errorDescription)
            )
        } else if let closeDetails {
            connectContinuation.resume(
                throwing: WebSocketTransportError.closed(closeDetails)
            )
        } else {
            connectContinuation.resume(
                throwing: WebSocketTransportError.connectionFailed(
                    "The connection ended before opening."
                )
            )
        }
        self.connectContinuation = nil
    }

    private func connectedTask() throws -> URLSessionWebSocketTask {
        guard let webSocketTask else {
            throw WebSocketTransportError.notConnected
        }
        return webSocketTask
    }

    private func resolvedError(_ error: any Error) -> any Error {
        if error is CancellationError {
            return error
        }
        if let transportError = error as? WebSocketTransportError {
            return transportError
        }
        if let closeDetails {
            return WebSocketTransportError.closed(closeDetails)
        }
        if let task = webSocketTask,
            task.closeCode != .invalid
        {
            return WebSocketTransportError.closed(
                WebSocketCloseDetails(
                    code: task.closeCode.rawValue,
                    reason: task.closeReason.flatMap {
                        String(data: $0, encoding: .utf8)
                    }
                )
            )
        }
        return WebSocketTransportError.operationFailed(error.localizedDescription)
    }

    private func cancelConnectionAttempt() {
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        tearDown()
    }

    private func tearDown() {
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private weak var owner: URLSessionWebSocketTransport?

    init(owner: URLSessionWebSocketTransport) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task {
            await owner?.didOpen()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task {
            await owner?.didClose(code: closeCode.rawValue, reason: reason)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let errorDescription = error?.localizedDescription
        Task {
            await owner?.didComplete(errorDescription: errorDescription)
        }
    }
}
