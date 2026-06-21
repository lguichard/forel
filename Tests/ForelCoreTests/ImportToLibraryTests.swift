import Testing
import Foundation
@testable import ForelCore

/// Covers the format/parameter logic of the Import to Library action that can be
/// exercised without a real Music/Photos/TV library. The actual import paths
/// drive system apps over AppleScript/PhotoKit and aren't unit-testable here;
/// these tests pin down the parts that gate them — format compatibility,
/// conflict-resolution defaults, and parameter validation — so the three
/// execution paths (Dry Run, Run Now, watcher) stay consistent.
@Suite struct ImportToLibraryTests {
    // MARK: - Format compatibility

    @Test func canImportToLibraryAcceptsOnlyCompatibleFormats() {
        let dir = TempDir()
        let audio = dir.file("song.mp3", contents: "x")
        let image = dir.file("photo.png", contents: "x")
        let movie = dir.file("clip.mov", contents: "x")
        let text = dir.file("notes.txt", contents: "x")

        // Music accepts audio only.
        #expect(ActionExecutor.canImportToLibrary(audio, libraryType: .music))
        #expect(!ActionExecutor.canImportToLibrary(image, libraryType: .music))
        #expect(!ActionExecutor.canImportToLibrary(text, libraryType: .music))

        // Photos accepts images and movies.
        #expect(ActionExecutor.canImportToLibrary(image, libraryType: .photos))
        #expect(ActionExecutor.canImportToLibrary(movie, libraryType: .photos))
        #expect(!ActionExecutor.canImportToLibrary(audio, libraryType: .photos))
        #expect(!ActionExecutor.canImportToLibrary(text, libraryType: .photos))

        // TV accepts movies only.
        #expect(ActionExecutor.canImportToLibrary(movie, libraryType: .tv))
        #expect(!ActionExecutor.canImportToLibrary(audio, libraryType: .tv))
        #expect(!ActionExecutor.canImportToLibrary(image, libraryType: .tv))
    }

    @Test func formatDescriptionIsNonEmptyForEveryLibrary() {
        for type in LibraryType.allCases {
            #expect(!ActionExecutor.formatDescription(for: type).isEmpty)
        }
    }

    // MARK: - Conflict resolution defaults

    @Test func conflictResolutionUsesProvidedDefaultWhenParamMissing() {
        let noParam = makeAction(.importToLibrary, .object(["library_type": .string("music")]))
        #expect(ActionExecutor.conflictResolution(noParam, default: .skip) == .skip)

        let explicit = makeAction(.importToLibrary, .object([ActionParam.onConflict: .string("replace")]))
        #expect(ActionExecutor.conflictResolution(explicit, default: .skip) == .replace)

        // An unrecognized value falls back to the supplied default rather than .rename.
        let garbage = makeAction(.importToLibrary, .object([ActionParam.onConflict: .string("nonsense")]))
        #expect(ActionExecutor.conflictResolution(garbage, default: .skip) == .skip)
    }

    // MARK: - Parameter validation (safe paths that never touch a real library)

    @Test func executeRejectsIncompatibleFormatBeforeTouchingLibrary() {
        let dir = TempDir()
        let text = dir.file("notes.txt", contents: "x")
        let action = makeAction(.importToLibrary, .object(["library_type": .string("music")]))
        #expect(throws: (any Error).self) {
            try ActionExecutor.execute(action, path: text)
        }
    }

    @Test func planRejectsIncompatibleFormat() {
        let dir = TempDir()
        let text = dir.file("notes.txt", contents: "x")
        let action = makeAction(.importToLibrary, .object(["library_type": .string("tv")]))
        #expect(throws: (any Error).self) {
            try ActionExecutor.plan(action, path: text)
        }
    }

    @Test func invalidLibraryTypeThrows() {
        let dir = TempDir()
        let audio = dir.file("song.mp3", contents: "x")
        let action = makeAction(.importToLibrary, .object(["library_type": .string("nonsense")]))
        #expect(throws: (any Error).self) {
            try ActionExecutor.plan(action, path: audio)
        }
        #expect(throws: (any Error).self) {
            try ActionExecutor.execute(action, path: audio)
        }
    }

    // MARK: - Persistence round-trip

    @Test func importToLibraryActionSurvivesDatabaseRoundTrip() throws {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "import audio")
        try db.insertRule(rule)

        let params: JSONValue = .object([
            ActionParam.libraryType: .string(LibraryType.music.rawValue),
            ActionParam.targetPlaylist: .string("Favorites"),
            ActionParam.onConflict: .string(MoveConflictResolution.replace.rawValue),
        ])
        rule.actions = [makeAction(.importToLibrary, params, position: 0, ruleId: rule.id)]
        try db.updateRule(rule)

        let loaded = try db.listRules(folderId: folder.id)[0]
        #expect(loaded.actions.count == 1)
        #expect(loaded.actions[0].kind == .importToLibrary)
        #expect(loaded.actions[0].params == params)
    }
}
