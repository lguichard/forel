import Foundation

/// Converts a core `ExecutionPlan` into the legacy preview view-model the
/// Dry Run sheet renders, so the UI keeps working unchanged while the plan
/// becomes the single source of truth behind it.
extension PlanActionStatus {
    var asDryRunStatus: DryRunStatus {
        switch self {
        case .wouldRun: return .wouldRun
        case .wouldSkip: return .wouldSkip
        case .blocked: return .blockedByConflict
        case .needsConfirmation: return .needsConfirmation
        }
    }
}

extension PlannedAction {
    public func asActionPreview() -> ActionPreview {
        ActionPreview(
            kind: actionKind,
            description: description,
            sourcePath: sourcePath,
            targetPath: targetPath,
            status: status.asDryRunStatus
        )
    }
}

extension PlannedRule {
    public func asRulePreview() -> RulePreview {
        RulePreview(ruleId: ruleId, ruleName: ruleName, conditions: conditions, actions: actions.map { $0.asActionPreview() })
    }
}

extension PlannedFile {
    public func asFilePreview() -> FilePreview {
        FilePreview(path: path, name: (path as NSString).lastPathComponent, rules: rules.map { $0.asRulePreview() })
    }
}

extension ExecutionPlan {
    public func asPreviewResult(filesScanned: Int) -> PreviewResult {
        PreviewResult(filesScanned: filesScanned, matches: files.map { $0.asFilePreview() })
    }
}
