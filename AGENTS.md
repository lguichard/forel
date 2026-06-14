# Forel — AI & Agent Guidelines

> **Source of truth for all AI coding agents** (Claude Code, Cursor, Copilot, etc.).
> `CLAUDE.md` is a symlink to this file — edit only `AGENTS.md`.

---

## What Forel is

Forel is an **open-source macOS file-automation app** (think Hazel). It watches folders and runs user-defined rules (conditions → actions) on new/changed files. It lives in the system tray and applies rules silently in the background.

**Status: alpha.** Core plumbing works; many planned features are not yet implemented.

---

## Stack

| Layer | Technology |
|---|---|
| App shell | Wails 3 (v3 alpha) |
| Backend | Go (1.24+) |
| Frontend | React 19 + TypeScript |
| State (UI) | Zustand 5 |
| Persistence | SQLite via `modernc.org/sqlite` (pure-Go, no CGO) |
| File watching | `fsnotify` (FSEvents/kqueue on macOS) |
| macOS tags | `github.com/pkg/xattr` + `howett.net/plist` |
| Icons | `lucide-react` |
| Build | Wails 3 + Vite 7 + `pnpm` (frontend) |

---

## The IPC boundary — the most important constraint

Wails enforces a **hard process boundary** between the React frontend (WebView) and the Go backend. They communicate through **bound service methods**: every exported method on the `App` service in `app.go` is exposed to the frontend as a typed, auto-generated TypeScript function.

```
React (WebView)                          Go (native process)
──────────────────                       ────────────────────────────────
import { GetRules } from                 func (a *App) GetRules(folderID string)
  "bindings/forel/app"                       ([]rules.Rule, error)
GetRules(folderId)            →           ↑
        ↑                                 |
        └──────────── JSON response ──────┘
```

**Every frontend feature that reads or mutates app state requires a matching method on the `App` service.** There is no shared memory, no filesystem shortcut, no hidden channel. A returned `error` becomes a rejected JS promise.

When adding a feature, ask yourself: _"Does the frontend need data from the OS/DB, or does it need to trigger a side effect?"_ If yes → you need a bound method.

### Adding a bound method — the full checklist

1. **`app.go`** — add an exported method to `*App`.
   - Use `a.store` for DB access, `a.watcher` for watch commands, `a.app` for runtime (dialogs, etc.).
   - Return `(T, error)` (or just `error`). Errors surface as JS promise rejections.
   - Call `a.rebuildTray()` at the end if the change is visible in the tray.

2. **`frontend/bindings/`** — regenerate bindings so the frontend can call the method:
   ```bash
   wails3 generate bindings -ts -d frontend/bindings
   ```
   `wails3 dev` / `wails3 task build` also regenerate them automatically.

3. **`frontend/src/store/index.ts`** — add a Zustand action that imports and calls the
   generated function from `../../bindings/forel/app`. Components never import bindings
   directly except self-contained sub-components (e.g. the folder picker, tag picker).

4. **`frontend/src/types/index.ts`** — `types/index.ts` stays the UI source of truth.
   The generated bindings use enum types; the store casts at the boundary
   (`as unknown as <type>`) so the rest of the UI keeps using `../types`.

---

## Repository layout

```
forel/
├── main.go                       App bootstrap: DB open, watcher start, window, tray, run loop
├── app.go                        App service — every exported method is an IPC-callable function
├── go.mod / go.sum
├── Taskfile.yml                  Wails task runner entry (build / dev / package)
├── build/                        Wails build assets (config.yml, darwin/Info.plist, icons)
├── internal/
│   ├── db/db.go                  SQLite schema + all query helpers (Store type)
│   ├── tray/                     System tray controller + icon compositing
│   │   ├── tray.go               Dynamic menu rebuild + event handlers
│   │   └── icon.go               Trim/recenter the menu-bar icon
│   ├── watcher/watcher.go        fsnotify loop + Add/Remove command channel
│   └── rules/
│       ├── model.go              Rule/Condition/Action types (JSON tags ↔ DB strings)
│       ├── condition.go          Condition evaluation logic
│       ├── action.go             Action execution + macOS Finder tags/colors
│       ├── engine.go             Applies rules to a file path; preview types
│       └── fileinfo_darwin.go    macOS file birth-time helper
│
└── frontend/                     React frontend (Vite + pnpm)
    ├── index.html
    ├── package.json              pnpm only; depends on @wailsio/runtime
    ├── vite.config.ts            dev server on port 9245 (matches Wails)
    ├── bindings/                 GENERATED Go↔TS bindings (committed)
    └── src/
        ├── App.tsx               Root: layout, sidebar, rule list
        ├── App.css               All styles (single file, no CSS modules)
        ├── main.tsx              React entry point
        ├── components/
        │   ├── RuleEditor.tsx    Modal: edit conditions + actions for a rule
        │   ├── RuleList.tsx      Right panel: list rules for selected folder
        │   └── Sidebar.tsx       Left panel: watched folders
        ├── store/
        │   └── index.ts          Zustand store — all binding calls live here
        └── types/
            └── index.ts          Shared TS types + UI label maps
```

