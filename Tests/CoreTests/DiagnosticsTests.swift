import Foundation
import XCTest
@testable import LarmindonKit

extension JSONDecoder {
    static var diagnosticDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class DiagnosticsTests: XCTestCase {
    func testRecorderRetainsBoundedNewestEvents() async {
        let recorder = DiagnosticRecorder(capacity: 100)
        for index in 0..<105 {
            await recorder.record(
                category: "test",
                name: "event",
                fields: ["index": String(index)]
            )
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.fields["index"], "5")
        XCTAssertEqual(events.last?.fields["index"], "104")
    }

    func testExportOmitsTranscriptAndRawAudioByDefault() async throws {
        let recorder = DiagnosticRecorder(capacity: 100)
        await recorder.record(category: "test", name: "started")

        let bundleURL = try await recorder.makeExportDirectory(
            transcript: nil
        )
        defer {
            try? FileManager.default.removeItem(at: bundleURL)
        }

        let manifestURL = bundleURL.appendingPathComponent(
            "manifest.json"
        )
        let eventsURL = bundleURL.appendingPathComponent("events.jsonl")
        let transcriptURL = bundleURL.appendingPathComponent(
            "transcript.txt"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: eventsURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: transcriptURL.path)
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            DiagnosticManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertFalse(manifest.includesTranscript)
        XCTAssertFalse(manifest.includesRawAudio)
        XCTAssertEqual(manifest.eventCount, 1)
    }

    /// The share sheet has to receive a single file. AirDrop is the delivery path, and a
    /// folder doesn't survive it the way an archive does.
    func testExportProducesASingleZipFileNotADirectory() async throws {
        let recorder = DiagnosticRecorder(capacity: 100)
        await recorder.record(category: "test", name: "started")

        let bundleURL = try await recorder.makeExportBundle(transcript: nil)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var isDirectory: ObjCBool = true
        let exists = FileManager.default.fileExists(
            atPath: bundleURL.path,
            isDirectory: &isDirectory
        )

        XCTAssertTrue(exists)
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertEqual(bundleURL.pathExtension, "zip")

        let size =
            try FileManager.default
            .attributesOfItem(atPath: bundleURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    /// Persistence is best-effort by design: a diagnostics failure must never be able to
    /// take down the app it exists to diagnose.
    func testRecordingWorksWithoutPersistenceActivated() async {
        let recorder = DiagnosticRecorder(capacity: 100)
        await recorder.record(category: "test", name: "no_store")
        await recorder.flush()

        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 1)
    }

    func testActivatingPersistenceWritesEventsThrough() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DiagnosticStore(
            url: directory.appendingPathComponent("diagnostics.sqlite")
        )
        let recorder = DiagnosticRecorder(capacity: 100)
        await recorder.activatePersistence(store: store)

        await recorder.record(category: "test", name: "persisted")
        await recorder.flush()

        let names = try await store.recentEvents().map(\.name)
        XCTAssertTrue(names.contains("persisted"))
        // activatePersistence records its own readiness marker, which is the signal that
        // the store opened rather than silently degrading to memory-only.
        XCTAssertTrue(names.contains("persistence_ready"))
    }

    /// The point of the whole change: what lands on the Mac carries previous sessions, not
    /// just the one that happened to be running when Export was tapped.
    func testExportedBundleCarriesTheDatabaseWithEarlierSessions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("diagnostics.sqlite")

        // A previous launch that was killed: it recorded events and never recorded an end.
        let earlier = DiagnosticStore(url: databaseURL)
        try await earlier.open()
        try await earlier.append([
            DiagnosticEvent(
                sessionID: UUID(),
                category: "lifecycle",
                name: "did_enter_background"
            )
        ])
        await earlier.close()

        let recorder = DiagnosticRecorder(capacity: 100)
        await recorder.activatePersistence(store: DiagnosticStore(url: databaseURL))
        await recorder.record(category: "test", name: "this_session")

        let bundle = try await recorder.makeExportDirectory(transcript: nil)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let exportedDatabase = bundle.appendingPathComponent("diagnostics.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedDatabase.path))

        let copy = DiagnosticStore(url: exportedDatabase)
        try await copy.open()
        let names = try await copy.recentEvents().map(\.name)
        XCTAssertTrue(names.contains("did_enter_background"))
        XCTAssertTrue(names.contains("this_session"))

        let manifest = try JSONDecoder.diagnosticDecoder.decode(
            DiagnosticManifest.self,
            from: Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        )
        XCTAssertTrue(manifest.includesDatabase)
        XCTAssertGreaterThan(manifest.storedEventCount, manifest.eventCount)
    }

    /// Regression: bundle `larmindon-diagnostics-BBE900D2` held 849
    /// `previous_session_ended_unexpectedly` events for 35 sessions. iOS almost never
    /// delivers `willTerminate`, so sessions stayed open and every launch re-reported all of
    /// them. Each one should be reported exactly once.
    func testUnexpectedlyEndedSessionIsReportedOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-unexpected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("diagnostics.sqlite")

        let killed = UUID()
        let earlier = DiagnosticStore(url: databaseURL)
        try await earlier.open()
        try await earlier.startSession(
            sessionID: killed.uuidString,
            startedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "1.0",
            appBuild: "1",
            osVersion: "26.0",
            deviceClass: "iPhone17,1"
        )
        let lastEventAt = Date(timeIntervalSince1970: 1_060)
        try await earlier.append([
            DiagnosticEvent(timestamp: lastEventAt, sessionID: killed, category: "test", name: "last_seen")
        ])
        await earlier.close()

        func reportedSessions(_ recorder: DiagnosticRecorder) async -> [String] {
            await recorder.snapshot()
                .filter { $0.name == "previous_session_ended_unexpectedly" }
                .compactMap { $0.fields["session"] }
        }

        let secondLaunch = DiagnosticRecorder(capacity: 100)
        await secondLaunch.activatePersistence(store: DiagnosticStore(url: databaseURL))
        let secondReports = await reportedSessions(secondLaunch)
        XCTAssertEqual(secondReports, [killed.uuidString])
        await secondLaunch.flush()

        // The second launch also never exits cleanly, so the third reports it, and only it.
        let thirdLaunch = DiagnosticRecorder(capacity: 100)
        await thirdLaunch.activatePersistence(store: DiagnosticStore(url: databaseURL))
        let thirdReports = await reportedSessions(thirdLaunch)
        let secondSessionID = await secondLaunch.sessionID.uuidString
        XCTAssertEqual(thirdReports, [secondSessionID])

        let check = DiagnosticStore(url: databaseURL)
        try await check.open()
        let stillOpen = try await check.sessionsEndedUnexpectedly(
            excluding: await thirdLaunch.sessionID.uuidString
        )
        XCTAssertTrue(stillOpen.isEmpty)
    }

    func testDeviceIdentifierRedactionIsStableAndDoesNotRevealInput() {
        let first = DiagnosticRedaction.identifier("personal-device-uid")
        let second = DiagnosticRedaction.identifier("personal-device-uid")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("device-"))
        XCTAssertFalse(first.contains("personal-device-uid"))
    }
}
