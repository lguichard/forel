package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"

	"forel/internal/db"
	"forel/internal/rules"
	"forel/internal/tray"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// App is the service bound to the frontend. Each exported method becomes an
// IPC-callable function in the generated TypeScript bindings.
type App struct {
	store   *db.Store
	watcher Watcher
	paused  *atomic.Bool

	app  *application.App
	tray *tray.Controller
}

// Watcher is the subset of the file watcher the App needs.
type Watcher interface {
	Add(path string)
	Remove(path string)
}

func NewApp(store *db.Store, w Watcher, paused *atomic.Bool) *App {
	return &App{store: store, watcher: w, paused: paused}
}

func (a *App) rebuildTray() {
	if a.tray != nil {
		a.tray.Rebuild()
	}
}

// ---------- Folders ----------

func (a *App) GetWatchedFolders() ([]rules.WatchedFolder, error) {
	return a.store.ListFolders()
}

func (a *App) AddWatchedFolder(path string) (rules.WatchedFolder, error) {
	folder := rules.NewWatchedFolder(path)
	if err := a.store.InsertFolder(folder); err != nil {
		return rules.WatchedFolder{}, err
	}
	a.watcher.Add(path)
	a.rebuildTray()
	return folder, nil
}

func (a *App) RemoveWatchedFolder(id string) error {
	path, _ := a.store.FolderPath(id)
	if err := a.store.DeleteFolder(id); err != nil {
		return err
	}
	if path != "" {
		a.watcher.Remove(path)
	}
	a.rebuildTray()
	return nil
}

func (a *App) ToggleWatchedFolder(id string, enabled bool) error {
	if err := a.store.ToggleFolder(id, enabled); err != nil {
		return err
	}
	a.rebuildTray()
	return nil
}

// ---------- Rules ----------

func (a *App) GetRules(folderID string) ([]rules.Rule, error) {
	return a.store.ListRules(folderID)
}

func (a *App) CreateRule(folderID, name string) (rules.Rule, error) {
	rule := rules.NewRule(folderID, name)
	if err := a.store.InsertRule(rule); err != nil {
		return rules.Rule{}, err
	}
	a.rebuildTray()
	return rule, nil
}

func (a *App) UpdateRule(rule rules.Rule) error {
	if err := a.store.UpdateRule(rule); err != nil {
		return err
	}
	a.rebuildTray()
	return nil
}

func (a *App) DeleteRule(ruleID string) error {
	if err := a.store.DeleteRule(ruleID); err != nil {
		return err
	}
	a.rebuildTray()
	return nil
}

func (a *App) ToggleRule(ruleID string, enabled bool) error {
	if err := a.store.ToggleRule(ruleID, enabled); err != nil {
		return err
	}
	a.rebuildTray()
	return nil
}

// RunRulesNow evaluates and applies all rules to every file in the folder.
func (a *App) RunRulesNow(folderID string) ([]string, error) {
	folderPath, rs, err := a.folderRules(folderID)
	if err != nil {
		return nil, err
	}

	matched := make([]string, 0)
	entries, err := os.ReadDir(folderPath)
	if err == nil {
		for _, entry := range entries {
			p := filepath.Join(folderPath, entry.Name())
			matched = append(matched, rules.EvaluateFile(p, rs)...)
		}
	}
	return matched, nil
}

// PreviewRules simulates rule evaluation over the folder without running actions.
func (a *App) PreviewRules(folderID string) (rules.PreviewResult, error) {
	folderPath, rs, err := a.folderRules(folderID)
	if err != nil {
		return rules.PreviewResult{}, err
	}

	result := rules.PreviewResult{FilesScanned: 0, Matches: []rules.FilePreview{}}
	entries, err := os.ReadDir(folderPath)
	if err != nil {
		return rules.PreviewResult{}, err
	}
	for _, entry := range entries {
		p := filepath.Join(folderPath, entry.Name())
		result.FilesScanned++
		if preview := rules.PreviewFile(p, rs); preview != nil {
			result.Matches = append(result.Matches, *preview)
		}
	}
	return result, nil
}

func (a *App) folderRules(folderID string) (string, []rules.Rule, error) {
	path, err := a.store.FolderPath(folderID)
	if err != nil {
		return "", nil, err
	}
	rs, err := a.store.ListRules(folderID)
	if err != nil {
		return "", nil, err
	}
	return path, rs, nil
}

// ---------- Tags ----------

// GetMacosTags returns text tags: Finder favourites + custom tags from the DB.
// The 7 system colour names are excluded — colours are handled separately.
func (a *App) GetMacosTags() []string {
	colors := map[string]bool{
		"red": true, "orange": true, "yellow": true, "green": true,
		"blue": true, "purple": true, "gray": true, "grey": true,
	}
	isColor := func(name string) bool { return colors[strings.ToLower(name)] }

	tags := make([]string, 0)
	seen := map[string]bool{}
	add := func(name string) {
		if name != "" && !isColor(name) && !seen[name] {
			seen[name] = true
			tags = append(tags, name)
		}
	}

	// Finder favourite tags.
	if out, err := exec.Command("defaults", "read", "com.apple.finder", "FavoriteTagNames").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			name := strings.TrimSpace(line)
			name = strings.TrimSuffix(name, ",")
			name = strings.Trim(name, "\"")
			if name != "(" && name != ")" {
				add(name)
			}
		}
	}

	// User-defined tags stored in our DB.
	if custom, err := a.store.ListCustomTags(); err == nil {
		for _, name := range custom {
			add(name)
		}
	}

	return tags
}

// AddCustomTag persists a user-defined tag so it appears across sessions.
func (a *App) AddCustomTag(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("tag name cannot be empty")
	}
	return a.store.InsertCustomTag(name)
}

// SelectDirectory opens a native folder picker and returns the chosen path, or
// "" if the user cancelled.
func (a *App) SelectDirectory() (string, error) {
	dialog := a.app.Dialog.OpenFile()
	dialog.CanChooseDirectories(true)
	dialog.CanChooseFiles(false)
	return dialog.PromptForSingleSelection()
}
