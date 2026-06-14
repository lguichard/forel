package main

import (
	"embed"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"

	"forel/internal/db"
	"forel/internal/tray"
	"forel/internal/watcher"

	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed assets/forel-icon.png
var iconPNG []byte

func main() {
	store, err := db.Open(databasePath())
	if err != nil {
		log.Fatalf("open database: %v", err)
	}

	w, err := watcher.Start(store)
	if err != nil {
		log.Fatalf("start watcher: %v", err)
	}

	var paused atomic.Bool
	appSvc := NewApp(store, w, &paused)

	app := application.New(application.Options{
		Name:        "Forel",
		Description: "Open-source file automation for macOS",
		Services: []application.Service{
			application.NewService(appSvc),
		},
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(assets),
		},
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: false,
		},
	})
	appSvc.app = app

	win := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:     "Forel",
		Width:     900,
		Height:    620,
		MinWidth:  720,
		MinHeight: 520,
		Mac: application.MacWindow{
			InvisibleTitleBarHeight: 44,
			TitleBar:                application.MacTitleBarHiddenInset,
			Backdrop:                application.MacBackdropNormal,
		},
		BackgroundColour: application.NewRGB(30, 30, 30),
		URL:              "/",
	})

	// Hide the window on close instead of quitting; the app stays in the tray.
	win.OnWindowEvent(events.Common.WindowClosing, func(e *application.WindowEvent) {
		e.Cancel()
		win.Hide()
	})

	// System tray.
	trayCtl := tray.New(app, win, store, w, &paused, iconPNG)
	appSvc.tray = trayCtl
	trayCtl.Setup()

	// Start watching all currently enabled folders.
	if folders, err := store.ListFolders(); err == nil {
		for _, f := range folders {
			if f.Enabled {
				w.Add(f.Path)
			}
		}
	}

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}

// databasePath mirrors the original Tauri data dir so existing rules survive:
// ~/Library/Application Support/com.forel.app/forel.db.
func databasePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("home dir unavailable: %v", err)
	}
	dir := filepath.Join(home, "Library", "Application Support", "com.forel.app")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Fatalf("create data dir: %v", err)
	}
	return filepath.Join(dir, "forel.db")
}
