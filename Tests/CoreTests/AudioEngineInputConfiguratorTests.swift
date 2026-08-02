import AVFAudio
import XCTest
@testable import LarmindonKit

final class AudioEngineInputConfiguratorTests: XCTestCase {
    func testAcceptsFormatReportedByConfiguredNode() {
        XCTAssertTrue(
            AudioEngineInputConfigurator.isUsableCaptureFormat(
                sampleRate: 48_000,
                channelCount: 1
            )
        )
        XCTAssertTrue(
            AudioEngineInputConfigurator.isUsableCaptureFormat(
                sampleRate: 44_100,
                channelCount: 2
            )
        )
    }

    func testRejectsFormatFromNodeThatHasNotSettledOnADevice() {
        XCTAssertFalse(
            AudioEngineInputConfigurator.isUsableCaptureFormat(
                sampleRate: 0,
                channelCount: 1
            )
        )
        XCTAssertFalse(
            AudioEngineInputConfigurator.isUsableCaptureFormat(
                sampleRate: 48_000,
                channelCount: 0
            )
        )
        XCTAssertFalse(
            AudioEngineInputConfigurator.isUsableCaptureFormat(
                sampleRate: 0,
                channelCount: 0
            )
        )
    }
}
