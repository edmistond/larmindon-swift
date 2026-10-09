import Foundation

public actor URLSessionWebSocketTransport: WebSocketTransport {
    typealias ConnectionFactory =
        @Sendable (
            URLRequest,
            @escaping @Sendable (WebSocketConnectionEvent) async -> Void
        ) -> any WebSocketConnection

    private final class Attempt {
        let id: UUID
        let driver: any WebSocketConnection
        var isOpen = false
        var error: WebSocketTransportError?
        var continuation: CheckedContinuation<Void, any Error>?

        init(id: UUID, driver: any WebSocketConnection) {
            self.id = id
            self.driver = driver
        }
    }

    private let endpoint: URL
    private let makeConnection: ConnectionFactory
    private var connection: Attempt?

    public init(endpoint: URL) {
        self.endpoint = endpoint
        makeConnection = { URLSessionWebSocketConnection(request: $0, onEvent: $1) }
    }

    init(endpoint: URL, makeConnection: @escaping ConnectionFactory) {
        self.endpoint = endpoint
        self.makeConnection = makeConnection
    }

    public func connect(headers: [String: String]) async throws {
        guard connection == nil else {
            throw WebSocketTransportError.connectionFailed("A connection is already active.")
        }
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let id = UUID()
        let driver = makeConnection(request) { [weak self] event in
            await self?.handle(event, id: id)
        }
        let attempt = Attempt(id: id, driver: driver)
        connection = attempt
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    attempt.continuation = continuation
                    driver.resume()
                }
            } onCancel: {
                Task { await self.cancelConnectionAttempt(id: id) }
            }
            try Task.checkCancellation()
            try validate(attempt)
        } catch {
            endConnection(id: id, error: .connectionFailed(error.localizedDescription), code: .goingAway)
            throw error
        }
    }

    public func sendText(_ text: String) async throws {
        try await send(.text(text))
    }

    public func sendBinary(_ data: Data) async throws {
        try await send(.binary(data))
    }

    private func send(_ message: WebSocketMessage) async throws {
        let attempt = try connectedAttempt()
        do {
            try await attempt.driver.send(message)
            try validate(attempt)
        } catch {
            throw resolvedError(error, attempt: attempt)
        }
    }

    public func receive() async throws -> WebSocketMessage {
        let attempt = try connectedAttempt()
        do {
            let message = try await attempt.driver.receive()
            try validate(attempt)
            return message
        } catch {
            throw resolvedError(error, attempt: attempt)
        }
    }

    public func sendPing() async throws {
        let attempt = try connectedAttempt()
        do {
            try await attempt.driver.sendPing()
            try validate(attempt)
        } catch {
            throw resolvedError(error, attempt: attempt)
        }
    }

    public func close(code: WebSocketCloseCode) async {
        guard let connection else { return }
        endConnection(
            id: connection.id,
            error: .closed(WebSocketCloseDetails(code: code.rawValue, reason: nil)),
            code: code
        )
    }

    private func handle(_ event: WebSocketConnectionEvent, id: UUID) {
        guard let connection, connection.id == id else { return }
        switch event {
        case .opened:
            guard connection.continuation != nil else { return }
            connection.isOpen = true
            connection.continuation?.resume()
            connection.continuation = nil
        case .closed(let details):
            endConnection(id: id, error: .closed(details))
        case .completed(let errorDescription):
            endConnection(
                id: id,
                error: .connectionFailed(errorDescription ?? "The connection ended.")
            )
        }
    }

    private func connectedAttempt() throws -> Attempt {
        guard let connection, connection.isOpen else { throw WebSocketTransportError.notConnected }
        return connection
    }

    private func validate(_ attempt: Attempt) throws {
        if let error = attempt.error { throw error }
        guard connection?.id == attempt.id, attempt.isOpen else { throw WebSocketTransportError.notConnected }
    }

    private func resolvedError(_ error: any Error, attempt: Attempt) -> any Error {
        if error is CancellationError { return error }
        if let terminalError = attempt.error { return terminalError }
        if let details = attempt.driver.closeDetails { return WebSocketTransportError.closed(details) }
        if let transportError = error as? WebSocketTransportError { return transportError }
        return WebSocketTransportError.operationFailed(error.localizedDescription)
    }

    private func cancelConnectionAttempt(id: UUID) {
        guard let connection, connection.id == id else { return }
        connection.continuation?.resume(throwing: CancellationError())
        connection.continuation = nil
        endConnection(id: id, error: .connectionFailed("Connection cancelled."), code: .goingAway)
    }

    private func endConnection(id: UUID, error: WebSocketTransportError, code: WebSocketCloseCode? = nil) {
        guard let connection, connection.id == id else { return }
        connection.error = error
        connection.continuation?.resume(throwing: error)
        connection.continuation = nil
        self.connection = nil
        if let code { connection.driver.cancel(code: code) }
        connection.driver.invalidate()
    }
}
