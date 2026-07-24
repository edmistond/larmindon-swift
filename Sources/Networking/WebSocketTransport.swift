import Foundation

public enum WebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

public enum WebSocketCloseCode: Int, Equatable, Sendable {
    case normalClosure = 1_000
    case goingAway = 1_001
    case protocolError = 1_002
    case unsupportedData = 1_003
    case noStatusReceived = 1_005
    case abnormalClosure = 1_006
    case invalidFramePayloadData = 1_007
    case policyViolation = 1_008
    case messageTooBig = 1_009
    case mandatoryExtensionMissing = 1_010
    case internalServerError = 1_011
    case tlsHandshakeFailure = 1_015
}

public struct WebSocketCloseDetails: Equatable, Sendable {
    public let code: Int
    public let reason: String?

    public init(code: Int, reason: String?) {
        self.code = code
        self.reason = reason
    }
}

public enum WebSocketTransportError: LocalizedError, Equatable, Sendable {
    case notConnected
    case connectionFailed(String)
    case operationFailed(String)
    case closed(WebSocketCloseDetails)
    case unsupportedMessage

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The WebSocket is not connected."
        case .connectionFailed(let message):
            return "The WebSocket connection failed: \(message)"
        case .operationFailed(let message):
            return "The WebSocket operation failed: \(message)"
        case .closed(let details):
            if let reason = details.reason, !reason.isEmpty {
                return "The WebSocket closed with code \(details.code): \(reason)"
            }
            return "The WebSocket closed with code \(details.code)."
        case .unsupportedMessage:
            return "The WebSocket received an unsupported message type."
        }
    }
}

public protocol WebSocketTransport: Sendable {
    func connect() async throws
    func sendText(_ text: String) async throws
    func sendBinary(_ data: Data) async throws
    func receive() async throws -> WebSocketMessage
    func sendPing() async throws
    func close(code: WebSocketCloseCode) async
}
