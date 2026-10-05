import Foundation
import Network
import OSLog

#if os(iOS)
import UIKit
#endif

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    /// Bumped when the envelope or a shared field's meaning changes, so a scorer reading
    /// an old bundle knows which rules apply. 3 added `sequence` and
    /// `monotonicMicroseconds`.
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    /// Wall-clock time, for lining events up with what a person remembers. Never subtract
    /// two of these to measure a delay: the wall clock can step.
    public let timestamp: Date
    /// One per app launch, not per caption session; a Soniox session's events carry their
    /// own `run_id` field.
    public let sessionID: UUID
    /// This process's order of recording, starting at 1. Gaps mean events were lost
    /// between the recorder and the store. Ordering only within one process.
    public let sequence: Int
    /// Microseconds on the monotonic clock, which keeps counting while the device sleeps.
    /// The value to subtract when measuring between events from the same launch.
    public let monotonicMicroseconds: UInt64
    public let category: String
    public let name: String
    public let fields: [String: String]

    public init(
        timestamp: Date = Date(),
        sessionID: UUID,
        sequence: Int = 0,
        monotonicMicroseconds: UInt64 = DiagnosticClock.nowMicroseconds(),
        category: String,
        name: String,
        fields: [String: String] = [:],
        schemaVersion: Int = DiagnosticEvent.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.sequence = sequence
        self.monotonicMicroseconds = monotonicMicroseconds
        self.category = category
        self.name = name
        self.fields = fields
    }
}

/// The clock diagnostic durations are measured on.
public enum DiagnosticClock {
    /// `CLOCK_MONOTONIC_RAW` counts through sleep, so a delay that spans the phone locking
    /// is measured in full, and unlike the wall clock it never steps.
    public static func nowMicroseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000
    }
}

public struct DiagnosticManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let exportedAt: Date
    public let sessionID: UUID
    public let appVersion: String
    public let appBuild: String
    public let operatingSystem: String
    public let deviceClass: String
    public let includesTranscript: Bool
    public let includesRawAudio: Bool
    public let eventCount: Int
    /// Whether `diagnostics.sqlite` is present. It won't be if persistence failed to open,
    /// in which case the bundle falls back to this session's in-memory events only.
    public let includesDatabase: Bool
    /// Events in the database across all retained sessions, as opposed to `eventCount`,
    /// which counts only this session's in-memory ring buffer.
    public let storedEventCount: Int
    public let storedSessionCount: Int
    /// Schema of each event line, so a bundle says which field rules it follows.
    public let eventSchemaVersion: Int
    /// Events this launch failed to write to the database. They are still in the
    /// in-memory ring buffer if it hasn't wrapped, but missing from `diagnostics.sqlite`.
    public let failedWriteEventCount: Int
}

public enum DiagnosticRedaction {
    public static func identifier(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "device-\(String(hash, radix: 16))"
    }
}

