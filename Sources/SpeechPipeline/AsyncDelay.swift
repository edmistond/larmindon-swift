import Foundation

/// A narrow time dependency for lifecycle deadlines; production uses monotonic time.
struct AsyncDelay: Sendable {
    var sleep: @Sendable (Duration) async throws -> Void

    static let continuous = AsyncDelay { try await Task.sleep(for: $0) }
}
