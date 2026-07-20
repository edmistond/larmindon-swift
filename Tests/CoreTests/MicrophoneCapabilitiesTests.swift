import XCTest
@testable import LarmindonKit

final class MicrophoneCapabilitiesTests: XCTestCase {
    func testKnownPolarPatternsHaveReadableTitles() {
        XCTAssertEqual(MicrophonePolarPattern.omnidirectional.title, "Omnidirectional")
        XCTAssertEqual(MicrophonePolarPattern.cardioid.title, "Cardioid")
        XCTAssertEqual(MicrophonePolarPattern.subcardioid.title, "Subcardioid")
        XCTAssertEqual(MicrophonePolarPattern.stereo.title, "Stereo")
    }

    func testCapabilityItemsUseLabelAsStableDefaultIdentifier() {
        let item = MicrophoneCapabilityItem(label: "Actual channels", value: "2")

        XCTAssertEqual(item.id, "Actual channels")
    }

    func testCapabilitySectionsUseTitleAsStableDefaultIdentifier() {
        let section = MicrophoneCapabilitySection(
            title: "Channels",
            items: [MicrophoneCapabilityItem(label: "Actual", value: "1")]
        )

        XCTAssertEqual(section.id, "Channels")
    }
}