public actor DiagnosticRecorder {
    public static let shared = DiagnosticRecorder()

    public let sessionID = UUID()
    private let capacity: Int
    private var events: [DiagnosticEvent] = []
    private let logger = Logger(
        subsystem: "com.davidedmiston.larmindon",
        category: "diagnostics"
    )

    private var store: DiagnosticStore?
    private var pendingWrites: [DiagnosticEvent] = []
    private var flushTask: Task<Void, Never>?
    private var nextSequence = 1
    /// Counted outside the store so a store that keeps failing can still be reported: the
    /// count rides on the next event that does get written, and in the export manifest.
    private var failedWriteEventCount = 0

    /// One transaction per 50 events rather than per event: `soniox_update` alone fires
    /// about once a second, and a commit each time would be constant disk churn in the
    /// user's pocket.
    private static let batchSize = 50
    /// Ceiling on how long an event can sit only in memory. A kill inside this window loses
    /// at most a couple of seconds of context.
    private static let flushInterval = Duration.seconds(2)

    public init(capacity: Int = 2_000) {
        self.capacity = max(100, capacity)
    }

    public func record(
        category: String,
        name: String,
        fields: [String: String] = [:]
    ) {
        let event = DiagnosticEvent(
            sessionID: sessionID,
            sequence: nextSequence,
            category: category,
            name: name,
            fields: fields
        )
        nextSequence += 1
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        logger.info(
            "[\(category, privacy: .public)] \(name, privacy: .public) \(fields.description, privacy: .public)"
        )

        guard store != nil else { return }
        pendingWrites.append(event)
        if pendingWrites.count >= Self.batchSize {
            flushPending()
        } else {
            scheduleFlush()
        }
    }

    public func snapshot() -> [DiagnosticEvent] {
        events
    }

    // MARK: - Persistence

    /// Opens the durable store, records this session, prunes aged-out rows, and reports any
    /// previous session that never got to record an end.
    ///
    /// Separate from `init` because it touches the filesystem and can fail. A failure is
    /// deliberately non-fatal: diagnostics degrading to in-memory-only is much better than
    /// diagnostics taking the app down.
    public func activatePersistence(
        store: DiagnosticStore? = nil,
        retention: TimeInterval = DiagnosticStore.defaultRetention
    ) async {
        guard self.store == nil else { return }

        do {
            let resolved = try store ?? DiagnosticStore(url: DiagnosticStore.defaultURL())
            try await resolved.open()

            // Read this *before* recording the current session, so the current one can't
            // appear in its own report.
            let unexpected = try await resolved.sessionsEndedUnexpectedly(
                excluding: sessionID.uuidString
            )

            try await resolved.startSession(
                sessionID: sessionID.uuidString,
                startedAt: Date(),
                appVersion: Self.bundleValue("CFBundleShortVersionString"),
                appBuild: Self.bundleValue("CFBundleVersion"),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceClass: Self.deviceClass
            )

            let pruned = try await resolved.prune(olderThan: retention)
            self.store = resolved

            record(
                category: "diagnostics",
                name: "persistence_ready",
                fields: [
                    "pruned_events": String(pruned),
                    "stored_events": String((try? await resolved.eventCount()) ?? -1),
                    "stored_sessions": String((try? await resolved.sessionCount()) ?? -1),
                ]
            )

            // The whole point of persisting: a background kill leaves no other trace. This
            // is the only place an unexplained disappearance becomes visible.
            for session in unexpected {
                record(
                    category: "diagnostics",
                    name: "previous_session_ended_unexpectedly",
                    fields: [
                        "session": session.sessionID,
                        "started_at": ISO8601DateFormatter().string(from: session.startedAt),
                        "last_event_at": session.lastEventAt
                            .map { ISO8601DateFormatter().string(from: $0) } ?? "none",
                        "event_count": String(session.eventCount),
                    ]
                )
            }

            // Report each session once. iOS rarely delivers `willTerminate`, so nearly every
            // session ends without `markCleanExit`; left open, each launch re-reported the
            // whole week's backlog (bundle BBE900D2: 849 reports for 35 sessions). The report
            // is written first so a kill right here cannot close a session nobody heard about.
            // Its last event is the best available end time.
            if !unexpected.isEmpty {
                await flush()
                for session in unexpected {
                    try await resolved.endSession(
                        sessionID: session.sessionID,
                        reason: DiagnosticStore.endedUnexpectedlyReason,
                        at: session.lastEventAt ?? session.startedAt
                    )
                }
            }
        } catch {
            logger.error(
                "Diagnostics persistence unavailable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Marks this session as having exited gracefully. Its absence on the next launch is
    /// what identifies a kill, so this must only be called on a real, orderly shutdown.
    public func markCleanExit(reason: String) async {
        guard let store else { return }
        await flush()
        try? await store.endSession(sessionID: sessionID.uuidString, reason: reason)
    }

    /// Writes everything buffered. Called on backgrounding, where a kill may follow with no
    /// further warning.
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil

        guard let store, !pendingWrites.isEmpty else { return }
        let batch = pendingWrites
        pendingWrites.removeAll()

        do {
            try await store.append(batch)
        } catch {
            failedWriteEventCount += batch.count
            logger.error(
                "Diagnostics write failed: \(error.localizedDescription, privacy: .public)"
            )
            // Recorded, not just logged, so the loss shows up in the database (once writes
            // recover) and in the in-memory events of an export. Not flushed from here,
            // which would retry in a loop against a store that is failing.
            let event = DiagnosticEvent(
                sessionID: sessionID,
                sequence: nextSequence,
                category: "diagnostics",
                name: "events_dropped",
                fields: [
                    "reason": "store_write_failed",
                    "dropped_events": String(batch.count),
                    "dropped_events_total": String(failedWriteEventCount),
                    "first_sequence": String(batch.first?.sequence ?? 0),
                    "last_sequence": String(batch.last?.sequence ?? 0),
                    "message": error.localizedDescription,
                ]
            )
            nextSequence += 1
            events.append(event)
            if events.count > capacity {
                events.removeFirst(events.count - capacity)
            }
            pendingWrites.append(event)
        }
    }

    private func flushPending() {
        Task { [weak self] in
            await self?.flush()
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Builds the bundle and returns a **zip archive**, not a directory.
    ///
    /// AirDrop is the intended delivery path, and a folder does not survive a share sheet
    /// the way a single file does. Zipping goes through `NSFileCoordinator`'s `.forUploading`
    /// option, which is the Foundation-native way to archive a directory without pulling in
    /// a compression dependency.
    public func makeExportBundle(transcript: String?) async throws -> URL {
        try Self.zipDirectory(await makeExportDirectory(transcript: transcript))
    }

    /// Stages the bundle contents. Split from the zip step so tests can assert on what goes
    /// into the archive without needing to unzip — there's no Foundation API for reading a
    /// zip, and shelling out to `unzip` doesn't exist in the Simulator.
    func makeExportDirectory(transcript: String?) async throws -> URL {
        // Anything still buffered belongs in the export — usually including the events that
        // prompted the export in the first place.
        await flush()

        let snapshot = events
        let includesTranscript = transcript?.isEmpty == false

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "larmindon-diagnostics-\(sessionID.uuidString)",
                isDirectory: true
            )
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        // The database is the reason the bundle exists now: it carries previous sessions,
        // including any that were killed. The per-session JSONL below stays for the sake of
        // eyeballing a bundle without a SQL client.
        var includesDatabase = false
        var storedEventCount = 0
        var storedSessionCount = 0
        if let store {
            do {
                try await store.writeSnapshot(
                    to: root.appendingPathComponent("diagnostics.sqlite")
                )
                includesDatabase = true
                storedEventCount = (try? await store.eventCount()) ?? 0
                storedSessionCount = (try? await store.sessionCount()) ?? 0
            } catch {
                logger.error(
                    "Diagnostics snapshot failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let manifest = DiagnosticManifest(
            formatVersion: 3,
            exportedAt: Date(),
            sessionID: sessionID,
            appVersion: Self.bundleValue("CFBundleShortVersionString"),
            appBuild: Self.bundleValue("CFBundleVersion"),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceClass: Self.deviceClass,
            includesTranscript: includesTranscript,
            includesRawAudio: false,
            eventCount: snapshot.count,
            includesDatabase: includesDatabase,
            storedEventCount: storedEventCount,
            storedSessionCount: storedSessionCount,
            eventSchemaVersion: DiagnosticEvent.currentSchemaVersion,
            failedWriteEventCount: failedWriteEventCount
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        let eventLines = try snapshot.map { event -> Data in
            var line = try lineEncoder.encode(event)
            line.append(0x0A)
            return line
        }
        var jsonl = Data()
        for line in eventLines {
            jsonl.append(line)
        }
        try jsonl.write(
            to: root.appendingPathComponent("events.jsonl"),
            options: .atomic
        )

        if let transcript, !transcript.isEmpty {
            try Data(transcript.utf8).write(
                to: root.appendingPathComponent("transcript.txt"),
                options: .atomic
            )
        }

        return root
    }

    /// Archives a directory using `NSFileCoordinator`'s `.forUploading` option, which hands
    /// back a temporary zip. The zip is copied somewhere stable before the closure returns,
    /// because the coordinator deletes its temporary copy immediately afterward.
    private static func zipDirectory(_ directory: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(directory.lastPathComponent)
            .appendingPathExtension("zip")

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinatorError
        ) { temporaryZip in
            do {
                try FileManager.default.copyItem(at: temporaryZip, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return destination
    }

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown"
    }

    /// Read via sysctl rather than `UIDevice.current.model`, which is main-actor isolated and
    /// so can't be touched from this actor. The identifier it returns ("iPhone17,1") is also
    /// strictly more useful in a bundle than the word "iPhone" — thermal and memory limits
    /// differ by model, and both matter for diagnosing a background kill.
    private static var deviceClass: String {
        #if os(iOS)
        let key = "hw.machine"
        #else
        let key = "hw.model"
        #endif

        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown"
        }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else {
            return "Unknown"
        }
        return String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
    }
}

public final class NetworkPathDiagnosticMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "com.davidedmiston.larmindon.network-path"
    )
    private let recorder: DiagnosticRecorder

    public init(recorder: DiagnosticRecorder = .shared) {
        self.recorder = recorder
        monitor.pathUpdateHandler = { [recorder] path in
            Task {
                await recorder.record(
                    category: "network",
                    name: "path_changed",
                    fields: [
                        "status": String(describing: path.status),
                        "expensive": String(path.isExpensive),
                        "constrained": String(path.isConstrained),
                        "interfaces": path.availableInterfaces
                            .map { String(describing: $0.type) }
                            .sorted()
                            .joined(separator: ","),
                    ]
                )
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
