package rules

import (
	"os"
	"path/filepath"
	"testing"
)

func mkRule(name string, enabled bool, match ConditionMatch, conds []Condition) Rule {
	return Rule{
		ID:             name,
		Name:           name,
		Enabled:        enabled,
		ConditionMatch: match,
		Conditions:     conds,
		Actions:        []Action{},
	}
}

func TestEvaluateFileMatchesEnabledRules(t *testing.T) {
	file := tempFile(t, "invoice.pdf", "paid")
	rs := []Rule{
		mkRule("all matched", true, MatchAll, []Condition{
			cond(CondName, OpContains, "invoice"),
			cond(CondExtension, OpIs, "pdf"),
		}),
		mkRule("any matched", true, MatchAny, []Condition{
			cond(CondName, OpContains, "receipt"),
			cond(CondContents, OpContains, "paid"),
		}),
		mkRule("disabled", false, MatchAll, []Condition{
			cond(CondExtension, OpIs, "pdf"),
		}),
		mkRule("empty", true, MatchAll, nil),
	}

	got := EvaluateFile(file, rs)
	want := []string{"all matched", "any matched"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("expected %v, got %v", want, got)
	}
}

func TestPreviewFileReturnsOrderedActionsWithoutExecuting(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "invoice.pdf")
	if err := os.WriteFile(file, []byte("paid"), 0o644); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(dir, "Processed")
	if err := os.Mkdir(destination, 0o755); err != nil {
		t.Fatal(err)
	}

	rule := mkRule("archive invoice", true, MatchAll, []Condition{
		cond(CondExtension, OpIs, "pdf"),
	})
	rule.Actions = []Action{
		{Kind: ActAddTag, Params: map[string]any{"tags": []any{"Reviewed"}}, Position: 2},
		{Kind: ActMoveToFolder, Params: map[string]any{"destination": destination}, Position: 1},
	}

	preview := PreviewFile(file, []Rule{rule})
	if preview == nil {
		t.Fatal("preview should match")
	}
	if _, err := os.Stat(file); err != nil {
		t.Fatal("file should still exist (no execution)")
	}
	if _, err := os.Stat(filepath.Join(destination, "invoice.pdf")); !os.IsNotExist(err) {
		t.Fatal("file should not have been moved")
	}
	if preview.Name != "invoice.pdf" {
		t.Fatalf("name = %q", preview.Name)
	}
	if preview.Rules[0].RuleName != "archive invoice" {
		t.Fatalf("rule name = %q", preview.Rules[0].RuleName)
	}
	wantActions := []string{
		"Move to " + filepath.Join(destination, "invoice.pdf"),
		"Add tag: Reviewed",
	}
	got := preview.Rules[0].Actions
	if len(got) != len(wantActions) || got[0] != wantActions[0] || got[1] != wantActions[1] {
		t.Fatalf("expected %v, got %v", wantActions, got)
	}
}