---

## Dev commands

```bash
# Run app in dev mode (hot-reload frontend, Go rebuilds on change)
wails3 dev            # or: wails3 task dev

# Build the app binary (frontend + bindings + go build → bin/Forel)
wails3 task build

# Package a macOS .app bundle
wails3 task package

# Regenerate the Go↔TS bindings after changing app.go
wails3 generate bindings -ts -d frontend/bindings

# Type-check / build frontend only (from frontend/)
pnpm build           # tsc + vite build

# Run the Go test suites
go test ./internal/...
```

> `wails3` lives in `$(go env GOPATH)/bin` — ensure it is on your `PATH`.
> `pnpm` is required for the frontend (`npm`/`yarn` are not used). Run `pnpm` from `frontend/`.

---

## Build & lint policy

**Every change must build cleanly and pass `go vet` and `go test`.**

```bash
go build ./...        # must succeed (ld "built for newer macOS" warnings are harmless)
go vet ./...          # must be clean
go test ./internal/...# must pass
gofmt -l .            # must print nothing (everything formatted)
```

- No unused imports, variables, or dead helpers — `go vet`/compiler will flag them; fix the root cause, don't silence it.
- Don't add abstractions "for later."
- The frontend must pass `pnpm build` (strict `tsc`, no `any`).

---

## Data model

Rules are stored in SQLite at `~/Library/Application Support/com.forel.app/forel.db`.

```
watched_folders (id, path, enabled, created_at)
    └── rules (id, folder_id, name, enabled, condition_match, priority, created_at)
            ├── conditions (id, rule_id, kind, operator, value)
            └── actions    (id, rule_id, kind, params JSON, position)
```

`params` is a freeform JSON object (`map[string]any` in Go). Each action kind documents its expected keys in `action.go`.

---

## How to add a new Action type

Actions are the most common extension point. Follow every step — skipping one silently breaks the feature.

### 1. Go model (`internal/rules/model.go`)

Add a typed-string constant to the `ActionKind` block. The string value is what's stored in
SQLite and consumed by the frontend:
```go
const ActYourNewAction ActionKind = "your_new_action"
```

### 2. Go execution (`internal/rules/action.go`)

Add a `case` to both `Execute()` and `Preview()`:
```go
case ActYourNewAction:
    param := paramString(action.Params, "my_param")
    if param == "" {
        return fmt.Errorf("YourNewAction requires 'my_param'")
    }
    // … do the thing …
```
(Use `paramString` / `paramStrings` helpers to read params. No DB converter step is needed —
the kind round-trips as its raw string.)

### 3. TypeScript type (`frontend/src/types/index.ts`)

```typescript
export type ActionKind =
  | "your_new_action"   // ← add this
  | /* …existing… */;

export const ACTION_KIND_LABELS: Record<ActionKind, string> = {
  your_new_action: "Human readable label",
  // …
};
```

### 4. Frontend UI (`frontend/src/components/RuleEditor.tsx`)

Add a `needsX` boolean in `ActionRow` and render the relevant input(s).

### 5. Regenerate bindings

`wails3 generate bindings -ts -d frontend/bindings` (or just run `wails3 dev`).

---

## How to add a new Condition type

Same layered pattern as actions:

1. Add a typed-string constant to `ConditionKind` in `model.go`
2. Implement evaluation in `condition.go` — `Evaluate` receives a `path string` and returns `(bool, error)`
3. Add to the `ConditionKind` union and `CONDITION_KIND_LABELS` in `frontend/src/types/index.ts`
4. Wire up the operator set in `operatorsFor()` in `RuleEditor.tsx`
5. Regenerate bindings

---

## Tray menu

The tray menu is rebuilt from scratch after every mutation (add/remove folder, toggle rule, etc.). The entry point is `(*tray.Controller).Rebuild()`; the `App` service calls it via `a.rebuildTray()` at the end of any method that changes visible state.

