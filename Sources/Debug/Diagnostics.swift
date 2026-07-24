import Foundation
import Network
import OSLog

#if os(iOS)
import UIKit
#endif

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let sessionID: UUID
    public let category: String
    public let name: String
    public let fields: [String: String]

    public init(
        timestamp: Date = Date(),
        sessionID: UUID,
        category: String,
        name: String,
        fields: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.category = category
        self.name = name
        self.fields = fields
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
            category: category,
            name: name,
            fields: fields
        )
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        logger.info(
            "[\(category, privacy: .public)] \(name, privacy: .public) \(fields.description, privacy: .public)"
        )
    }

    public func snapshot() -> [DiagnosticEvent] {
        events
    }

    public func makeExportBundle(transcript: String?) throws -> URL {
        let snapshot = events
        let includesTranscript = transcript?.isEmpty == false
        let manifest = DiagnosticManifest(
            formatVersion: 1,
            exportedAt: Date(),
            sessionID: sessionID,
            appVersion: Self.bundleValue("CFBundleShortVersionString"),
            appBuild: Self.bundleValue("CFBundleVersion"),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceClass: Self.deviceClass,
            includesTranscript: includesTranscript,
            includesRawAudio: false,
            eventCount: snapshot.count
        )

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

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown"
    }

    private static var deviceClass: String {
        #if os(iOS)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
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
