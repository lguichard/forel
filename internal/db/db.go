package db

import (
	"database/sql"
	"encoding/json"
	"fmt"

	"forel/internal/rules"

	_ "modernc.org/sqlite"
)

// Store wraps the SQLite connection pool. Access is serialised to a single
// connection (SetMaxOpenConns(1)) to mirror the original single-connection
// design and avoid writer lock contention.
type Store struct {
	db *sql.DB
}

// Open opens (creating if needed) the database at path and initialises the
// schema.
func Open(path string) (*Store, error) {
	conn, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	conn.SetMaxOpenConns(1)

	s := &Store{db: conn}
	if err := s.init(); err != nil {
		conn.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) init() error {
	stmts := []string{
		`PRAGMA journal_mode=WAL`,
		`PRAGMA foreign_keys=ON`,
		`CREATE TABLE IF NOT EXISTS watched_folders (
			id          TEXT PRIMARY KEY,
			path        TEXT NOT NULL UNIQUE,
			enabled     INTEGER NOT NULL DEFAULT 1,
			created_at  TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS rules (
			id               TEXT PRIMARY KEY,
			folder_id        TEXT NOT NULL REFERENCES watched_folders(id) ON DELETE CASCADE,
			name             TEXT NOT NULL,
			enabled          INTEGER NOT NULL DEFAULT 1,
			condition_match  TEXT NOT NULL DEFAULT 'all',
			priority         INTEGER NOT NULL DEFAULT 0,
			created_at       TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS conditions (
			id        TEXT PRIMARY KEY,
			rule_id   TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
			kind      TEXT NOT NULL,
			operator  TEXT NOT NULL,
			value     TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS actions (
			id        TEXT PRIMARY KEY,
			rule_id   TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
			kind      TEXT NOT NULL,
			params    TEXT NOT NULL,
			position  INTEGER NOT NULL DEFAULT 0
		)`,
		`CREATE TABLE IF NOT EXISTS custom_tags (
			name TEXT PRIMARY KEY
		)`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.Exec(stmt); err != nil {
			return fmt.Errorf("schema init: %w", err)
		}
	}
	return nil
}

// ---------- Custom tags ----------

func (s *Store) ListCustomTags() ([]string, error) {
	rows, err := s.db.Query("SELECT name FROM custom_tags ORDER BY name")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tags []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		tags = append(tags, name)
	}
	return tags, rows.Err()
}

func (s *Store) InsertCustomTag(name string) error {
	_, err := s.db.Exec("INSERT OR IGNORE INTO custom_tags (name) VALUES (?)", name)
	return err
}

// ---------- WatchedFolder ----------

func (s *Store) ListFolders() ([]rules.WatchedFolder, error) {
	rows, err := s.db.Query("SELECT id, path, enabled, created_at FROM watched_folders ORDER BY created_at")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	folders := make([]rules.WatchedFolder, 0)
	for rows.Next() {
		var f rules.WatchedFolder
		var enabled int64
		if err := rows.Scan(&f.ID, &f.Path, &enabled, &f.CreatedAt); err != nil {
			return nil, err
		}
		f.Enabled = enabled != 0
		folders = append(folders, f)
	}
	return folders, rows.Err()
}

func (s *Store) FolderPath(id string) (string, error) {
	var path string
	err := s.db.QueryRow("SELECT path FROM watched_folders WHERE id=?", id).Scan(&path)
	return path, err
}

// FolderIDForPath returns the id of the enabled watched folder whose path
// equals path, or ("", false) if none.
func (s *Store) FolderIDForPath(path string) (string, bool) {
	var id string
	err := s.db.QueryRow("SELECT id FROM watched_folders WHERE path=? AND enabled=1", path).Scan(&id)
	if err != nil {
		return "", false
	}
	return id, true
}

func (s *Store) InsertFolder(f rules.WatchedFolder) error {
	_, err := s.db.Exec(
		"INSERT INTO watched_folders (id, path, enabled, created_at) VALUES (?,?,?,?)",
		f.ID, f.Path, boolToInt(f.Enabled), f.CreatedAt,
	)
	return err
}

func (s *Store) DeleteFolder(id string) error {
	_, err := s.db.Exec("DELETE FROM watched_folders WHERE id=?", id)
	return err
}

func (s *Store) ToggleFolder(id string, enabled bool) error {
	_, err := s.db.Exec("UPDATE watched_folders SET enabled=? WHERE id=?", boolToInt(enabled), id)
	return err
}

// ---------- Rules ----------

// FolderWithRules pairs a folder with its rules, for the tray menu.
type FolderWithRules struct {
	Folder rules.WatchedFolder
	Rules  []rules.Rule
}

func (s *Store) ListAllRulesWithFolder() ([]FolderWithRules, error) {
	folders, err := s.ListFolders()
	if err != nil {
		return nil, err
	}
	result := make([]FolderWithRules, 0, len(folders))
	for _, folder := range folders {
		rs, err := s.ListRules(folder.ID)
		if err != nil {
			return nil, err
		}
		result = append(result, FolderWithRules{Folder: folder, Rules: rs})
	}
	return result, nil
}

