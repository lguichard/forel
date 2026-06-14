package tray

import (
	"path/filepath"
	"sync/atomic"

	"forel/internal/db"
	"forel/internal/watcher"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// Controller owns the system tray and rebuilds its menu on demand.
type Controller struct {
	app     *application.App
	win     application.Window
	store   *db.Store
	watcher *watcher.Handle
	paused  *atomic.Bool

	tray *application.SystemTray
	icon []byte
}

// New creates a tray controller. iconPNG is the raw source PNG to display.
func New(
	app *application.App,
	win application.Window,
	store *db.Store,
	w *watcher.Handle,
	paused *atomic.Bool,
	iconPNG []byte,
) *Controller {
	return &Controller{
		app:     app,
		win:     win,
		store:   store,
		watcher: w,
		paused:  paused,
		icon:    processIcon(iconPNG),
	}
}

// Setup creates the tray and installs the first menu.
func (c *Controller) Setup() {
	c.tray = c.app.SystemTray.New()
	if len(c.icon) > 0 {
		c.tray.SetIcon(c.icon)
	}
	c.tray.SetTooltip("Forel")
	c.tray.SetMenu(c.buildMenu())
}

// Rebuild regenerates the tray menu to reflect current state.
func (c *Controller) Rebuild() {
	if c.tray == nil {
		return
	}
	c.tray.SetMenu(c.buildMenu())
}

func (c *Controller) buildMenu() *application.Menu {
	menu := application.NewMenu()

	// Primary action at top.
	menu.Add("Open Forel").OnClick(func(*application.Context) {
		c.win.Show()
		c.win.Focus()
	})
	menu.AddSeparator()

	paused := c.paused.Load()
	statusLabel, actionLabel := "🟢  File watching is active", "Stop Watching"
	if paused {
		statusLabel, actionLabel = "🔴  File watching is paused", "Start Watching"
	}

	status := menu.Add(statusLabel)
	status.SetEnabled(false)
	menu.Add(actionLabel).OnClick(func(*application.Context) { c.toggleWatch() })
	menu.AddSeparator()

	// Rules grouped by folder.
	hasRules := false
	if groups, err := c.store.ListAllRulesWithFolder(); err == nil {
		for _, group := range groups {
			if len(group.Rules) == 0 {
				continue
			}
			folderName := filepath.Base(group.Folder.Path)
			if folderName == "" || folderName == "." {
				folderName = group.Folder.Path
			}
			header := menu.Add(folderName)
			header.SetEnabled(false)

			for _, rule := range group.Rules {
				hasRules = true
				ruleID := rule.ID
				item := menu.AddCheckbox(rule.Name, rule.Enabled)
				item.OnClick(func(*application.Context) { c.toggleRule(ruleID) })
			}
		}
	}

	if !hasRules {
		noRules := menu.Add("No rules configured")
		noRules.SetEnabled(false)
	}

	menu.AddSeparator()
	menu.Add("Quit Forel").OnClick(func(*application.Context) { c.app.Quit() })

	return menu
}

func (c *Controller) toggleWatch() {
	nowPaused := !c.paused.Load()
	c.paused.Store(nowPaused)

	folders, err := c.store.ListFolders()
	if err != nil {
		c.Rebuild()
		return
	}
	for _, f := range folders {
		if nowPaused {
			c.watcher.Remove(f.Path)
		} else if f.Enabled {
			c.watcher.Add(f.Path)
		}
	}
	c.Rebuild()
}

func (c *Controller) toggleRule(ruleID string) {
	enabled, ok := c.store.RuleEnabled(ruleID)
	if !ok {
		return
	}
	if err := c.store.ToggleRule(ruleID, !enabled); err == nil {
		c.Rebuild()
	}
}
