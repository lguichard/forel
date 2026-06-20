import Foundation

/// Everything a completed Run Now/watcher execution produced, ready to
/// persist as a unit: history, the journal entries for Forel's own changes,
/// and the `file_state` updates that follow.
public struct PlanExecutionResult: Sendable {
    public let history: [HistoryEntry]
    public let events: [FilesystemEvent]
    public let fileStateUpserts: [FileState]
    public let fileStateDeletes: [String]
}

/// Executes exactly the `wouldRun` actions of an `ExecutionPlan`, the same
/// plan Dry Run showed. Never executes a `wouldSkip` or unresolved
/// `blocked`/`needsConfirmation` action.
public enum PlanExecutor {
    public static func execute(_ plan: ExecutionPlan, batchId: String = UUID().uuidString) -> PlanExecutionResult {
        let collidingDestinations = PlanValidator.collidingDestinations(plan)
        var history: [HistoryEntry] = []
        for file in plan.files {
            history.append(contentsOf: executeFile(file, batchId: batchId, planId: plan.id, collidingDestinations: collidingDestinations))
        }
        let events = FilesystemEvent.forelActionEvents(batchId: batchId, history: history)
        let stateUpdates = FileState.updatesFromHistory(history)
        return PlanExecutionResult(
            history: history,
            events: events,
            fileStateUpserts: stateUpdates.upserts,
            fileStateDeletes: stateUpdates.deletes
        )
    }

    private static func executeFile(_ file: PlannedFile, batchId: String, planId: String, collidingDestinations: Set<String>) -> [HistoryEntry] {
        guard let staleReason = PlanStaleness.reason(for: file) else {
            return file.rules.flatMap { rule in
                rule.actions.compactMap { action in
                    executeAction(action, batchId: batchId, planId: planId, collidingDestinations: collidingDestinations)
                }
            }
        }
        // The file changed or disappeared since it was planned: refuse every
        // action this plan would otherwise have run, rather than risk acting
        // on a file that no longer matches what Dry Run showed.
        return file.rules.flatMap { rule in
            rule.actions.filter { $0.status == .wouldRun }.map { action in
                HistoryEntry(
                    batchId: batchId,
                    ruleId: action.ruleId,
                    ruleName: action.ruleName,
                    actionKind: action.actionKind,
                    originalPath: action.sourcePath,
                    resultPath: action.sourcePath,
                    undo: Undo.none.toJSON(),
                    reversible: false,
                    status: .failed,
                    message: staleReason,
                    planId: planId
                )
            }
        }
    }

    private static func executeAction(_ planned: PlannedAction, batchId: String, planId: String, collidingDestinations: Set<String>) -> HistoryEntry? {
        if let target = planned.targetPath, planned.status == .wouldRun, collidingDestinations.contains(target) {
            return HistoryEntry(
                batchId: batchId,
                ruleId: planned.ruleId,
                ruleName: planned.ruleName,
                actionKind: planned.actionKind,
                originalPath: planned.sourcePath,
                resultPath: planned.sourcePath,
                undo: Undo.none.toJSON(),
                reversible: false,
                status: .failed,
                message: "Another file in this batch would also write to \(target); refusing both.",
                planId: planId
            )
        }

        switch planned.status {
        case .wouldSkip:
            return nil
        case .blocked, .needsConfirmation:
            return HistoryEntry(
                batchId: batchId,
                ruleId: planned.ruleId,
                ruleName: planned.ruleName,
                actionKind: planned.actionKind,
                originalPath: planned.sourcePath,
                resultPath: planned.sourcePath,
                undo: Undo.none.toJSON(),
                reversible: false,
                status: planned.status == .needsConfirmation ? .needsConfirmation : .failed,
                message: planned.conflictReason ?? "Blocked by plan validation",
                planId: planId
            )
        case .wouldRun:
            let sourceIdentity = FileFingerprint.identity(planned.sourcePath)
            let sourceFingerprint = FileFingerprint.current(planned.sourcePath)
            do {
                let applied = try ActionExecutor.execute(planned.action, path: planned.sourcePath)
                let resultPath: String
                switch applied.undo {
                case .copy(let copy): resultPath = copy
                default: resultPath = applied.newPath
                }
                let resultIdentity = FileFingerprint.identity(resultPath)
                return HistoryEntry(
                    batchId: batchId,
                    ruleId: planned.ruleId,
                    ruleName: planned.ruleName,
                    actionKind: planned.actionKind,
                    originalPath: planned.sourcePath,
                    resultPath: resultPath,
                    undo: applied.undo.toJSON(),
                    reversible: applied.undo.isReversible,
                    sourceVolumeId: sourceIdentity?.volumeId,
                    sourceFileId: sourceIdentity?.fileId,
                    sourceFingerprint: sourceFingerprint,
                    resultVolumeId: resultIdentity?.volumeId,
                    resultFileId: resultIdentity?.fileId,
                    resultFingerprint: FileFingerprint.current(resultPath),
                    planId: planId
                )
            } catch {
                return HistoryEntry(
                    batchId: batchId,
                    ruleId: planned.ruleId,
                    ruleName: planned.ruleName,
                    actionKind: planned.actionKind,
                    originalPath: planned.sourcePath,
                    resultPath: planned.sourcePath,
                    undo: Undo.none.toJSON(),
                    reversible: false,
                    status: .failed,
                    message: String(describing: error),
                    planId: planId
                )
            }
        }
    }

}
