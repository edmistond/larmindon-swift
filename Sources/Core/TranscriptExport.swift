import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The transcript as a shareable `.txt` file, for the share sheet's Save to Files, AirDrop,
/// Mail and friends.
///
/// The text is rendered and written only when a share destination asks for it. A
/// `ShareLink` builds its item every time the toolbar re-evaluates, which during capture is
/// every caption update, so the item must be cheap to construct — it just holds the store.
public struct TranscriptExport: Transferable, Sendable {
    public let store: CaptionStore
    public let createdAt: Date

    public init(store: CaptionStore, createdAt: Date = Date()) {
        self.store = store
        self.createdAt = createdAt
    }

    /// `Larmindon Transcript 2026-09-05 14.32.txt`. Sortable, and free of the slashes and
    /// colons that a locale-formatted timestamp would put in a file name.
    public var suggestedFileName: String {
        Self.fileName(for: createdAt)
    }

    public static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Larmindon Transcript \(formatter.string(from: date)).txt"
    }

    /// Writes the transcript into a fresh subdirectory of `directory` so the file can carry
    /// its user-facing name without colliding with an earlier export.
    public static func write(
        _ text: String,
        named fileName: String,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName, directoryHint: .notDirectory)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            // `fullTranscript` already carries `[Speaker N]` markers when the provider
            // reports speakers, so the file matches what "Copy Full Transcript" produces.
            let text = await export.store.fullTranscript
            let url = try Self.write(text, named: export.suggestedFileName)
            return SentTransferredFile(url)
        }
    }
}
