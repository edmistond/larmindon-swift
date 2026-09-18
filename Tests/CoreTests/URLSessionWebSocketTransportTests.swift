import Foundation
import XCTest
@testable import LarmindonKit

final class URLSessionWebSocketTransportTests: XCTestCase {
    private final class Connection: WebSocketConnection, @unchecked Sendable {
        let operations = FakeWebSocketTransport()
        let onEvent: @Sendable (WebSocketConnectionEvent) async -> Void
        private let lock = NSLock()
        private var invalidations = 0
        private var details: WebSocketCloseDetails?
        var invalidationCount: Int { lock.withLock { invalidations } }
        var closeDetails: WebSocketCloseDetails? { lock.withLock { details } }

        init(onEvent: @escaping @Sendable (WebSocketConnectionEvent) async -> Void) {
            self.onEvent = onEvent
        }
        func resume() {}
        func cancel(code: WebSocketCloseCode) { Task { await operations.close(code: code) } }
        func invalidate() {
            lock.withLock { invalidations += 1 }
            Task { await operations.close(code: .goingAway) }
        }
        func send(_ message: WebSocketMessage) async throws {
            switch message {
            case .text(let text): try await operations.sendText(text)
            case .binary(let data): try await operations.sendBinary(data)
            }
        }
        func receive() async throws -> WebSocketMessage { try await operations.receive() }
        func sendPing() async throws { try await operations.sendPing() }
        func emit(_ event: WebSocketConnectionEvent) async throws {
            if case .opened = event { try await operations.connect() }
            if case .closed(let details) = event { lock.withLock { self.details = details } }
            await onEvent(event)
        }
    }

    private struct Fixture {
        let transport: URLSessionWebSocketTransport
        let connections: AsyncStream<Connection>
        init() {
            let (connections, continuation) = AsyncStream<Connection>.makeStream()
            self.connections = connections
            transport = URLSessionWebSocketTransport { onEvent in
                let connection = Connection(onEvent: onEvent)
                continuation.yield(connection)
                return connection
            }
        }
    }

    func testCloseDuringHandshakeResumesConnectAndAllowsReplacement() async throws {
        let fixture = Fixture()
        var connections = fixture.connections.makeAsyncIterator()
        let start = Task { try await fixture.transport.connect() }
        let oldValue = await connections.next()
        let old = try XCTUnwrap(oldValue)
        await fixture.transport.close(code: .goingAway)
        do { try await start.value; XCTFail("Closed handshake must fail") } catch {}
        XCTAssertEqual(old.invalidationCount, 1)

        let replacementStart = Task { try await fixture.transport.connect() }
        let replacementValue = await connections.next()
        let replacement = try XCTUnwrap(replacementValue)
        try await old.emit(.opened)
        try await old.emit(.closed(WebSocketCloseDetails(code: 1006, reason: "old close")))
        try await old.emit(.completed(errorDescription: "old completion"))
        do { try await fixture.transport.sendText("before open"); XCTFail("Old open cannot open replacement") } catch {
            XCTAssertEqual(error as? WebSocketTransportError, .notConnected)
        }
        try await replacement.emit(.opened)
        try await replacementStart.value
        try await fixture.transport.sendText("replacement")
        let messages = await replacement.operations.sentTextMessages
        XCTAssertEqual(messages, ["replacement"])
        XCTAssertEqual(replacement.invalidationCount, 0)
        await fixture.transport.close(code: .normalClosure)
    }

    func testCancellationDuringHandshakeReleasesConnectionOnce() async throws {
        let fixture = Fixture()
        var connections = fixture.connections.makeAsyncIterator()
        let start = Task { try await fixture.transport.connect() }
        let value = await connections.next()
        let connection = try XCTUnwrap(value)
        start.cancel()
        do { try await start.value; XCTFail("Cancelled handshake must fail") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(connection.invalidationCount, 1)
        try await connection.emit(.opened)
        await fixture.transport.close(code: .goingAway)
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testDelegateCompletionBeforeOpenFailsConnect() async throws {
        let fixture = Fixture()
        var connections = fixture.connections.makeAsyncIterator()
        let start = Task { try await fixture.transport.connect() }
        let value = await connections.next()
        let connection = try XCTUnwrap(value)
        try await connection.emit(.completed(errorDescription: "handshake failed"))
        do { try await start.value; XCTFail("Handshake must fail") } catch {
            XCTAssertEqual(error as? WebSocketTransportError, .connectionFailed("handshake failed"))
        }
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testMidstreamCloseReportsCodeAndReason() async throws {
        let fixture = Fixture()
        var connections = fixture.connections.makeAsyncIterator()
        let start = Task { try await fixture.transport.connect() }
        let value = await connections.next()
        let connection = try XCTUnwrap(value)
        try await connection.emit(.opened)
        try await start.value
        let gate = AsyncGate()
        await connection.operations.pauseReceive(on: gate)
        await connection.operations.enqueue(.text("arrived too late"))
        let receive = Task { try await fixture.transport.receive() }
        await gate.waitUntilEntered()
        let details = WebSocketCloseDetails(code: 1008, reason: "policy")
        try await connection.emit(.closed(details))
        await gate.release()
        do { _ = try await receive.value; XCTFail("A late message cannot revive the connection") } catch {
            XCTAssertEqual(error as? WebSocketTransportError, .closed(details))
        }
    }

    func testSendFailureIsMappedByConcreteTransport() async throws {
        let fixture = Fixture()
        var connections = fixture.connections.makeAsyncIterator()
        let start = Task { try await fixture.transport.connect() }
        let value = await connections.next()
        let connection = try XCTUnwrap(value)
        try await connection.emit(.opened)
        try await start.value
        await connection.operations.failBinary(with: .operationFailed("cannot send"))
        do { try await fixture.transport.sendBinary(Data([1])); XCTFail("Send must fail") } catch {
            XCTAssertEqual(error as? WebSocketTransportError, .operationFailed("cannot send"))
        }
        await fixture.transport.close(code: .goingAway)
    }

    func testFoundationDelegateForwardsLifecycleDetailsWithoutNetwork() async throws {
        let (events, continuation) = AsyncStream<WebSocketConnectionEvent>.makeStream()
        let delegate = WebSocketDelegate { continuation.yield($0) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: try XCTUnwrap(URL(string: "wss://example.invalid")))
        var iterator = events.makeAsyncIterator()
        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        guard case .opened = await iterator.next() else { return XCTFail("Missing open event") }
        delegate.urlSession(session, webSocketTask: task, didCloseWith: .policyViolation, reason: Data("policy".utf8))
        guard case .closed(let details) = await iterator.next() else { return XCTFail("Missing close event") }
        XCTAssertEqual(details, WebSocketCloseDetails(code: 1008, reason: "policy"))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        guard case .completed(let error) = await iterator.next() else { return XCTFail("Missing completion") }
        XCTAssertNil(error)
        continuation.finish()
    }
}
