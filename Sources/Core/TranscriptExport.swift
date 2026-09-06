import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The transcript as a shareable `.txt` file, for the share sheet's Save to Files, AirDrop,
/// Mail and friends.
///
/// Holds a snapshot of the caption arrays rather than the store. Copying the arrays is a
/// copy-on-write reference bump, so a `ShareLink` can rebuild this on every caption update,
/// and the export closure needs no hop back to the main actor. That matters: the iOS share
/// sheet loads item representations while blocking the main thread, so an export that
/// awaits the main actor sits there until the system gives up waiting.
public struct TranscriptExport: Transferable, Sendable {
    public let finalizedChunks: [TranscriptChunk]
    public let volatileCaptions: [VolatileCaption]
    public let createdAt: Date

    public init(
        finalizedChunks: [TranscriptChunk],
        volatileCaptions: [VolatileCaption],
        createdAt: Date = Date()
    ) {
        self.finalizedChunks = finalizedChunks
        self.volatileCaptions = volatileCaptions
        self.createdAt = createdAt
    }

    @MainActor
    public init(store: CaptionStore, createdAt: Date = Date()) {
        self.init(
            finalizedChunks: store.finalizedChunks,
            volatileCaptions: store.volatileCaptions,
            createdAt: createdAt
        )
    }

    public var isEmpty: Bool {
        finalizedChunks.isEmpty && volatileCaptions.isEmpty
    }

    /// Same rendering as `CaptionStore.fullTranscript`, `[Speaker N]` markers included when
    /// the provider reports speakers, so the file matches what "Copy Full Transcript" gives.
    public var text: String {
        CaptionStore.transcript(
            for: finalizedChunks.map(CaptionLine.finalized)
                + volatileCaptions.map(CaptionLine.volatile)
        )
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
            SentTransferredFile(try Self.write(export.text, named: export.suggestedFileName))
        }
    }
}
