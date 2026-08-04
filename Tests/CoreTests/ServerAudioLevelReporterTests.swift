import XCTest
@testable import LarmindonKit

final class ServerAudioLevelReporterTests: XCTestCase {
    func testPublishesAtMostFourUpdatesPerSecond() {
        let reporter = ServerAudioLevelReporter(updateInterval: 0.25)

        XCTAssertNotNil(
            reporter.update(
                rawLevel: 0.5,
                observedCallbackFrameLength: 768,
                at: 10
            )
        )
        XCTAssertNil(
            reporter.update(
                rawLevel: 0.6,
                observedCallbackFrameLength: 768,
                at: 10.1
            )
        )
        XCTAssertNil(
            reporter.update(
                rawLevel: 0.7,
                observedCallbackFrameLength: 768,
                at: 10.249
            )
        )
        XCTAssertNotNil(
            reporter.update(
                rawLevel: 0.8,
                observedCallbackFrameLength: 768,
                at: 10.25
            )
        )
    }

    func testSmoothsAttackAndReleaseAcrossSuppressedSamples() throws {
        let reporter = ServerAudioLevelReporter(updateInterval: 0.25)

        let initial = try XCTUnwrap(
            reporter.update(
                rawLevel: 0,
                observedCallbackFrameLength: 768,
                at: 20
            )
        )
        XCTAssertEqual(initial.rawInputLevel, 0)

        XCTAssertNil(
            reporter.update(
                rawLevel: 1,
                observedCallbackFrameLength: 768,
                at: 20.1
            )
        )
        let attack = try XCTUnwrap(
            reporter.update(
                rawLevel: 1,
                observedCallbackFrameLength: 768,
                at: 20.25
            )
        )
        XCTAssertGreaterThan(attack.rawInputLevel, 0)
        XCTAssertLessThan(attack.rawInputLevel, 1)

        let release = try XCTUnwrap(
            reporter.update(
                rawLevel: 0,
                observedCallbackFrameLength: 768,
                at: 20.5
            )
        )
        XCTAssertLessThan(release.rawInputLevel, attack.rawInputLevel)
        XCTAssertGreaterThan(release.rawInputLevel, 0)
        XCTAssertEqual(release.observedCallbackFrameLength, 768)
    }

    func testLoudAudioAloneDoesNotMakeTheMeterHot() throws {
        let reporter = ServerAudioLevelReporter(updateInterval: 0.25)

        let snapshot = try XCTUnwrap(
            reporter.update(
                rawLevel: 1,
                observedCallbackFrameLength: 768,
                at: 30
            )
        )

        // The whole point: the mic can be delivering plenty of signal while the backend
        // returns nothing, which is exactly the dead-zone stall the old noise gate hid.
        XCTAssertGreaterThan(snapshot.rawInputLevel, 0)
        XCTAssertFalse(snapshot.speechDetected)
        XCTAssertEqual(snapshot.vadState, "Server idle")
    }

    func testProviderTokensMakeTheMeterHotUntilTheWindowLapses() throws {
        let reporter = ServerAudioLevelReporter(
            updateInterval: 0.25,
            activityWindow: 2
        )

        reporter.noteProviderActivity(at: 40)

        let hot = try XCTUnwrap(
            reporter.update(
                rawLevel: 0.5,
                observedCallbackFrameLength: 768,
                at: 40.25
            )
        )
        XCTAssertTrue(hot.speechDetected)
        XCTAssertEqual(hot.vadState, "Server returning tokens")

        // Still inside the window, so a gap between words doesn't strobe the bar.
        let stillHot = try XCTUnwrap(
            reporter.update(
                rawLevel: 0.5,
                observedCallbackFrameLength: 768,
                at: 41.9
            )
        )
        XCTAssertTrue(stillHot.speechDetected)

        let lapsed = try XCTUnwrap(
            reporter.update(
                rawLevel: 0.5,
                observedCallbackFrameLength: 768,
                at: 42.5
            )
        )
        XCTAssertFalse(lapsed.speechDetected)
        XCTAssertEqual(lapsed.vadState, "Server idle")
    }

    func testEmptyProviderUpdatesDoNotCountAsActivity() {
        // Soniox emits a transcript update roughly once a second whether or not it heard
        // anything, and the source yields `.volatileSegments` for every one. Counting those
        // would pin the meter hot and reproduce the bug this replaced.
        XCTAssertFalse(CaptionResult.volatileSegments([]).carriesTranscription)
        XCTAssertFalse(
            CaptionResult.volatileSegments([
                CaptionSegment(text: "  ", speakerID: "1")
            ]).carriesTranscription
        )
        XCTAssertFalse(CaptionResult.volatile("").carriesTranscription)
        XCTAssertFalse(CaptionResult.failure("socket closed").carriesTranscription)

        XCTAssertTrue(
            CaptionResult.volatileSegments([
                CaptionSegment(text: "Hello", speakerID: "1")
            ]).carriesTranscription
        )
        XCTAssertTrue(CaptionResult.finalized("Hello.").carriesTranscription)
    }
}