The menu-bar icon is the app icon with its transparent padding trimmed and re-centered in a square canvas (`internal/tray/icon.go`). The source PNG (`assets/forel-icon.png`) must be square.

---

## App state

The `App` service in `app.go` holds the shared state:

```go
type App struct {
    store   *db.Store    // SQLite access (single connection, serialised)
    watcher Watcher      // fsnotify control surface (Add/Remove)
    paused  *atomic.Bool // lock-free global pause flag

    app  *application.App   // Wails runtime (dialogs, quit, …)
    tray *tray.Controller   // rebuilt on visible changes
}
```

- `db.Store` wraps `*sql.DB` with `SetMaxOpenConns(1)` so all access is serialised — no manual mutex needed. `UpdateRule` is atomic via a `*sql.Tx`.
- Send watcher commands with `a.watcher.Add(path)` / `a.watcher.Remove(path)`.
- Toggle pause with `a.paused.Store(…)`.

---

## Code conventions

### Go

- Errors: return `error`; wrap with `fmt.Errorf("context: %w", err)`. Bound methods return `(T, error)`.
- No `panic` in production paths. No dead-code helpers or speculative abstractions.
- One short comment only when *why* is non-obvious — not *what*.
- macOS only: platform-specific code uses the `_darwin.go` suffix (e.g. `fileinfo_darwin.go`). Do not add Linux/Windows stubs.
- Keep `gofmt` clean.

### TypeScript / React

- Strict mode (`tsconfig.json`). No `any`.
- All binding calls go in `frontend/src/store/index.ts` — components never import from `bindings/` directly except self-contained sub-components (folder picker, tag picker).
- Zustand actions are async when they wrap a binding call.
- Styles live in `App.css` — no CSS modules, no Tailwind, no inline styles except dynamic values (e.g. `backgroundColor`).
- Component files export one default component. Inner components (e.g. `ConditionRow`) are plain functions in the same file.
- No `useEffect` for derived state — compute it inline.
- `types/index.ts` is the UI source of truth; cast generated binding results to those types in the store.

---

## PR guidelines for contributors

### Before you start

- Open an issue first for anything non-trivial. Discuss the approach before writing code.
- Check that no open PR already covers the same feature.
- `wails3 dev` must run cleanly on your machine before you begin.

### What a good PR looks like

- **One concern per PR.** A new action type is one PR. A new condition type is another.
- **Both sides of the boundary.** Any PR that adds frontend UI _must_ include the matching `App` method and regenerated bindings (and vice versa). A frontend-only PR that fakes data with hardcoded values will not be merged.
- **No breaking schema changes without a migration.** If you add a column to a SQLite table, guard it in `db.init` (e.g. `ALTER TABLE … ADD COLUMN` behind a `PRAGMA user_version` check).
- **`go build ./...`, `go vet ./...`, and `go test ./internal/...` pass** with no new issues.
- **`pnpm build` passes** with zero TypeScript errors.
- **Manual test.** Describe in the PR body what you tested: which folder, which file, which rule, what you observed.

### What will be rejected

- PRs that add a frontend action/condition with a stub Go implementation.
- PRs that break the tray (the tray must reflect state changes immediately).
- PRs that change `App.css` class names without updating all usages.
- PRs that add abstractions, helpers, or utilities "for later."
- Feature flags, backwards-compat shims, or commented-out code.

### Commit style

```
type: short imperative sentence

# type is one of: feat, fix, refactor, chore, docs
# Body is optional. Explain WHY, not WHAT.
```

---

## macOS-specific notes

- **Tags** are stored as a binary plist in the `com.apple.metadata:_kMDItemUserTags` xattr (`pkg/xattr` + `howett.net/plist`). A color label is a tag of the form `"Name\nIndex"` (gray=1, green=2, purple=3, blue=4, yellow=5, red=6, orange=7). Finder reflects changes immediately — no restart needed.
- **File watching** uses `fsnotify` (FSEvents/kqueue). The watcher runs on a goroutine; `Add`/`Remove` commands and fs events are serialised through a single `select` loop.
- **Tray icon** is trimmed/re-centered from `assets/forel-icon.png`. Keep the source PNG square.
- **Window close** hides the window instead of quitting (handled via the `WindowClosing` event in `main.go`). The app keeps running in the tray. Quit is only available from the tray menu.
- This app targets **macOS only**. Keep the code simple — no cross-platform stubs.
