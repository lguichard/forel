import Foundation

/// Last known identity/fingerprint Forel observed for a path, persisted so
/// the watcher's "new-or-changed" gate and undo guards can tell whether a
/// file has changed since Forel last looked at it.
public struct FileState: Codable, Equatable, Sendable {
    public var path: String
    public var volumeId: Int64?
    public var fileId: Int64?
    public var contentFingerprint: String?
    public var updatedAt: String

    public init(
        path: String,
        volumeId: Int64? = nil,
        fileId: Int64? = nil,
        contentFingerprint: String? = nil,
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.path = path
        self.volumeId = volumeId
        self.fileId = fileId
        self.contentFingerprint = contentFingerprint
        self.updatedAt = updatedAt
    }

    /// Derives the `file_state` upserts/deletes a completed run should apply,
    /// from the `applied` entries in its `ActionHistory`. A path that moved
    /// drops its old `file_state` row and gains one at the new path; an
    /// unchanged path (tag/color/copy) just refreshes its fingerprint.
    public static func updatesFromHistory(_ history: [HistoryEntry]) -> (upserts: [FileState], deletes: [String]) {
        var upserts: [String: FileState] = [:]
        var deletes: Set<String> = []

        for entry in history where entry.status == .applied {
            if entry.originalPath != entry.resultPath {
                deletes.insert(entry.originalPath)
                upserts.removeValue(forKey: entry.originalPath)
            }
            let identity = FileFingerprint.identity(entry.resultPath)
            upserts[entry.resultPath] = FileState(
                path: entry.resultPath,
                volumeId: identity?.volumeId,
                fileId: identity?.fileId,
                contentFingerprint: FileFingerprint.current(entry.resultPath)
            )
            deletes.remove(entry.resultPath)
        }

        return (Array(upserts.values), Array(deletes))
    }
}