func (s *Store) ListRules(folderID string) ([]rules.Rule, error) {
	rows, err := s.db.Query(
		`SELECT id, folder_id, name, enabled, condition_match, priority, created_at
		 FROM rules WHERE folder_id=? ORDER BY priority, created_at`, folderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]rules.Rule, 0)
	for rows.Next() {
		var r rules.Rule
		var enabled int64
		var match string
		if err := rows.Scan(&r.ID, &r.FolderID, &r.Name, &enabled, &match, &r.Priority, &r.CreatedAt); err != nil {
			return nil, err
		}
		r.Enabled = enabled != 0
		if match == "any" {
			r.ConditionMatch = rules.MatchAny
		} else {
			r.ConditionMatch = rules.MatchAll
		}
		r.Conditions = []rules.Condition{}
		r.Actions = []rules.Action{}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for i := range out {
		conds, err := s.listConditions(out[i].ID)
		if err != nil {
			return nil, err
		}
		acts, err := s.listActions(out[i].ID)
		if err != nil {
			return nil, err
		}
		out[i].Conditions = conds
		out[i].Actions = acts
	}
	return out, nil
}

// RuleEnabled returns the enabled flag of a rule, or (false, false) if absent.
func (s *Store) RuleEnabled(id string) (bool, bool) {
	var enabled int64
	err := s.db.QueryRow("SELECT enabled FROM rules WHERE id=?", id).Scan(&enabled)
	if err != nil {
		return false, false
	}
	return enabled != 0, true
}

func (s *Store) InsertRule(r rules.Rule) error {
	_, err := s.db.Exec(
		`INSERT INTO rules (id, folder_id, name, enabled, condition_match, priority, created_at)
		 VALUES (?,?,?,?,?,?,?)`,
		r.ID, r.FolderID, r.Name, boolToInt(r.Enabled), matchToStr(r.ConditionMatch), r.Priority, r.CreatedAt,
	)
	return err
}

// UpdateRule atomically replaces a rule's row and all its conditions/actions.
func (s *Store) UpdateRule(r rules.Rule) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}

	if err := updateRuleTx(tx, r); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func updateRuleTx(tx *sql.Tx, r rules.Rule) error {
	if _, err := tx.Exec(
		"UPDATE rules SET name=?, enabled=?, condition_match=?, priority=? WHERE id=?",
		r.Name, boolToInt(r.Enabled), matchToStr(r.ConditionMatch), r.Priority, r.ID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM conditions WHERE rule_id=?", r.ID); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM actions WHERE rule_id=?", r.ID); err != nil {
		return err
	}
	for _, c := range r.Conditions {
		if _, err := tx.Exec(
			"INSERT INTO conditions (id, rule_id, kind, operator, value) VALUES (?,?,?,?,?)",
			c.ID, c.RuleID, string(c.Kind), string(c.Operator), c.Value,
		); err != nil {
			return err
		}
	}
	for _, a := range r.Actions {
		paramsJSON, err := marshalParams(a.Params)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(
			"INSERT INTO actions (id, rule_id, kind, params, position) VALUES (?,?,?,?,?)",
			a.ID, a.RuleID, string(a.Kind), paramsJSON, a.Position,
		); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) DeleteRule(id string) error {
	_, err := s.db.Exec("DELETE FROM rules WHERE id=?", id)
	return err
}

func (s *Store) ToggleRule(id string, enabled bool) error {
	_, err := s.db.Exec("UPDATE rules SET enabled=? WHERE id=?", boolToInt(enabled), id)
	return err
}

// ---------- Conditions / Actions ----------

func (s *Store) listConditions(ruleID string) ([]rules.Condition, error) {
	rows, err := s.db.Query("SELECT id, rule_id, kind, operator, value FROM conditions WHERE rule_id=?", ruleID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]rules.Condition, 0)
	for rows.Next() {
		var c rules.Condition
		var kind, op string
		if err := rows.Scan(&c.ID, &c.RuleID, &kind, &op, &c.Value); err != nil {
			return nil, err
		}
		c.Kind = rules.ConditionKind(kind)
		c.Operator = rules.Operator(op)
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) listActions(ruleID string) ([]rules.Action, error) {
	rows, err := s.db.Query(
		"SELECT id, rule_id, kind, params, position FROM actions WHERE rule_id=? ORDER BY position", ruleID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]rules.Action, 0)
	for rows.Next() {
		var a rules.Action
		var kind, paramsStr string
		if err := rows.Scan(&a.ID, &a.RuleID, &kind, &paramsStr, &a.Position); err != nil {
			return nil, err
		}
		a.Kind = rules.ActionKind(kind)
		if paramsStr != "" {
			_ = json.Unmarshal([]byte(paramsStr), &a.Params)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ---------- helpers ----------

func boolToInt(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

func matchToStr(m rules.ConditionMatch) string {
	if m == rules.MatchAny {
		return "any"
	}
	return "all"
}

func marshalParams(p map[string]any) (string, error) {
	if p == nil {
		return "null", nil
	}
	b, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
