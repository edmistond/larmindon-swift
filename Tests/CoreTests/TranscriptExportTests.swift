import XCTest
@testable import LarmindonKit

final class TranscriptExportTests: XCTestCase {
    func testFileNameIsSortableAndFileSystemSafe() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 5
        components.hour = 14
        components.minute = 32
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: components)!

        let name = TranscriptExport.fileName(for: date)

        XCTAssertEqual(name, "Larmindon Transcript 2026-09-05 14.32.txt")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testWritesTranscriptUnderRequestedNameWithoutClobberingEarlierExports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try TranscriptExport.write("[Speaker 1] Hello", named: "t.txt", in: directory)
        let second = try TranscriptExport.write("[Speaker 2] Again", named: "t.txt", in: directory)

        XCTAssertEqual(first.lastPathComponent, "t.txt")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "[Speaker 1] Hello\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "[Speaker 2] Again\n")
    }
}
