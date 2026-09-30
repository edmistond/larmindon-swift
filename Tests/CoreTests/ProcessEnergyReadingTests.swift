import XCTest
@testable import LarmindonKit

final class ProcessEnergyReadingTests: XCTestCase {
    func testFieldsOmitCountersTheKernelDidNotProvide() {
        let reading = ProcessEnergyReading(
            userCPUMilliseconds: 1200,
            systemCPUMilliseconds: 340,
            wakeups: nil,
            energy: nil
        )
        XCTAssertEqual(
            reading.fields,
            ["cpu_user_ms": "1200", "cpu_system_ms": "340"]
        )
    }

    func testFieldsIncludeWakeupsAndEnergyWhenPresent() {
        let reading = ProcessEnergyReading(
            userCPUMilliseconds: 5,
            systemCPUMilliseconds: 6,
            wakeups: 42,
            energy: 9_000_000
        )
        XCTAssertEqual(reading.fields["wakeups"], "42")
        XCTAssertEqual(reading.fields["task_energy"], "9000000")
    }

    func testCountersAreReadableAndNeverGoBackwards() throws {
        let first = try XCTUnwrap(ProcessEnergyReading.current())
        XCTAssertNotNil(first.wakeups)

        // Burn a little CPU so the second read has something to show.
        var accumulator = 0.0
        for index in 0..<2_000_000 {
            accumulator += sin(Double(index))
        }
        XCTAssertFalse(accumulator.isNaN)

        let second = try XCTUnwrap(ProcessEnergyReading.current())
        XCTAssertGreaterThanOrEqual(second.userCPUMilliseconds, first.userCPUMilliseconds)
        XCTAssertGreaterThanOrEqual(second.systemCPUMilliseconds, first.systemCPUMilliseconds)
        XCTAssertGreaterThanOrEqual(second.wakeups ?? 0, first.wakeups ?? 0)
        if let firstEnergy = first.energy, let secondEnergy = second.energy {
            XCTAssertGreaterThanOrEqual(secondEnergy, firstEnergy)
        }
    }

    func testResourceFieldsCarryProcessCPUTime() async {
        let fields = await MainActor.run {
            AppEnvironmentDiagnosticMonitor.resourceFields()
        }
        XCTAssertNotNil(fields["cpu_user_ms"])
        XCTAssertNotNil(fields["cpu_system_ms"])
    }
}
