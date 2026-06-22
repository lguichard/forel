// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Testing
import Foundation
@testable import ForelCore

@Suite struct WatcherCoordinatorTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func handleTriggersPlanAndExecution() throws {
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
        coordinator.handle(path: file)

        let movedPath = (destination as NSString).appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: movedPath))
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try db.listHistory().count == 1)
    }

    /// The bug this whole table exists to fix: `copyToFolder` never moves
    /// its source out of scope, so repeated/duplicate FSEvents for the same
    /// untouched file used to keep re-copying — piling up Activity entries
    /// indefinitely under the watcher (Run Now, a single pass, never showed
    /// the problem).
    @Test func repeatedEventsForAnUnchangedSourceDoNotPileUpCopies() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.png")
        let destination = dir.dir("PNGCopies")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "png copy")
        rule.conditions = [makeCondition(.extension_, .is, "png", ruleId: rule.id)]
        rule.actions = [makeAction(.copyToFolder, .object([
            "destination": .string(destination),
            "on_conflict": .string("replace"),
        ]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        for _ in 0..<5 {
            coordinator.handle(path: file)
        }

        #expect(try db.listHistory().count == 1)
    }

    /// A duplicate/coalesced FSEvent for the *original* path of a file the
    /// watcher just successfully moved away must not be replanned and fail
    /// with a noisy "doesn't exist" entry — there's nothing left to evaluate.
    @Test func duplicateEventForAnAlreadyMovedAwayPathRecordsNoFailure() throws {
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
        coordinator.handle(path: file)
        coordinator.handle(path: file) // duplicate event for the now-vacated path

        let history = try db.listHistory()
        #expect(history.count == 1)
        #expect(history[0].status == .applied)
    }

    /// Regression guard for the inverse bug: a path nothing has evaluated
    /// before — like a file a previous rule just moved here — must still get
    /// its full chance, even though the destination folder is also watched.
    @Test func laterRuleStillAppliesAfterAnEarlierRuleMovedTheFile() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.png")
        let pngDir = dir.dir("PNG")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)

        var moveRule = makeRule(folderId: folder.id, name: "move pngs")
        moveRule.conditions = [makeCondition(.extension_, .is, "png", ruleId: moveRule.id)]
        moveRule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pngDir)]), position: 0, ruleId: moveRule.id)]
        try db.insertRule(moveRule)

        var colorRule = makeRule(folderId: folder.id, name: "color pngs", recursionDepth: 3)
        colorRule.conditions = [makeCondition(.extension_, .is, "png", ruleId: colorRule.id)]
        colorRule.actions = [makeAction(.setColorLabel, .object(["color": .string("Blue")]), position: 0, ruleId: colorRule.id)]
        try db.insertRule(colorRule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)

        let movedPath = (pngDir as NSString).appendingPathComponent("a.png")
        #expect(FileManager.default.fileExists(atPath: movedPath))

        // The move's own follow-up FSEvent for the new path.
        coordinator.handle(path: movedPath)

        #expect(FinderTags.currentColorName(movedPath) == "blue")
        #expect(try db.listHistory().contains { $0.actionKind == .setColorLabel && $0.status == .applied })
    }

    @Test func resultEventAfterMoveAndRenameDoesNotRepeatTheSameRule() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.png")
        let pngDir = dir.dir("PNG")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)

        var rule = makeRule(folderId: folder.id, name: "move and rename", recursionDepth: 2)
        rule.conditions = [makeCondition(.extension_, .is, "png", ruleId: rule.id)]
        rule.actions = [
            makeAction(.moveToFolder, .object(["destination": .string(pngDir)]), position: 0, ruleId: rule.id),
            makeAction(.rename, .object(["pattern": .string("{name}-moved")]), position: 1, ruleId: rule.id),
        ]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)

        let renamedPath = (pngDir as NSString).appendingPathComponent("a-moved.png")
        #expect(FileManager.default.fileExists(atPath: renamedPath))

        coordinator.handle(path: renamedPath)

        let repeatedPath = (pngDir as NSString).appendingPathComponent("a-moved-moved.png")
        #expect(FileManager.default.fileExists(atPath: renamedPath))
        #expect(!FileManager.default.fileExists(atPath: repeatedPath))
        #expect(try db.listHistory().filter { $0.ruleId == rule.id }.count == 2)
    }

    @Test func alreadyInDestinationIsSkippedByTheWatcher() throws {
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
        coordinator.handle(path: existing)

        #expect(FileManager.default.fileExists(atPath: existing))
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
    }

    @Test func syncFolderTargetChangeCopiesBackToWatchedRoot() throws {
        let db = try makeDB()
        let dir = TempDir()
        let source = dir.dir("Source")
        let target = dir.dir("Target")
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target),
            ActionParam.syncDirection: .string(SyncDirection.twoWay.rawValue),
        ]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let file = (target as NSString).appendingPathComponent("a.txt")
        try "target".write(toFile: file, atomically: true, encoding: .utf8)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file, kind: .changed)

        let copied = (source as NSString).appendingPathComponent("a.txt")
        #expect(try String(contentsOfFile: copied, encoding: .utf8) == "target")
        let history = try db.listHistory()
        #expect(history.count == 1)
        #expect(history[0].actionKind == .syncFolders)
        #expect(history[0].status == .applied)
    }

    @Test func syncFolderDeletionMovesCounterpartToTrash() throws {
        let db = try makeDB()
        let dir = TempDir()
        let source = dir.dir("Source")
        let target = dir.dir("Target")
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target),
            ActionParam.syncDirection: .string(SyncDirection.twoWay.rawValue),
            ActionParam.syncDeletePolicy: .string(SyncDeletePolicy.moveToTrash.rawValue),
        ]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let deleted = (source as NSString).appendingPathComponent("a.txt")
        let counterpart = (target as NSString).appendingPathComponent("a.txt")
        try "other".write(toFile: counterpart, atomically: true, encoding: .utf8)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: deleted, kind: .deleted)

        #expect(!FileManager.default.fileExists(atPath: counterpart))
        let history = try db.listHistory()
        #expect(history.count == 1)
        #expect(history[0].actionKind == .syncFolders)
        #expect(history[0].reversible)
    }

    @Test func syncFolderMissingChangedEventIsTreatedAsDeletion() throws {
        let db = try makeDB()
        let dir = TempDir()
        let source = dir.dir("Source")
        let target = dir.dir("Target")
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target),
            ActionParam.syncDirection: .string(SyncDirection.twoWay.rawValue),
            ActionParam.syncDeletePolicy: .string(SyncDeletePolicy.moveToTrash.rawValue),
        ]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let deleted = (source as NSString).appendingPathComponent("a.txt")
        let counterpart = (target as NSString).appendingPathComponent("a.txt")
        try "other".write(toFile: counterpart, atomically: true, encoding: .utf8)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: deleted)

        #expect(!FileManager.default.fileExists(atPath: counterpart))
        let history = try db.listHistory()
        #expect(history.count == 1)
        #expect(history[0].actionKind == .syncFolders)
    }
}
