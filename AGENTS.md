# Forel - AI & Agent Guidelines

> Source of truth for AI coding agents working on the Swift app in this repository.

## What Forel is

Forel is a native macOS file-automation app. It watches folders and runs user-defined rules on files locally. The active app is the Swift package at the repository root.

## Stack

| Layer | Technology |
|---|---|
| App shell | SwiftUI / AppKit |
| Backend | Swift 6 |
| Core persistence | SQLite via the in-house `Database` wrapper |
| File watching | `FileWatcher` / FSEvents on macOS |
| Updates | GitHub Releases check (`UpdaterManager`) |
| Build | Swift Package Manager |

## Repository layout

```text
forel/
├── Package.swift
├── Sources/
│   ├── ForelApp/
│   └── ForelCore/
├── Tests/
└── README.md
```

## Working rules

- Use `swift build` and `swift test` from the repository root.
- When changing Swift code, keep edits aligned with the existing package structure and avoid unnecessary refactors.
- Use `apply_patch` for manual file edits.
- Do not revert user changes you did not make.
- Avoid destructive commands unless explicitly requested.

## App structure

- `Sources/ForelApp` contains the SwiftUI app, windows, views, and menu bar code.
- `Sources/ForelCore` contains models, persistence, watcher, and rule engine logic.
- `Tests/ForelCoreTests` contains the core unit tests. Add or update tests with behavior changes.

## Persistence and rules

- Rules, conditions, actions, and history are stored in SQLite.
- The rule engine lives in `Sources/ForelCore/Engine`.
- UI changes that affect persistence should be backed by tests in `Tests/ForelCoreTests`.
- Rule behavior changes must be checked across all three execution paths:
  Dry Run preview, manual Run Now, and automatic watcher execution. Scope,
  recursion depth, matching, and action-chain changes should include tests or
  explicit verification that these paths stay consistent.

## Build and test commands

```bash
swift build
swift test
swift run ForelApp
```

## Changelog

- New entries always go under `## [Unreleased]` at the top of `CHANGELOG.md`, never directly under a version header. A version header is only created by renaming `[Unreleased]` when actually cutting that release.
- Entries must be concise, precise, and user-facing: state what changed and the user-visible effect, no filler, no internal implementation detail (no file/function names, no "we").

## Notes for contributors

- Keep the codebase macOS-only.
- Prefer the existing Swift patterns in the repo over introducing new abstractions.
- When a UI change affects saved rules or execution behavior, verify the database round-trip and execution path together.
