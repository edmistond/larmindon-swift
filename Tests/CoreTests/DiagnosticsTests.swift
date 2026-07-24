import Foundation
import XCTest
@testable import LarmindonKit

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

        let bundleURL = try await recorder.makeExportBundle(
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

    func testDeviceIdentifierRedactionIsStableAndDoesNotRevealInput() {
        let first = DiagnosticRedaction.identifier("personal-device-uid")
        let second = DiagnosticRedaction.identifier("personal-device-uid")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("device-"))
        XCTAssertFalse(first.contains("personal-device-uid"))
    }
}
