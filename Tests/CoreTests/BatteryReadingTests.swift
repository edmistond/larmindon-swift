import XCTest
@testable import LarmindonKit

#if os(iOS)
import UIKit
#endif

final class BatteryReadingTests: XCTestCase {
    func testLevelConvertsToWholePercent() {
        let reading = BatteryReading(level: 0.85, state: .charging)
        XCTAssertEqual(
            reading.fields,
            ["battery_percent": "85", "battery_state": "charging"]
        )
    }

    func testNegativeLevelReadsAsUnknownPercent() {
        // UIDevice reports -1 when battery monitoring is off or the level is unavailable.
        let reading = BatteryReading(level: -1, state: .unknown)
        XCTAssertNil(reading.percent)
        XCTAssertEqual(
            reading.fields,
            ["battery_percent": "unknown", "battery_state": "unknown"]
        )
    }

    func testPluggedInStateUsesSnakeCase() {
        let reading = BatteryReading(percent: 80, state: .pluggedIn)
        XCTAssertEqual(reading.fields["battery_state"], "plugged_in")
    }

    func testResourceFieldsIncludeBatteryOnIOS() async throws {
        #if os(iOS)
        let fields = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return AppEnvironmentDiagnosticMonitor.resourceFields()
        }
        XCTAssertNotNil(fields["battery_percent"])
        XCTAssertNotNil(fields["battery_state"])
        #else
        throw XCTSkip("Only iOS always reports a battery; a Mac may not have one.")
        #endif
    }
}
