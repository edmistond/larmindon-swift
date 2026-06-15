import CoreMedia
import XCTest
@testable import LarmindonKit

final class SpeechResultFinalizationTests: XCTestCase {
    func testInvalidFinalizationTimeIsNotFinalized() {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(value: 10, timescale: 1)
        )

        XCTAssertFalse(
            SpeechResultFinalization.isFinalized(
                range: range,
                resultsFinalizationTime: .invalid
            )
        )
    }

    func testFinalizationTimeBeforeRangeEndIsNotFinalized() {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(value: 10, timescale: 1)
        )

        XCTAssertFalse(
            SpeechResultFinalization.isFinalized(
                range: range,
                resultsFinalizationTime: CMTime(value: 9, timescale: 1)
            )
        )
    }

    func testFinalizationTimeAtRangeEndIsFinalized() {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(value: 10, timescale: 1)
        )

        XCTAssertTrue(
            SpeechResultFinalization.isFinalized(
                range: range,
                resultsFinalizationTime: CMTime(value: 10, timescale: 1)
            )
        )
    }

    func testFinalizationTimeAfterRangeEndIsFinalized() {
        let range = CMTimeRange(
            start: CMTime(value: 5, timescale: 1),
            duration: CMTime(value: 10, timescale: 1)
        )

        XCTAssertTrue(
            SpeechResultFinalization.isFinalized(
                range: range,
                resultsFinalizationTime: CMTime(value: 16, timescale: 1)
            )
        )
    }
}
