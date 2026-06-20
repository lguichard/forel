import Foundation

/// Where an observed filesystem fact came from.
public enum FilesystemEventSource: String, Codable, Equatable, Sendable {
    case fsevents
    case scan
    case runNow = "run_now"
    case forelAction = "forel_action"
    case undo

    public init(dbValue: String) {
        self = FilesystemEventSource(rawValue: dbValue) ?? .scan
    }
}

/// What kind of change was observed.
public enum FilesystemEventKind: String, Codable, Equatable, Sendable {
    case created
    case modified
    case renamed
    case removed
    case discovered
    case unknown

    public init(dbValue: String) {
        self = FilesystemEventKind(rawValue: dbValue) ?? .unknown
    }
}

/// A fact observed on the filesystem, journaled before any planning happens.
/// Distinct from an `ExecutionPlan` (an intention Forel computed) and a
/// `HistoryEntry` (an action Forel actually applied).
public struct FilesystemEvent: Codable, Equatable, Sendable {
    public var id: String
    public var batchId: String?
    public var source: FilesystemEventSource
    public var kind: FilesystemEventKind
    public var path: String
    public var previousPath: String?
    public var volumeId: Int64?
    public var fileId: Int64?
    public var contentFingerprint: String?
    public var rawFlags: Int64?
    public var isForelOriginated: Bool
    public var createdAt: String

    public init(
        id: String = UUID().uuidString,
        batchId: String? = nil,
        source: FilesystemEventSource,
        kind: FilesystemEventKind,
        path: String,
        previousPath: String? = nil,
        volumeId: Int64? = nil,
        fileId: Int64? = nil,
        contentFingerprint: String? = nil,
        rawFlags: Int64? = nil,
        isForelOriginated: Bool = false,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.batchId = batchId
        self.source = source
        self.kind = kind
        self.path = path
        self.previousPath = previousPath
        self.volumeId = volumeId
        self.fileId = fileId
        self.contentFingerprint = contentFingerprint
        self.rawFlags = rawFlags
        self.isForelOriginated = isForelOriginated
        self.createdAt = createdAt
    }

    /// Converts applied (non-skipped, non-failed) history entries from one
    /// rule run into `FilesystemEvent(source=forel_action)` so the journal
    /// records what Forel itself changed.
    public static func forelActionEvents(batchId: String, history: [HistoryEntry]) -> [FilesystemEvent] {
        history
            .filter { $0.status == .applied }
            .map { entry in
                FilesystemEvent(
                    batchId: batchId,
                    source: .forelAction,
                    kind: eventKind(forActionKind: entry.actionKind),
                    path: entry.resultPath,
                    previousPath: entry.originalPath == entry.resultPath ? nil : entry.originalPath,
                    contentFingerprint: FileFingerprint.current(entry.resultPath),
                    isForelOriginated: true
                )
            }
    }

    private static func eventKind(forActionKind kind: ActionKind) -> FilesystemEventKind {
        switch kind {
        case .moveToFolder, .rename:
            return .renamed
        case .copyToFolder:
            return .created
        case .moveToTrash, .delete:
            return .removed
        case .addTag, .removeTag, .setColorLabel, .runScript, .runShortcut:
            return .modified
        }
    }
}
