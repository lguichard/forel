import Foundation
import ForelCore
import Combine
import AppKit

/// Central observable state for the SwiftUI app: owns the database, the
/// watcher coordinator, and the in-memory view of folders/rules. Mirrors the
/// surface of the old `useForelStore` Zustand store, but as direct Swift
@MainActor
final class AppModel: ObservableObject {
    /// Which screen the detail pane shows. Settings and History are in-app
    /// views (not separate windows) reached from the sidebar or menu bar.
    enum DetailRoute { case rules, history, settings }

    @Published var folders: [WatchedFolder] = []
    @Published var selectedFolderId: String?
    @Published var rules: [Rule] = []
    @Published var history: [HistoryEntry] = []
    @Published var paused: Bool = false
    @Published var alertTitle: String = "Error"
    @Published var errorMessage: String?
    @Published var detailRoute: DetailRoute = .rules
    @Published var appTheme: AppTheme = .system
    @Published var accentPreset: AccentPreset = .default
    @Published var showDockIcon: Bool = true
    /// Bumped whenever the accent colour changes, so views can force a full
    /// re-render with `.id(model.accentVersion)` — `ForelTheme.accent` is a
    /// plain static var, not itself observable.
    @Published var accentVersion: Int = 0
    @Published private(set) var isRunningNow = false
    @Published private(set) var runNowMessage: String?
    private var runNowMessageId: UUID?
    @Published private(set) var isPreviewing = false
    @Published var previewResult: PreviewResult?
    /// The most recently computed plan backing `previewResult` — the same
    /// `ExecutionPlan` Run Now/watcher will consume once they're wired to it.
    @Published private(set) var lastPlan: ExecutionPlan?
    /// `PlanValidator`'s read on `lastPlan` — the same validation Run Now
    /// and the watcher apply before executing.
    @Published private(set) var lastPlanValidation: PlanValidationResult?

    let db: Database
    private let coordinator: WatcherCoordinator

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.forel.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("forel.db").path

        let db = try Database(path: dbPath)
        self.db = db
        self.coordinator = WatcherCoordinator(db: db)
        // Default to paused (watching off) on a fresh install — a brand-new
        // user hasn't set up any rules yet, and starting to watch folders
        // immediately means triggering permission prompts and risking rule-less
        // surprises before they've configured anything. Once they've explicitly
        // set this either way, that choice persists.
        let storedPaused = try? db.getSetting("paused")
        self.paused = storedPaused.map { $0 == "1" } ?? true

        let storedAccent = (try? db.getSetting("accent_color")) ?? nil
        let preset = storedAccent.flatMap(AccentPreset.init(rawValue:)) ?? .default
        self.accentPreset = preset
        ForelTheme.apply(preset)

        let storedTheme = (try? db.getSetting("theme")) ?? nil
        self.appTheme = storedTheme.flatMap(AppTheme.init(rawValue:)) ?? .system

        let storedShowDockIcon = try? db.getSetting("show_dock_icon")
        self.showDockIcon = storedShowDockIcon.map { $0 == "1" } ?? true

