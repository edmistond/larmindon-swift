import SQLite3
import XCTest
@testable import LarmindonKit

final class SQLiteStatementRowsTests: XCTestCase {
    func testStepFailureAfterSuccessfulRowThrowsInsteadOfReturningDone() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        // ABS of the smallest signed integer fails during the second step, not prepare.
        let sql = "SELECT abs(value) FROM (SELECT 1 AS value UNION ALL SELECT -9223372036854775808);"
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        XCTAssertTrue(try SQLiteStatementRows.next(prepared))
        XCTAssertEqual(sqlite3_column_int64(prepared, 0), 1)
        XCTAssertThrowsError(try SQLiteStatementRows.next(prepared)) { error in
            guard case DiagnosticStoreError.sql(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("integer overflow"))
        }
    }

    func testDoneIsSuccessfulEndOfRows() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT 7;", -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        XCTAssertTrue(try SQLiteStatementRows.next(prepared))
        XCTAssertFalse(try SQLiteStatementRows.next(prepared))
    }
}
