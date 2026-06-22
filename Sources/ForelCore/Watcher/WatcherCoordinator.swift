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

import Foundation

/// Wires `FileWatcher` events to the database and rule engine: for every
/// created/renamed path, finds the owning watched folder, loads its rules,
/// evaluates them, and persists any resulting action history. Mirrors
/// `watcher::on_event` / `load_folder_and_rules_for_path`.
public final class WatcherCoordinator: @unchecked Sendable {
    private let db: Database
    private let watcher: FileWatcher
    public var onRuleMatched: (@Sendable (String, String) -> Void)?

    public init(db: Database) {
        self.db = db
        var watcherRef: FileWatcher!
        watcherRef = FileWatcher(onEvent: { _, _ in })
        self.watcher = watcherRef
        self.watcher.replaceHandler { [weak self] path, kind in
            self?.handle(path: path, kind: kind)
        }
    }

    public func add(_ path: String) {
        watcher.add(path)
        for target in syncTargets(forWatchedFolderPath: path) {
            watcher.add(target)
        }
    }
    public func remove(_ path: String) { watcher.remove(path) }
    public func removeAll() { watcher.replaceAll([]) }
    public func refreshWatchedPaths() {
        let paths = db.withLock { db -> Set<String> in
            let folders = ((try? db.listFolders()) ?? []).filter(\.enabled)
            var paths = Set(folders.map(\.path))
            for folder in folders {
                for target in syncTargets(for: folder, db: db) {
                    paths.insert(target)
                }
            }
            return paths
        }
        watcher.replaceAll(paths)
    }

    func handle(path: String) {
        handle(path: path, kind: .changed)
    }

