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
}
