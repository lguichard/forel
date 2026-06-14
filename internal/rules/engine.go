package rules

import (
	"log"
	"path/filepath"
	"sort"
)

// RulePreview describes the actions a matching rule would perform.
type RulePreview struct {
	RuleID   string   `json:"rule_id"`
	RuleName string   `json:"rule_name"`
	Actions  []string `json:"actions"`
}

// FilePreview groups the rules that match a single file.
type FilePreview struct {
	Path  string        `json:"path"`
	Name  string        `json:"name"`
	Rules []RulePreview `json:"rules"`
}

// PreviewResult is the outcome of a dry-run over a folder.
type PreviewResult struct {
	FilesScanned int           `json:"files_scanned"`
	Matches      []FilePreview `json:"matches"`
}

// EvaluateFile evaluates all enabled rules against path and executes matching
// ones. Returns the names of the rules that matched.
func EvaluateFile(path string, rules []Rule) []string {
	matched := make([]string, 0)
	for _, rule := range rules {
		if !rule.Enabled {
			continue
		}
		if ruleMatches(rule, path) {
			executeActions(rule, path)
			matched = append(matched, rule.Name)
		}
	}
	return matched
}

// PreviewFile evaluates enabled rules against path and returns the actions they
// would perform, without executing anything. Returns nil if nothing matches.
func PreviewFile(path string, rules []Rule) *FilePreview {
	var matchedRules []RulePreview

	for _, rule := range rules {
		if !rule.Enabled {
			continue
		}
		if !ruleMatches(rule, path) {
			continue
		}
		sorted := sortedActions(rule)
		actions := make([]string, 0, len(sorted))
		for _, act := range sorted {
			actions = append(actions, Preview(act, path))
		}
		matchedRules = append(matchedRules, RulePreview{
			RuleID:   rule.ID,
			RuleName: rule.Name,
			Actions:  actions,
		})
	}

	if len(matchedRules) == 0 {
		return nil
	}

	return &FilePreview{
		Path:  path,
		Name:  filepath.Base(path),
		Rules: matchedRules,
	}
}

func ruleMatches(rule Rule, path string) bool {
	if len(rule.Conditions) == 0 {
		return false
	}

	switch rule.ConditionMatch {
	case MatchAny:
		for _, c := range rule.Conditions {
			ok, err := Evaluate(c, path)
			if err == nil && ok {
				return true
			}
		}
		return false
	default: // MatchAll
		for _, c := range rule.Conditions {
			ok, err := Evaluate(c, path)
			if err != nil || !ok {
				return false
			}
		}
		return true
	}
}

func executeActions(rule Rule, path string) {
	for _, act := range sortedActions(rule) {
		if err := Execute(act, path); err != nil {
			log.Printf("action %q in rule %q failed on %s: %v", act.Kind, rule.Name, path, err)
		}
	}
}

func sortedActions(rule Rule) []Action {
	sorted := make([]Action, len(rule.Actions))
	copy(sorted, rule.Actions)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].Position < sorted[j].Position
	})
	return sorted
}
