import Testing
import Foundation
import CoreServices
@testable import ForelCore

@Suite struct WatcherCoordinatorTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func fsEventTriggersPlanAndExecution() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemCreated))

        let movedPath = (destination as NSString).appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: movedPath))
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try db.listHistory().count == 1)
    }

    @Test func forelEchoIsObservedButDoesNotRerunRules() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        try db.upsertFileState(FileState(
            path: file,
            volumeId: FileFingerprint.identity(file)?.volumeId,
            fileId: FileFingerprint.identity(file)?.fileId,
            contentFingerprint: FileFingerprint.current(file)
        ))

        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "tag")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemModified))

        // The event is observed (fsevents row exists) but rules did not run.
        #expect(try db.listFilesystemEvents(path: file).contains { $0.source == .fsevents })
        #expect(try db.listHistory().isEmpty)
    }

    @Test func alreadyInDestinationIsSkippedByWatcher() throws {
        let db = try makeDB()
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sort pdf", recursionDepth: nil)
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: existing, flags: UInt32(kFSEventStreamEventFlagItemCreated))

        #expect(FileManager.default.fileExists(atPath: existing))
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
        #expect(try db.listHistory().isEmpty)
    }

    @Test func startupScanUsesThePlanner() throws {
        let db = try makeDB()
        let dir = TempDir()
        _ = dir.file("a.txt")
        let destination = dir.dir("Archive")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.runStartupScan(folder: folder)

        let movedPath = (destination as NSString).appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: movedPath))
        #expect(try db.listHistory().count == 1)
        #expect(try db.listRecentFilesystemEvents().contains { $0.source == .scan && $0.kind == .discovered })
    }

    @Test func runNowAndWatcherProduceTheSamePlannedActionForTheSameFile() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let depth = RuleEngine.pathDepth(root: dir.path, path: file) ?? 0
        let viaWatcherPlanner = RulePlanner.planFile(path: file, depth: depth, rules: [rule], root: dir.path)
        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let viaRunNowPlan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        let runNowFile = try #require(viaRunNowPlan.files.first { $0.path == file })
        let watcherFile = try #require(viaWatcherPlanner)

        #expect(runNowFile.rules.map { $0.actions.map(\.status) } == watcherFile.rules.map { $0.actions.map(\.status) })
        #expect(runNowFile.rules.map { $0.actions.map(\.targetPath) } == watcherFile.rules.map { $0.actions.map(\.targetPath) })
    }

    @Test func repeatedIdenticalEventsDoNotReapplyActionsAfterFirstRun() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "tag")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        #expect(try db.listHistory().count == 1)

        // A second, identical FSEvent for the same now-tagged file (its own
        // echo) must not re-run the rule.
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemModified))
        #expect(try db.listHistory().count == 1)
    }
}
