import Testing
import Foundation
import CoreServices
@testable import ForelCore

@Suite struct FilesystemEventTests {
    func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func migrationCreatesFilesystemEventsTable() throws {
        let db = try makeDB()
        // Inserting requires the table to exist; this round-trips an event
        // to prove the migration ran on a fresh database.
        let event = FilesystemEvent(source: .scan, kind: .discovered, path: "/tmp/a.txt")
        try db.insertFilesystemEvent(event)
        let events = try db.listRecentFilesystemEvents()
        #expect(events.count == 1)
    }

    @Test func roundTripsDiscoveredEvent() throws {
        let db = try makeDB()
        let event = FilesystemEvent(batchId: "batch-1", source: .scan, kind: .discovered, path: "/tmp/a.txt")
        try db.insertFilesystemEvent(event)

        let loaded = try #require(db.listFilesystemEvents(batchId: "batch-1").first)
        #expect(loaded.id == event.id)
        #expect(loaded.source == .scan)
        #expect(loaded.kind == .discovered)
        #expect(loaded.path == "/tmp/a.txt")
        #expect(loaded.isForelOriginated == false)
        #expect(loaded.volumeId == nil)
        #expect(loaded.fileId == nil)
    }

    @Test func roundTripsEventWithVolumeAndFileId() throws {
        let db = try makeDB()
        let event = FilesystemEvent(
            source: .fsevents,
            kind: .created,
            path: "/tmp/b.txt",
            volumeId: 42,
            fileId: 1234,
            contentFingerprint: "100-1700000000-0",
            rawFlags: 256
        )
        try db.insertFilesystemEvent(event)

        let loaded = try #require(db.listFilesystemEvents(path: "/tmp/b.txt").first)
        #expect(loaded.volumeId == 42)
        #expect(loaded.fileId == 1234)
        #expect(loaded.contentFingerprint == "100-1700000000-0")
        #expect(loaded.rawFlags == 256)
    }

    @Test func scanDiscoveryDoesNotChangeRuleExecution() throws {
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let path = dir.file("a.txt")
        let rule = makeRule(folderId: folder.id, name: "noop", actions: [])

        let depth = RuleEngine.pathDepth(root: dir.path, path: path) ?? 0
        let (matchedBefore, historyBefore) = RuleEngine.evaluateFile(path: path, depth: depth, rules: [rule], batchId: "b1", root: dir.path)

        // Recording a discovered event must be side-effect free for the
        // engine: re-running evaluation gives the same result.
        let db = try makeDB()
        try db.insertFilesystemEvent(FilesystemEvent(source: .scan, kind: .discovered, path: path))
        let (matchedAfter, historyAfter) = RuleEngine.evaluateFile(path: path, depth: depth, rules: [rule], batchId: "b2", root: dir.path)

        #expect(matchedBefore == matchedAfter)
        #expect(historyBefore.count == historyAfter.count)
    }

    @Test func forelActionEventsSkipNonAppliedHistory() throws {
        let history = [
            HistoryEntry(batchId: "b1", ruleId: "r1", ruleName: "rule", actionKind: .moveToFolder, originalPath: "/a", resultPath: "/b/a", undo: Undo.move(from: "/a", to: "/b/a").toJSON(), reversible: true, status: .applied),
            HistoryEntry(batchId: "b1", ruleId: "r1", ruleName: "rule", actionKind: .addTag, originalPath: "/c", resultPath: "/c", undo: Undo.none.toJSON(), reversible: false, status: .skipped),
            HistoryEntry(batchId: "b1", ruleId: "r1", ruleName: "rule", actionKind: .delete, originalPath: "/d", resultPath: "/d", undo: Undo.none.toJSON(), reversible: false, status: .failed),
        ]

        let events = FilesystemEvent.forelActionEvents(batchId: "b1", history: history)

        #expect(events.count == 1)
        #expect(events[0].source == .forelAction)
        #expect(events[0].kind == .renamed)
        #expect(events[0].path == "/b/a")
        #expect(events[0].previousPath == "/a")
        #expect(events[0].isForelOriginated)
    }

    @Test func fsEventsKindDerivesFromFlags() throws {
        #expect(WatcherCoordinator.kind(forFlags: UInt32(kFSEventStreamEventFlagItemCreated)) == .created)
        #expect(WatcherCoordinator.kind(forFlags: UInt32(kFSEventStreamEventFlagItemRenamed)) == .renamed)
        #expect(WatcherCoordinator.kind(forFlags: 0) == .unknown)
    }
}