        reloadFolders()
        startWatchingEnabledFolders()
    }

    func applyDockIconPreference(keepingWindowsVisible: Bool = false) {
        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible && !(window is NSPanel)
        }
        let keyWindow = NSApp.keyWindow

        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)

        guard keepingWindowsVisible else { return }

        let windowsToRestore = visibleWindows.isEmpty
            ? NSApp.windows.filter { !($0 is NSPanel) }
            : visibleWindows

        let restoreWindows = {
            for window in windowsToRestore {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        restoreWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for window in windowsToRestore {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func setShowDockIcon(_ enabled: Bool) {
        showDockIcon = enabled
        try? db.setSetting("show_dock_icon", enabled ? "1" : "0")
        applyDockIconPreference(keepingWindowsVisible: true)
    }

    func setAppTheme(_ theme: AppTheme) {
        appTheme = theme
        try? db.setSetting("theme", theme.rawValue)
    }

    func setAccentPreset(_ preset: AccentPreset) {
        accentPreset = preset
        ForelTheme.apply(preset)
        accentVersion += 1
        try? db.setSetting("accent_color", preset.rawValue)
    }

    func reloadFolders() {
        folders = (try? db.listFolders()) ?? []
        if let selectedFolderId, !folders.contains(where: { $0.id == selectedFolderId }) {
            self.selectedFolderId = folders.first?.id
        }
        if selectedFolderId == nil {
            selectedFolderId = folders.first?.id
        }
        reloadRules()
    }

    func reloadRules() {
        guard let folderId = selectedFolderId else { rules = []; return }
        rules = (try? db.listRules(folderId: folderId)) ?? []
    }

    func reloadHistory() {
        history = (try? db.listHistory()) ?? []
    }

    private func startWatchingEnabledFolders() {
        guard !paused else { return }
        let coordinator = self.coordinator
        for folder in (try? db.listFolders()) ?? [] where folder.enabled {
            coordinator.add(folder.path)
            // Catches up on anything that changed while Forel wasn't
            // running (missed FSEvents), off the main thread so launch
            // isn't blocked scanning large folders.
            Task {
                await Task.detached(priority: .utility) {
                    coordinator.runStartupScan(folder: folder)
                }.value
                reloadHistory()
            }
        }
    }

    func addFolder(path: String) {
        let normalizedPath = (path as NSString).standardizingPath
        if let existingFolder = folders.first(where: { ($0.path as NSString).standardizingPath == normalizedPath }) {
            selectedFolderId = existingFolder.id
            detailRoute = .rules
            reloadRules()
            showNotice(
                title: "Folder already watched",
                message: "\"\((existingFolder.path as NSString).lastPathComponent)\" is already in your watched folders."
            )
            return
        }

        let folder = WatchedFolder(path: normalizedPath)
        do {
            try db.insertFolder(folder)
            if !paused { coordinator.add(normalizedPath) }
            reloadFolders()
        } catch {
            showError(error)
        }
    }

    func removeFolder(_ folder: WatchedFolder) {
        coordinator.remove(folder.path)
        try? db.deleteFolder(folder.id)
        reloadFolders()
    }

    func toggleFolder(_ folder: WatchedFolder, enabled: Bool) {
        try? db.toggleFolder(folder.id, enabled: enabled)
        if enabled, !paused {
            coordinator.add(folder.path)
        } else {
            coordinator.remove(folder.path)
        }
        reloadFolders()
    }

    func reorderFolders(_ folderIds: [String]) {
        try? db.reorderFolders(folderIds)
        reloadFolders()
    }

    func saveRule(_ rule: Rule) {
        do {
            if rules.contains(where: { $0.id == rule.id }) {
                try db.updateRule(rule)
            } else {
                try db.insertRule(rule)
            }
            reloadRules()
        } catch {
            showError(error)
        }
    }

    func deleteRule(_ rule: Rule) {
        try? db.deleteRule(rule.id)
        reloadRules()
    }

    func toggleRule(_ rule: Rule, enabled: Bool) {
        try? db.toggleRule(rule.id, enabled: enabled)
        reloadRules()
    }

    func reorderRules(_ ruleIds: [String]) {
        guard let folderId = selectedFolderId else { return }
        try? db.reorderRules(folderId: folderId, ruleIds: ruleIds)
        reloadRules()
    }

    /// Runs all enabled rules in the selected folder against every file
    /// currently in it (a manual "Run Now"), bounded by each rule's scope.
    func runNow() {
        guard !isRunningNow else { return }
        guard let folder = folders.first(where: { $0.id == selectedFolderId }) else { return }
        let folderRules = rules.filter(\.enabled)
        guard !folderRules.isEmpty else {
            showRunNowMessage("Run complete — no enabled rules")
            return
        }
        isRunningNow = true
        Task {
            defer { isRunningNow = false }
            let db = self.db
            let outcome: (plan: ExecutionPlan, validation: PlanValidationResult, result: PlanExecutionResult) = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                let entries = RuleEngine.walkEntries(root: folder.path, maxDepth: maxDepth)
                let scanBatchId = UUID().uuidString
                let scanEvents = entries.map { entry in
                    FilesystemEvent(batchId: scanBatchId, source: .scan, kind: .discovered, path: entry.path)
                }
                try? db.insertFilesystemEvents(scanEvents)

                // Run Now consumes the same plan Dry Run would have shown for
                // these exact files/rules — it never matches/plans actions
                // on its own.
                let plan = RulePlanner.plan(entries: entries, rules: folderRules, root: folder.path, folderId: folder.id, status: .ready)
                // Same validator Dry Run shows conflicts/warnings from, run
                // here too so Run Now never executes a batch it disagrees with.
                return (plan: plan, validation: PlanValidator.validate(plan), result: PlanExecutor.execute(plan, batchId: UUID().uuidString))
            }.value
            lastPlan = outcome.plan
            lastPlanValidation = outcome.validation
            let result = outcome.result

            if !result.history.isEmpty {
                try? db.insertHistoryEntries(result.history)
            }
            if !result.events.isEmpty {
                try? db.insertFilesystemEvents(result.events)
            }
            for state in result.fileStateUpserts { try? db.upsertFileState(state) }
            for path in result.fileStateDeletes { try? db.deleteFileState(path) }

            reloadHistory()
            let appliedCount = result.history.filter { $0.status == .applied }.count
            let otherCount = result.history.count - appliedCount
            let message: String
            if result.history.isEmpty {
                message = "Run complete — no matching files"
            } else if otherCount == 0 {
                message = "Run complete — \(appliedCount) action\(appliedCount == 1 ? "" : "s") applied"
            } else {
                message = "Run complete — \(appliedCount) applied, \(otherCount) skipped or blocked"
            }
            showRunNowMessage(message)
        }
    }

    /// Shows a transient confirmation after a manual run, auto-dismissed a
    /// few seconds later — unless a newer run has already replaced it.
    private func showRunNowMessage(_ message: String) {
        let id = UUID()
        runNowMessageId = id
        runNowMessage = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if runNowMessageId == id { runNowMessage = nil }
        }
    }

    /// Runs Dry Run off the main thread — scanning every file in a large
    /// folder can take a while, so `isPreviewing` drives a loading state on
    /// the button instead of freezing the UI. Sets `previewResult` when done,
    /// which the view presents as a sheet.
    func preview() {
        guard !isPreviewing else { return }
        guard let folder = folders.first(where: { $0.id == selectedFolderId }) else {
            lastPlan = nil
            lastPlanValidation = nil
            previewResult = PreviewResult(filesScanned: 0, matches: [])
            return
        }
        let folderRules = rules.filter(\.enabled)
        guard !folderRules.isEmpty else {
            lastPlan = nil
            lastPlanValidation = nil
            previewResult = PreviewResult(filesScanned: 0, matches: [])
            return
        }
        isPreviewing = true
        Task {
            defer { isPreviewing = false }
            let outcome = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                let entries = RuleEngine.walkEntries(root: folder.path, maxDepth: maxDepth)
                let plan = RulePlanner.plan(entries: entries, rules: folderRules, root: folder.path, folderId: folder.id, status: .previewed)
                return (plan: plan, validation: PlanValidator.validate(plan), filesScanned: entries.count)
            }.value
            lastPlan = outcome.plan
            lastPlanValidation = outcome.validation
            previewResult = outcome.plan.asPreviewResult(filesScanned: outcome.filesScanned)
        }
    }

    /// Reverses `entry` only if `UndoPlanner` finds it safe — never a silent
    /// best-effort rollback on a file that no longer matches what Forel
    /// originally changed.
    func undo(_ entry: HistoryEntry) {
        guard entry.status == .applied else { return }
        let recentEvents = (try? db.listFilesystemEvents(path: entry.resultPath)) ?? []
        let result = UndoPlanner.apply(entry, recentEvents: recentEvents)
        switch result.outcome {
        case .applied:
            try? db.insertHistoryEntries(result.history)
            try? db.insertFilesystemEvents(result.events)
            try? db.markHistoryUndone(entry.id)
            reloadHistory()
        case .blocked(let reason), .needsConfirmation(let reason):
            showNotice(title: "Can't undo this action", message: reason)
        }
    }

    /// Reverts every still-applied, reversible entry in a batch. Entries are
    /// undone in reverse application order so chained actions on the same file
    /// (e.g. tag then rename) revert correctly. Each entry is still checked
    /// individually by `UndoPlanner` — one unsafe entry doesn't block the rest.
    func undoBatch(_ batchId: String) {
        let entries = (try? db.listHistoryBatch(batchId)) ?? []
        let reversible = entries.filter { $0.status == .applied && $0.reversible }
        let recentEvents = reversible.flatMap { (try? db.listFilesystemEvents(path: $0.resultPath)) ?? [] }
        let results = UndoPlanner.applyBatch(reversible, recentEvents: recentEvents)

        var failures: [String] = []
        for result in results {
            guard let entry = reversible.first(where: { $0.id == result.entryId }) else { continue }
            switch result.outcome {
            case .applied:
                try? db.insertHistoryEntries(result.history)
                try? db.insertFilesystemEvents(result.events)
                try? db.markHistoryUndone(entry.id)
            case .blocked(let reason), .needsConfirmation(let reason):
                failures.append("\((entry.originalPath as NSString).lastPathComponent): \(reason)")
            }
        }

        if !failures.isEmpty {
            showError("Some actions could not be undone:\n" + failures.joined(separator: "\n"))
        }
        reloadHistory()
    }

    func togglePaused() {
        paused.toggle()
        try? db.setSetting("paused", paused ? "1" : "0")
        let allFolders = (try? db.listFolders()) ?? []
        for folder in allFolders {
            if paused {
                coordinator.remove(folder.path)
            } else if folder.enabled {
                coordinator.add(folder.path)
            }
        }
    }

    private func showNotice(title: String, message: String) {
        alertTitle = title
        errorMessage = message
    }

    private func showError(_ error: any Error) {
        showError("\(error)")
    }

    private func showError(_ message: String) {
        alertTitle = "Error"
        errorMessage = message
    }
}
