import XCTest
@testable import LarmindonKit

/// Deterministic gates for the durable diagnostics store. All of it runs against a temp-file
/// database in CI — no device, no real kill required, which matters because the behavior
/// being protected here (surviving a process death) is otherwise only observable by
/// suffering one.
final class DiagnosticStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(named name: String = "test.sqlite") -> DiagnosticStore {
        DiagnosticStore(url: directory.appendingPathComponent(name))
    }

    private func event(
        session: UUID,
        category: String = "state",
        name: String = "example",
        fields: [String: String] = [:],
        at date: Date = Date()
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: date,
            sessionID: session,
            category: category,
            name: name,
            fields: fields
        )
    }

    // MARK: - Round trip

    func testEventsSurviveClosingAndReopeningTheDatabase() async throws {
        let session = UUID()
        let store = makeStore()
        try await store.open()
        try await store.append([
            event(session: session, name: "first"),
            event(session: session, name: "second"),
        ])
        await store.close()

        // A new instance over the same file: this is the "process died, we came back" case.
        let reopened = makeStore()
        try await reopened.open()
        let events = try await reopened.recentEvents()

        let count = try await reopened.eventCount()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(events.map(\.name), ["second", "first"])
    }

    func testFieldsRoundTripAsQueryableJSON() async throws {
        let store = makeStore()
        try await store.open()
        try await store.append([
            event(
                session: UUID(),
                category: "audio_route",
                name: "audio_interruption",
                fields: ["decision": "give_up_attempts_exhausted", "attempt": "4"]
            )
        ])

        let stored = try await store.recentEvents().first
        XCTAssertEqual(stored?.fields["decision"], "give_up_attempts_exhausted")
        XCTAssertEqual(stored?.fields["attempt"], "4")
    }

    func testEmptyFieldsEncodeAsAnEmptyObjectRatherThanNull() {
        XCTAssertEqual(DiagnosticStore.encodeFields([:]), "{}")
        XCTAssertEqual(DiagnosticStore.decodeFields("{}"), [:])
        XCTAssertEqual(DiagnosticStore.decodeFields(nil), [:])
    }

    // MARK: - Unexpected termination

    /// The capability the whole change exists for: a session that never recorded an end was
    /// killed, and the only place that can be noticed is the next launch.
    func testSessionWithNoRecordedEndIsReportedOnNextLaunch() async throws {
        let killed = UUID().uuidString
        let current = UUID().uuidString

        let store = makeStore()
        try await store.open()
        try await store.startSession(
            sessionID: killed,
            startedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "1.0",
            appBuild: "1",
            osVersion: "26.0",
            deviceClass: "iPhone17,1"
        )
        try await store.append([
            event(
                session: UUID(uuidString: killed)!,
                at: Date(timeIntervalSince1970: 1_060)
            )
        ])

        let unexpected = try await store.sessionsEndedUnexpectedly(excluding: current)

        XCTAssertEqual(unexpected.count, 1)
        XCTAssertEqual(unexpected.first?.sessionID, killed)
        XCTAssertTrue(unexpected.first?.endedUnexpectedly == true)
        XCTAssertEqual(unexpected.first?.eventCount, 1)
        XCTAssertEqual(
            unexpected.first?.lastEventAt,
            Date(timeIntervalSince1970: 1_060)
        )
    }

    func testSessionThatExitedCleanlyIsNotReported() async throws {
        let clean = UUID().uuidString
        let store = makeStore()
        try await store.open()
        try await store.startSession(
            sessionID: clean,
            startedAt: Date(),
            appVersion: "1.0",
            appBuild: "1",
            osVersion: "26.0",
            deviceClass: "iPhone17,1"
        )
        try await store.endSession(sessionID: clean, reason: "will_terminate")

        let unexpected = try await store.sessionsEndedUnexpectedly(
            excluding: UUID().uuidString
        )
        XCTAssertTrue(unexpected.isEmpty)
    }

    /// The running session has no end recorded either, by definition. Reporting it would
    /// mean every launch accused itself of having been killed.
    func testTheCurrentSessionIsNeverReportedAsUnexpected() async throws {
        let current = UUID().uuidString
        let store = makeStore()
        try await store.open()
        try await store.startSession(
            sessionID: current,
            startedAt: Date(),
            appVersion: "1.0",
            appBuild: "1",
            osVersion: "26.0",
            deviceClass: "iPhone17,1"
        )

        let unexpected = try await store.sessionsEndedUnexpectedly(excluding: current)
        XCTAssertTrue(unexpected.isEmpty)
    }

    // MARK: - Retention

    func testPruneDropsAgedEventsAndKeepsRecentOnes() async throws {
        let session = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore()
        try await store.open()
        try await store.append([
            event(session: session, name: "old", at: now.addingTimeInterval(-10 * 86_400)),
            event(session: session, name: "recent", at: now.addingTimeInterval(-1 * 86_400)),
        ])

        let removed = try await store.prune(olderThan: 7 * 86_400, now: now)

        let remaining = try await store.eventCount()
        let names = try await store.recentEvents().map(\.name)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(names, ["recent"])
    }

    /// Sessions whose events have all aged out shouldn't linger as empty rows forever.
    func testPruneRemovesSessionsLeftWithNoEvents() async throws {
        let old = UUID().uuidString
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore()
        try await store.open()
        try await store.startSession(
            sessionID: old,
            startedAt: now.addingTimeInterval(-30 * 86_400),
            appVersion: "1.0",
            appBuild: "1",
            osVersion: "26.0",
            deviceClass: "iPhone17,1"
        )

        try await store.prune(olderThan: 7 * 86_400, now: now)

        let sessions = try await store.sessionCount()
        XCTAssertEqual(sessions, 0)
    }

    // MARK: - Export

    func testSnapshotWritesAReadableSingleFileCopy() async throws {
        let session = UUID()
        let store = makeStore()
        try await store.open()
        try await store.append([event(session: session, name: "exported")])

        let snapshot = directory.appendingPathComponent("snapshot.sqlite")
        try await store.writeSnapshot(to: snapshot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        // Readable as a database in its own right, not just a file that exists — this is
        // what lands on the Mac after AirDrop.
        let copy = DiagnosticStore(url: snapshot)
        try await copy.open()
        let count = try await copy.eventCount()
        let first = try await copy.recentEvents().first?.name
        XCTAssertEqual(count, 1)
        XCTAssertEqual(first, "exported")
    }

    func testSnapshotOverwritesAPreviousExport() async throws {
        let store = makeStore()
        try await store.open()
        let snapshot = directory.appendingPathComponent("snapshot.sqlite")

        try await store.writeSnapshot(to: snapshot)
        try await store.append([event(session: UUID(), name: "added_after_first_export")])
        try await store.writeSnapshot(to: snapshot)

        let copy = DiagnosticStore(url: snapshot)
        try await copy.open()
        let count = try await copy.eventCount()
        XCTAssertEqual(count, 1)
    }
}
