package rules

import (
	"time"

	"github.com/google/uuid"
)

// WatchedFolder is a directory Forel monitors for rule evaluation.
type WatchedFolder struct {
	ID        string `json:"id"`
	Path      string `json:"path"`
	Enabled   bool   `json:"enabled"`
	CreatedAt string `json:"created_at"`
}

func NewWatchedFolder(path string) WatchedFolder {
	return WatchedFolder{
		ID:        uuid.NewString(),
		Path:      path,
		Enabled:   true,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
}

// ConditionMatch decides whether all or any conditions must hold for a rule.
type ConditionMatch string

const (
	MatchAll ConditionMatch = "all"
	MatchAny ConditionMatch = "any"
)

// ConditionKind enumerates the supported condition types. The string values
// mirror the snake_case stored in SQLite and consumed by the frontend.
type ConditionKind string

const (
	CondName       ConditionKind = "name"
	CondExtension  ConditionKind = "extension"
	CondKind       ConditionKind = "kind"
	CondSizeBytes  ConditionKind = "size_bytes"
	CondTags       ConditionKind = "tags"
	CondColorLabel ConditionKind = "color_label"
	CondContents   ConditionKind = "contents"
)

// Operator enumerates comparison operators usable by conditions.
type Operator string

const (
	OpIs             Operator = "is"
	OpIsNot          Operator = "is_not"
	OpContains       Operator = "contains"
	OpDoesNotContain Operator = "does_not_contain"
	OpStartsWith     Operator = "starts_with"
	OpEndsWith       Operator = "ends_with"
	OpMatchesRegex   Operator = "matches_regex"
	OpGreaterThan    Operator = "greater_than"
	OpLessThan       Operator = "less_than"
)

// Condition is a single predicate evaluated against a file.
type Condition struct {
	ID       string        `json:"id"`
	RuleID   string        `json:"rule_id"`
	Kind     ConditionKind `json:"kind"`
	Operator Operator      `json:"operator"`
	Value    string        `json:"value"`
}

// ActionKind enumerates the supported actions. String values mirror the
// snake_case stored in SQLite and consumed by the frontend.
type ActionKind string

const (
	ActMoveToFolder  ActionKind = "move_to_folder"
	ActCopyToFolder  ActionKind = "copy_to_folder"
	ActRename        ActionKind = "rename"
	ActMoveToTrash   ActionKind = "move_to_trash"
	ActDelete        ActionKind = "delete"
	ActAddTag        ActionKind = "add_tag"
	ActRemoveTag     ActionKind = "remove_tag"
	ActSetColorLabel ActionKind = "set_color_label"
	ActRunScript     ActionKind = "run_script"
)

// Action is one operation performed when a rule matches. Params is a freeform
// JSON object whose keys depend on Kind (see action.go).
type Action struct {
	ID       string         `json:"id"`
	RuleID   string         `json:"rule_id"`
	Kind     ActionKind     `json:"kind"`
	Params   map[string]any `json:"params"`
	Position int64          `json:"position"`
}

// Rule groups conditions and actions for a watched folder.
type Rule struct {
	ID             string         `json:"id"`
	FolderID       string         `json:"folder_id"`
	Name           string         `json:"name"`
	Enabled        bool           `json:"enabled"`
	ConditionMatch ConditionMatch `json:"condition_match"`
	Conditions     []Condition    `json:"conditions"`
	Actions        []Action       `json:"actions"`
	Priority       int64          `json:"priority"`
	CreatedAt      string         `json:"created_at"`
}

func NewRule(folderID, name string) Rule {
	return Rule{
		ID:             uuid.NewString(),
		FolderID:       folderID,
		Name:           name,
		Enabled:        true,
		ConditionMatch: MatchAll,
		Conditions:     []Condition{},
		Actions:        []Action{},
		Priority:       0,
		CreatedAt:      time.Now().UTC().Format(time.RFC3339),
	}
}

// paramString returns the string value at key, or "".
func paramString(params map[string]any, key string) string {
	if params == nil {
		return ""
	}
	if v, ok := params[key].(string); ok {
		return v
	}
	return ""
}

// paramStrings returns the []string value at key (JSON arrays decode to []any).
func paramStrings(params map[string]any, key string) []string {
	if params == nil {
		return nil
	}
	raw, ok := params[key].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}
