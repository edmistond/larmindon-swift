import Foundation
import SQLite3

/// SQLite doesn't expose these to Swift. `TRANSIENT` tells SQLite to copy the bound bytes
/// rather than keep a pointer into a Swift string that may not outlive the statement.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

public struct DiagnosticSessionSummary: Equatable, Sendable {
    public let sessionID: String
    public let startedAt: Date
    public let endedAt: Date?
    public let endReason: String?
    public let lastEventAt: Date?
    public let eventCount: Int

    /// A session with no recorded end never got the chance to write one — a jetsam kill, a
    /// crash, or a force-quit. Distinguishing those is what the surrounding `lifecycle` and
    /// `resources` events are for; this flag only says the exit wasn't graceful.
    public var endedUnexpectedly: Bool { endedAt == nil }
}

public enum DiagnosticStoreError: LocalizedError {
    case open(String)
    case sql(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message):
            return "Could not open the diagnostics database: \(message)"
        case .sql(let message):
            return "Diagnostics database error: \(message)"
        }
    }
}

/// Durable event storage.
///
/// The in-memory ring buffer this sits behind cannot answer the question that matters most
/// now that captions survive backgrounding: *why did the app stop?* A jetsam kill gives the
/// process no chance to export anything, so the evidence has to already be on disk before
/// the kill happens.
///
/// Everything is serialized through the actor, so the SQLite handle needs no threading mode
/// beyond the default.
public actor DiagnosticStore {
    private var database: OpaquePointer?
    private let url: URL

    /// Rows older than this are dropped at launch. A week spans "it worked Tuesday, not
    /// Friday" without letting the file grow without bound.
    public static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Larmindon", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("diagnostics.sqlite")
    }

    public func open() throws {
        guard database == nil else { return }

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message =
                handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "code \(result)"
            sqlite3_close_v2(handle)
            throw DiagnosticStoreError.open(message)
        }
        database = handle

        // WAL so a reader (the export copy) never blocks the writer, and NORMAL so a
        // backgrounded session isn't fsyncing on every batch. The cost of NORMAL is losing
        // the last few events on an OS-level power loss, which is not the failure being
        // investigated here.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try migrate()
    }

    public func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = try currentSchemaVersion()
        guard version < 1 else { return }

        try execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                end_reason TEXT,
                app_version TEXT,
                app_build TEXT,
                os_version TEXT,
                device_class TEXT
            );

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                session_id TEXT NOT NULL,
                category TEXT NOT NULL,
                name TEXT NOT NULL,
                fields TEXT NOT NULL DEFAULT '{}'
            );

            CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
            CREATE INDEX IF NOT EXISTS events_session ON events(session_id, id);
            CREATE INDEX IF NOT EXISTS events_category ON events(category, name);
            """
        )
        try execute("PRAGMA user_version = 1;")
    }

    private func currentSchemaVersion() throws -> Int {
        try query("PRAGMA user_version;") { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
    }

    // MARK: - Writing

    public func startSession(
        sessionID: String,
        startedAt: Date,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        deviceClass: String
    ) throws {
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO sessions
                (session_id, started_at, app_version, app_build, os_version, device_class)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, sessionID)
        sqlite3_bind_double(statement, 2, startedAt.timeIntervalSince1970)
        bind(statement, 3, appVersion)
        bind(statement, 4, appBuild)
        bind(statement, 5, osVersion)
        bind(statement, 6, deviceClass)
        try step(statement)
    }

    /// The `end_reason` for a session closed after being reported as unexpectedly ended.
    /// Its `ended_at` is the last event it recorded, not an observed exit.
    public static let endedUnexpectedlyReason = "ended_unexpectedly"

    public func endSession(sessionID: String, reason: String, at date: Date = Date()) throws {
        let statement = try prepare(
            "UPDATE sessions SET ended_at = ?, end_reason = ? WHERE session_id = ?;"
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        bind(statement, 2, reason)
        bind(statement, 3, sessionID)
        try step(statement)
    }

    /// Batched deliberately: one transaction per flush rather than per event keeps a
    /// once-a-second event stream from turning into a once-a-second disk commit.
    public func append(_ events: [DiagnosticEvent]) throws {
        guard !events.isEmpty else { return }

        try execute("BEGIN IMMEDIATE;")
        do {
            let statement = try prepare(
                """
                INSERT INTO events (ts, session_id, category, name, fields)
                VALUES (?, ?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(statement) }

            for event in events {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_double(statement, 1, event.timestamp.timeIntervalSince1970)
                bind(statement, 2, event.sessionID.uuidString)
                bind(statement, 3, event.category)
                bind(statement, 4, event.name)
                bind(statement, 5, Self.encodeFields(event.fields))
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Stored as JSON so a field can be queried directly —
    /// `WHERE json_extract(fields, '$.decision') LIKE 'give_up%'` — rather than parsed out
    /// of a blob after the fact.
    static func encodeFields(_ fields: [String: String]) -> String {
        guard !fields.isEmpty,
            let data = try? JSONSerialization.data(
                withJSONObject: fields,
                options: [.sortedKeys]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    // MARK: - Reading

    /// Sessions from previous launches that never recorded an end. The current session is
    /// excluded because it is, by definition, still running.
    public func sessionsEndedUnexpectedly(excluding currentSessionID: String) throws
        -> [DiagnosticSessionSummary]
    {
        let statement = try prepare(
            """
            SELECT s.session_id, s.started_at, s.ended_at, s.end_reason,
                   (SELECT MAX(ts) FROM events e WHERE e.session_id = s.session_id),
                   (SELECT COUNT(*) FROM events e WHERE e.session_id = s.session_id)
            FROM sessions s
            WHERE s.ended_at IS NULL AND s.session_id != ?
            ORDER BY s.started_at DESC;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, currentSessionID)

        var summaries: [DiagnosticSessionSummary] = []
        while try SQLiteStatementRows.next(statement) {
            summaries.append(
                DiagnosticSessionSummary(
                    sessionID: text(statement, 0) ?? "",
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    endedAt: nil,
                    endReason: text(statement, 3),
                    lastEventAt: sqlite3_column_type(statement, 4) == SQLITE_NULL
                        ? nil
                        : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    eventCount: Int(sqlite3_column_int64(statement, 5))
                )
            )
        }
        return summaries
    }

    /// Most recent events first. Exists for verification and for a future in-app history
    /// view; the export path uses `writeSnapshot` instead.
    public func recentEvents(limit: Int = 200) throws -> [DiagnosticEvent] {
        let statement = try prepare(
            """
            SELECT ts, session_id, category, name, fields
            FROM events ORDER BY id DESC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))

        var results: [DiagnosticEvent] = []
        while try SQLiteStatementRows.next(statement) {
            results.append(
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    sessionID: UUID(uuidString: text(statement, 1) ?? "") ?? UUID(),
                    category: text(statement, 2) ?? "",
                    name: text(statement, 3) ?? "",
                    fields: Self.decodeFields(text(statement, 4))
                )
            )
        }
        return results
    }

    static func decodeFields(_ json: String?) -> [String: String] {
        guard let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: String]
        else {
            return [:]
        }
        return object
    }

    public func eventCount() throws -> Int {
        try query("SELECT COUNT(*) FROM events;") { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
    }

    public func sessionCount() throws -> Int {
        try query("SELECT COUNT(*) FROM sessions;") { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
    }

    // MARK: - Retention

    /// Pruned at launch rather than continuously: deleting while a session is running would
    /// add write pressure to the exact path being measured, and the file cannot grow
    /// meaningfully within one session.
    @discardableResult
    public func prune(
        olderThan retention: TimeInterval = DiagnosticStore.defaultRetention,
        now: Date = Date()
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970

        let deleteEvents = try prepare("DELETE FROM events WHERE ts < ?;")
        defer { sqlite3_finalize(deleteEvents) }
        sqlite3_bind_double(deleteEvents, 1, cutoff)
        try step(deleteEvents)
        let removed = Int(sqlite3_changes(database))

        // Sessions outlive their events only if every event aged out; drop those too so the
        // session list doesn't accumulate empty rows forever.
        let deleteSessions = try prepare(
            """
            DELETE FROM sessions
            WHERE started_at < ?
              AND NOT EXISTS (SELECT 1 FROM events e WHERE e.session_id = sessions.session_id);
            """
        )
        defer { sqlite3_finalize(deleteSessions) }
        sqlite3_bind_double(deleteSessions, 1, cutoff)
        try step(deleteSessions)

        return removed
    }

    // MARK: - Export

    /// Writes a consistent single-file copy.
    ///
    /// `VACUUM INTO` rather than copying the file: a WAL database lives across `.sqlite`,
    /// `-wal`, and `-shm`, so copying just the first can capture a database missing its most
    /// recent — and most relevant — writes.
    public func writeSnapshot(to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        try execute("VACUUM INTO '\(escaped)';")
    }

    // MARK: - SQLite plumbing

    private func execute(_ sql: String) throws {
        guard let database else {
            throw DiagnosticStoreError.sql("database is not open")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "code \(result)"
            sqlite3_free(errorMessage)
            throw DiagnosticStoreError.sql(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw DiagnosticStoreError.sql("database is not open")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw DiagnosticStoreError.sql(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            let message =
                database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "code \(result)"
            throw DiagnosticStoreError.sql(message)
        }
    }

    private func query<T>(
        _ sql: String,
        transform: (OpaquePointer) -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while try SQLiteStatementRows.next(statement) {
            results.append(transform(statement))
        }
        return results
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }
}

/// Shared by every diagnostic read loop. An error after some rows must throw,
/// not masquerade as SQLITE_DONE and return an apparently successful partial read.
enum SQLiteStatementRows {
    static func next(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let message = String(cString: sqlite3_errmsg(sqlite3_db_handle(statement)))
            throw DiagnosticStoreError.sql("\(message) (code \(result))")
        }
    }
}
