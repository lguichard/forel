import Foundation

/// How the validator should treat a destination that already exists.
/// `blockOnExistingDestination` (the default) never lets Forel write over an
/// existing file or silently rename around it; `confirmOnExistingDestination`
/// lets the caller ask the user instead of refusing outright.
public enum ConflictPolicy: Sendable {
    case blockOnExistingDestination
    case confirmOnExistingDestination
}

public enum PlanValidationStatus: String, Equatable, Sendable {
    case valid
    case validWithWarnings = "valid_with_warnings"
    case blocked
    case needsConfirmation = "needs_confirmation"
}

public struct PlanValidationResult: Equatable, Sendable {
    public let status: PlanValidationStatus
    public let warnings: [PlanWarning]
    public let conflicts: [PlanConflict]

    public init(status: PlanValidationStatus, warnings: [PlanWarning] = [], conflicts: [PlanConflict] = []) {
        self.status = status
        self.warnings = warnings
        self.conflicts = conflicts
    }
}

/// Validates an entire `ExecutionPlan` as a batch — collisions and recursion
/// no single file's plan can see on its own. Dry Run, Run Now and the
/// watcher call this with the same plan and get the same decision.
public enum PlanValidator {
    public static func validate(_ plan: ExecutionPlan, policy: ConflictPolicy = .blockOnExistingDestination) -> PlanValidationResult {
        var conflicts: [PlanConflict] = []
        let warnings: [PlanWarning] = []
        var needsConfirmation = false

        var writesByDestination: [String: Set<String>] = [:]

        for file in plan.files {
            if let staleness = PlanStaleness.reason(for: file) {
                conflicts.append(PlanConflict(path: file.path, message: staleness))
            }

            for rule in file.rules {
                for action in rule.actions {
                    switch action.status {
                    case .wouldRun:
                        if let target = action.targetPath, isMoveOrCopy(action.actionKind) {
                            writesByDestination[target, default: []].insert(file.path)
                            if action.actionKind == .moveToFolder, isSelfOrDescendantMove(source: action.sourcePath, targetPath: target) {
                                conflicts.append(
                                    PlanConflict(
                                        path: file.path,
                                        message: "Cannot move \"\((action.sourcePath as NSString).lastPathComponent)\" into itself or one of its own subfolders."
                                    )
                                )
                            }
                        }
                    case .needsConfirmation:
                        needsConfirmation = true
                    case .blocked:
                        if action.conflictReason == "destinationExists" {
                            switch policy {
                            case .blockOnExistingDestination:
                                conflicts.append(
                                    PlanConflict(path: file.path, message: "Destination already exists: \(action.targetPath ?? action.sourcePath)")
                                )
                            case .confirmOnExistingDestination:
                                needsConfirmation = true
                            }
                        }
                    case .wouldSkip:
                        continue
                    }
                }
            }
        }

        // Two different source files planned to land on the same destination
        // can never both be right — this is always a hard conflict,
        // regardless of policy.
        for (destination, sources) in writesByDestination where sources.count > 1 {
            conflicts.append(PlanConflict(path: destination, message: "Multiple files would be written to \(destination)."))
        }

        let status: PlanValidationStatus
        if !conflicts.isEmpty {
            status = .blocked
        } else if needsConfirmation {
            status = .needsConfirmation
        } else if !warnings.isEmpty {
            status = .validWithWarnings
        } else {
            status = .valid
        }

        return PlanValidationResult(status: status, warnings: warnings, conflicts: conflicts)
    }

    /// Destinations more than one source file's plan would write to — the
    /// one collision a single file's plan can never see on its own.
    /// `PlanExecutor` uses this to refuse every colliding write rather than
    /// run whichever one happens to come first.
    public static func collidingDestinations(_ plan: ExecutionPlan) -> Set<String> {
        var byDestination: [String: Set<String>] = [:]
        for file in plan.files {
            for rule in file.rules {
                for action in rule.actions where action.status == .wouldRun {
                    guard let target = action.targetPath, isMoveOrCopy(action.actionKind) else { continue }
                    byDestination[target, default: []].insert(file.path)
                }
            }
        }
        return Set(byDestination.filter { $0.value.count > 1 }.keys)
    }

    private static func isMoveOrCopy(_ kind: ActionKind) -> Bool {
        kind == .moveToFolder || kind == .copyToFolder
    }

    /// A directory can't be moved into itself or into one of its own
    /// descendants — `targetPath` is `destinationDir/basename(source)`, so
    /// the directory actually being written to is its parent.
    private static func isSelfOrDescendantMove(source: String, targetPath: String) -> Bool {
        let destinationDir = (targetPath as NSString).deletingLastPathComponent
        let normalizedSource = (source as NSString).standardizingPath
        let normalizedDestDir = (destinationDir as NSString).standardizingPath
        if normalizedSource == normalizedDestDir { return true }

        let sourceComponents = (normalizedSource as NSString).pathComponents
        let destComponents = (normalizedDestDir as NSString).pathComponents
        guard destComponents.count >= sourceComponents.count else { return false }
        return Array(destComponents.prefix(sourceComponents.count)) == sourceComponents
    }

}
