package watcher

import (
	"log"
	"path/filepath"

	"forel/internal/db"
	"forel/internal/rules"

	"github.com/fsnotify/fsnotify"
)

type cmdOp int

const (
	opAdd cmdOp = iota
	opRemove
)

type cmd struct {
	op   cmdOp
	path string
}

// Handle is the control surface for the background watcher.
type Handle struct {
	cmds chan cmd
}

// Add starts watching path (non-recursive).
func (h *Handle) Add(path string) { h.cmds <- cmd{op: opAdd, path: path} }

// Remove stops watching path.
func (h *Handle) Remove(path string) { h.cmds <- cmd{op: opRemove, path: path} }

// Start launches the watcher loop on a background goroutine.
func Start(store *db.Store) (*Handle, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}

	h := &Handle{cmds: make(chan cmd, 32)}
	watched := make(map[string]bool)

	go func() {
		defer w.Close()
		for {
			select {
			case event, ok := <-w.Events:
				if !ok {
					return
				}
				onEvent(event, store)

			case err, ok := <-w.Errors:
				if !ok {
					return
				}
				log.Printf("watcher error: %v", err)

			case c := <-h.cmds:
				switch c.op {
				case opAdd:
					if !watched[c.path] {
						if err := w.Add(c.path); err != nil {
							log.Printf("watch %s: %v", c.path, err)
						} else {
							watched[c.path] = true
						}
					}
				case opRemove:
					_ = w.Remove(c.path)
					delete(watched, c.path)
				}
			}
		}
	}()

	return h, nil
}

func onEvent(event fsnotify.Event, store *db.Store) {
	// React to files newly created in or moved into a watched folder.
	if !event.Op.Has(fsnotify.Create) && !event.Op.Has(fsnotify.Rename) {
		return
	}

	rs := loadRulesForPath(event.Name, store)
	matched := rules.EvaluateFile(event.Name, rs)
	for _, name := range matched {
		log.Printf("Rule '%s' matched %s", name, event.Name)
	}
}

func loadRulesForPath(path string, store *db.Store) []rules.Rule {
	parent := filepath.Dir(path)
	folderID, ok := store.FolderIDForPath(parent)
	if !ok {
		return nil
	}
	rs, err := store.ListRules(folderID)
	if err != nil {
		return nil
	}
	return rs
}
