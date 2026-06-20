import Testing
import Foundation
@testable import ForelCore

@Suite struct ExecutionPlanPreviewTests {
    @Test func planAlreadyInDestinationShowsAsWouldSkipInPreview() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        var rule = makeRule(name: "sort pdf", conditions: [makeCondition(.extension_, .is, "pdf")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .previewed)
        let preview = plan.asPreviewResult(filesScanned: entries.count)

        let match = try #require(preview.matches.first { $0.path == existing })
        #expect(match.rules[0].actions[0].status == .wouldSkip)
        #expect(FileManager.default.fileExists(atPath: existing))
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
    }

    @Test func planDoesNotMutateFilesystem() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        _ = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .previewed)

        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("a.txt")))
    }

    @Test func planCanBePersistedAsPreviewedExecutionPlan() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        var rule = makeRule(name: "tag", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, folderId: "folder-1", status: .previewed)

        #expect(plan.status == .previewed)
        #expect(plan.folderId == "folder-1")
        #expect(plan.files.contains { $0.path == file })
    }
}