    func handle(path: String, kind: FileWatcher.EventKind) {
        if kind == .deleted {
            handleDeleted(path: path)
            return
        }

        if !FileManager.default.fileExists(atPath: path) {
            handleDeleted(path: path)
            return
        }

        // A duplicate/coalesced FSEvent for a path a prior call already
        // moved away — common with FSEvents — would otherwise be replanned
        // (name/extension conditions don't require the file to exist) and
        // then fail at execution with a noisy "doesn't exist" entry.
        // Nothing meaningful can be evaluated against a path that's gone.
        guard hasPathChangedSinceLastEvaluation(path) else { return }

        if handleSyncTargetChange(path: path) { return }

        guard let (folder, rules) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = (try? db.listRules(folderId: folder.id)) ?? []
            return (folder, rules)
        }) else { return }

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return }
        let batchId = UUID().uuidString
        let (matched, history) = RuleEngine.run(path: path, depth: depth, rules: rules, batchId: batchId, root: folder.path)
        for ruleName in matched {
            onRuleMatched?(ruleName, path)
        }
        if !history.isEmpty {
            db.withLock { db in
                try? db.insertHistoryEntries(history)
            }
            recordEvaluatedResultStates(history)
        }
        recordEvaluatedState(path)
    }

    private func handleSyncTargetChange(path: String) -> Bool {
        guard let match = syncRuleMatch(forPath: path, includeWatchedRoot: false) else { return false }
        guard ActionExecutor.syncDirection(match.action) == .twoWay else { return true }
        guard hasPathChangedSinceLastEvaluation(path) else { return true }

        let batchId = UUID().uuidString
        do {
            let plan = try ActionExecutor.plan(match.action, path: path, root: match.folder.path)
            guard plan.status == .wouldRun else {
                insertSyncHistory(match: match, batchId: batchId, originalPath: path, resultPath: path, status: .skipped, message: plan.description, undo: .none)
                recordEvaluatedState(path)
                return true
            }
            let applied = try ActionExecutor.execute(match.action, path: path, root: match.folder.path)
            insertSyncHistory(match: match, batchId: batchId, originalPath: path, resultPath: applied.copiedPath ?? applied.newPath, undo: applied.undo)
            if let copiedPath = applied.copiedPath { recordEvaluatedState(copiedPath) }
            recordEvaluatedState(path)
        } catch {
            insertSyncHistory(match: match, batchId: batchId, originalPath: path, resultPath: path, status: .failed, message: String(describing: error), undo: .none)
        }
        return true
    }

    private func handleDeleted(path: String) {
        guard let match = syncRuleMatch(forPath: path, includeWatchedRoot: true) else { return }
        guard ActionExecutor.syncDeletePolicy(match.action) == .moveToTrash else { return }

        do {
            let counterpart = try ActionExecutor.syncCounterpartPath(match.action, path: path, root: match.folder.path)
            guard FileManager.default.fileExists(atPath: counterpart) else { return }
            let trash = try moveToTrash(counterpart)
            insertSyncHistory(
                match: match,
                batchId: UUID().uuidString,
                originalPath: path,
                resultPath: trash,
                undo: .move(from: counterpart, to: trash)
            )
        } catch {
            insertSyncHistory(
                match: match,
                batchId: UUID().uuidString,
                originalPath: path,
                resultPath: path,
                status: .failed,
                message: String(describing: error),
                undo: .none
            )
        }
    }

    private struct SyncRuleMatch {
        let folder: WatchedFolder
        let rule: Rule
        let action: Action
    }

    private func syncRuleMatch(forPath path: String, includeWatchedRoot: Bool) -> SyncRuleMatch? {
        db.withLock { db in
            let folders = ((try? db.listFolders()) ?? []).filter(\.enabled)
            for folder in folders {
                let rules = (try? db.listRules(folderId: folder.id)) ?? []
                for rule in rules where rule.enabled {
                    for action in rule.actions where action.kind == .syncFolders {
                        guard let target = action.params[ActionParam.destination]?.stringValue else { continue }
                        if includeWatchedRoot, isPathPrefix(folder.path, of: path) {
                            return SyncRuleMatch(folder: folder, rule: rule, action: action)
                        }
                        if isPathPrefix(target, of: path) {
                            return SyncRuleMatch(folder: folder, rule: rule, action: action)
                        }
                    }
                }
            }
            return nil
        }
    }

    private func syncTargets(forWatchedFolderPath path: String) -> [String] {
        db.withLock { db in
            guard let folder = try? db.listFolders().first(where: { $0.enabled && $0.path == path }) else { return [] }
            return syncTargets(for: folder, db: db)
        }
    }

    private func syncTargets(for folder: WatchedFolder, db: Database) -> [String] {
        let rules = (try? db.listRules(folderId: folder.id)) ?? []
        return rules
            .filter(\.enabled)
            .flatMap(\.actions)
            .filter { $0.kind == .syncFolders && ActionExecutor.syncDirection($0) == .twoWay }
            .compactMap { $0.params[ActionParam.destination]?.stringValue }
    }

    private func insertSyncHistory(
        match: SyncRuleMatch,
        batchId: String,
        originalPath: String,
        resultPath: String,
        status: HistoryStatus = .applied,
        message: String? = nil,
        undo: Undo
    ) {
        let identity = FileFingerprint.identity(resultPath)
        let entry = HistoryEntry(
            batchId: batchId,
            ruleId: match.rule.id,
            ruleName: match.rule.name,
            actionKind: match.action.kind,
            originalPath: originalPath,
            resultPath: resultPath,
            undo: undo.toJSON(),
            reversible: undo.isReversible,
            status: status,
            message: message,
            resultVolumeId: identity?.volumeId,
            resultFileId: identity?.fileId
        )
        db.withLock { db in
            try? db.insertHistoryEntries([entry])
        }
    }

    private func moveToTrash(_ path: String) throws -> String {
        let trash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let target = uniqueTrashPath(dir: trash, fileName: fileName)
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }

    private func uniqueTrashPath(dir: String, fileName: String) -> String {
        let candidate = (dir as NSString).appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        let nsName = fileName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var i = 1
        while true {
            let newName = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    private func isPathPrefix(_ prefix: String, of path: String) -> Bool {
        let prefixComponents = ((prefix as NSString).standardizingPath as NSString).pathComponents
        let pathComponents = ((path as NSString).standardizingPath as NSString).pathComponents
        guard pathComponents.count >= prefixComponents.count else { return false }
        return Array(pathComponents.prefix(prefixComponents.count)) == prefixComponents
    }

    /// Whether `path` looks different from the last time the watcher fully
    /// evaluated it (same identity and fingerprint means nothing meaningful
    /// changed). Without this, an action that doesn't move the file out of
    /// scope — `copyToFolder` in particular, which has no
    /// `alreadyInDestination`-style no-op the way `moveToFolder` does —
    /// would repeat itself on every duplicate/coalesced FSEvent for the same
    /// untouched source, piling up copies indefinitely.
    ///
    /// This checks the *observed* path itself, not anything an action
    /// produced, so a path nothing has evaluated before — e.g. a file a
    /// previous rule just moved here — always proceeds; only a path whose
    /// own state was already fully evaluated gets skipped.
    private func hasPathChangedSinceLastEvaluation(_ path: String) -> Bool {
        guard let cached = db.withLock({ db in try? db.getWatchedPathState(path) }) else { return true }
        guard let currentFingerprint = FileFingerprint.current(path), cached.fingerprint == currentFingerprint else {
            return true
        }
        // Fingerprint matches — file hasn't changed. No need to check identity
        // (inode/volume) unless it happens to already be cached; rows written
        // before migration V7 have nil volumeId/fileId and would otherwise
        // trigger a spurious re-evaluation.
        guard let volumeId = cached.volumeId, let fileId = cached.fileId else { return false }
        guard let identity = FileFingerprint.identity(path) else { return true }
        return !(identity.volumeId == volumeId && identity.fileId == fileId)
    }

    private func recordEvaluatedState(_ path: String) {
        // Nothing meaningful to cache once the file's gone (e.g. it was
        // just moved away) — and caching a path's only-just-vacated state
        // would just be inert until something new shows up there anyway.
        guard FileManager.default.fileExists(atPath: path) else { return }
        let identity = FileFingerprint.identity(path)
        let state = WatchedPathState(path: path, volumeId: identity?.volumeId, fileId: identity?.fileId, fingerprint: FileFingerprint.current(path))
        db.withLock { db in try? db.upsertWatchedPathState(state) }
    }

    private func recordEvaluatedResultStates(_ history: [HistoryEntry]) {
        let paths = Set(
            history
                .filter { $0.status == .applied }
                .map(\.resultPath)
        )
        for path in paths {
            recordEvaluatedState(path)
        }
    }
}
