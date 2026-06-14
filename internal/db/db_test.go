package db

import (
	"path/filepath"
	"testing"

	"forel/internal/rules"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestRuleRoundTripPreservesTagAndColorVariants(t *testing.T) {
	s := testStore(t)
	folder := rules.NewWatchedFolder("/tmp/forel-test")
	if err := s.InsertFolder(folder); err != nil {
		t.Fatalf("insert folder: %v", err)
	}
	rule := rules.NewRule(folder.ID, "tagged images")
	if err := s.InsertRule(rule); err != nil {
		t.Fatalf("insert rule: %v", err)
	}

	rule.ConditionMatch = rules.MatchAny
	rule.Conditions = []rules.Condition{
		{ID: "c1", RuleID: rule.ID, Kind: rules.CondTags, Operator: rules.OpIs, Value: "Project"},
		{ID: "c2", RuleID: rule.ID, Kind: rules.CondSizeBytes, Operator: rules.OpGreaterThan, Value: "1 MB"},
	}
	rule.Actions = []rules.Action{
		{ID: "a1", RuleID: rule.ID, Kind: rules.ActSetColorLabel, Params: map[string]any{"color": "Blue"}, Position: 2},
		{ID: "a2", RuleID: rule.ID, Kind: rules.ActAddTag, Params: map[string]any{"tags": []any{"Reviewed"}}, Position: 1},
	}

	if err := s.UpdateRule(rule); err != nil {
		t.Fatalf("update rule: %v", err)
	}

	loaded, err := s.ListRules(folder.ID)
	if err != nil {
		t.Fatalf("list rules: %v", err)
	}
	if len(loaded) != 1 {
		t.Fatalf("expected 1 rule, got %d", len(loaded))
	}
	r := loaded[0]
	if r.ConditionMatch != rules.MatchAny {
		t.Errorf("condition_match = %q", r.ConditionMatch)
	}
	if r.Conditions[0].Kind != rules.CondTags || r.Conditions[0].Operator != rules.OpIs || r.Conditions[0].Value != "Project" {
		t.Errorf("condition[0] = %+v", r.Conditions[0])
	}
	if r.Conditions[1].Kind != rules.CondSizeBytes {
		t.Errorf("condition[1].kind = %q", r.Conditions[1].Kind)
	}
	// Actions come back ordered by position: AddTag (1), SetColorLabel (2).
	if r.Actions[0].Kind != rules.ActAddTag {
		t.Errorf("action[0].kind = %q", r.Actions[0].Kind)
	}
	if r.Actions[1].Kind != rules.ActSetColorLabel {
		t.Errorf("action[1].kind = %q", r.Actions[1].Kind)
	}
	if got := r.Actions[1].Params["color"]; got != "Blue" {
		t.Errorf("action[1] color = %v", got)
	}
}

func TestUpdateRuleRollsBackOnFailure(t *testing.T) {
	s := testStore(t)
	folder := rules.NewWatchedFolder("/tmp/forel-test-rollback")
	if err := s.InsertFolder(folder); err != nil {
		t.Fatalf("insert folder: %v", err)
	}
	original := rules.NewRule(folder.ID, "original")
	if err := s.InsertRule(original); err != nil {
		t.Fatalf("insert rule: %v", err)
	}

	original.Conditions = []rules.Condition{
		{ID: "c1", RuleID: original.ID, Kind: rules.CondName, Operator: rules.OpContains, Value: "invoice"},
	}
	if err := s.UpdateRule(original); err != nil {
		t.Fatalf("seed children: %v", err)
	}

	// Invalid update: a condition referencing a non-existent rule_id violates
	// the foreign key, so the whole transaction must roll back.
	invalid := original
	invalid.Name = "updated"
	invalid.Conditions = []rules.Condition{
		{ID: "bad", RuleID: "missing-rule-id", Kind: rules.CondExtension, Operator: rules.OpIs, Value: "pdf"},
	}
	if err := s.UpdateRule(invalid); err == nil {
		t.Fatal("expected update to fail")
	}

	loaded, err := s.ListRules(folder.ID)
	if err != nil {
		t.Fatalf("list rules: %v", err)
	}
	if len(loaded) != 1 || loaded[0].Name != "original" {
		t.Fatalf("expected original preserved, got %+v", loaded)
	}
	if len(loaded[0].Conditions) != 1 || loaded[0].Conditions[0].Value != "invoice" {
		t.Fatalf("expected original condition preserved, got %+v", loaded[0].Conditions)
	}
}
