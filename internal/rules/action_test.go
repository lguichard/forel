package rules

import (
	"os"
	"path/filepath"
	"testing"
)

func tempFile(t *testing.T, name, contents string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(contents), 0o644); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	return p
}

func addTagAction(tags ...string) Action {
	anyTags := make([]any, len(tags))
	for i, t := range tags {
		anyTags[i] = t
	}
	return Action{Kind: ActAddTag, Params: map[string]any{"tags": anyTags}}
}

func TestAddAndRemoveTagNoDuplicates(t *testing.T) {
	file := tempFile(t, "document.txt", "hello")
	add := addTagAction("Project")
	remove := Action{Kind: ActRemoveTag, Params: map[string]any{"tags": []any{"Project"}}}

	if err := Execute(add, file); err != nil {
		t.Fatalf("add tag once: %v", err)
	}
	if err := Execute(add, file); err != nil {
		t.Fatalf("add tag twice: %v", err)
	}
	if got := ReadFileTags(file); len(got) != 1 || got[0] != "Project" {
		t.Fatalf("expected [Project], got %v", got)
	}

	if err := Execute(remove, file); err != nil {
		t.Fatalf("remove tag: %v", err)
	}
	if got := ReadFileTags(file); len(got) != 0 {
		t.Fatalf("expected no tags, got %v", got)
	}
}

func TestSetColorLabelReplacesColorAndKeepsTextTags(t *testing.T) {
	file := tempFile(t, "image.png", "png")
	setRed := Action{Kind: ActSetColorLabel, Params: map[string]any{"color": "Red"}}
	setBlue := Action{Kind: ActSetColorLabel, Params: map[string]any{"color": "Blue"}}

	if err := Execute(addTagAction("Project"), file); err != nil {
		t.Fatalf("add text tag: %v", err)
	}
	if err := Execute(setRed, file); err != nil {
		t.Fatalf("set red: %v", err)
	}
	if err := Execute(setBlue, file); err != nil {
		t.Fatalf("replace with blue: %v", err)
	}

	got := ReadFileTags(file)
	want := []string{"Project", "Blue\n4"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("expected %v, got %v", want, got)
	}
}

func TestSetColorLabelEmptyClearsLabel(t *testing.T) {
	file := tempFile(t, "image.png", "png")
	setRed := Action{Kind: ActSetColorLabel, Params: map[string]any{"color": "Red"}}
	clear := Action{Kind: ActSetColorLabel, Params: map[string]any{}}

	if err := Execute(addTagAction("Project"), file); err != nil {
		t.Fatalf("add text tag: %v", err)
	}
	if err := Execute(setRed, file); err != nil {
		t.Fatalf("set red: %v", err)
	}
	if err := Execute(clear, file); err != nil {
		t.Fatalf("clear label: %v", err)
	}

	got := ReadFileTags(file)
	if len(got) != 1 || got[0] != "Project" {
		t.Fatalf("expected [Project], got %v", got)
	}
}

func TestRenamePatternDoesNotDoubleAppendExtension(t *testing.T) {
	file := tempFile(t, "report.txt", "hello")
	dir := filepath.Dir(file)
	rename := Action{Kind: ActRename, Params: map[string]any{"pattern": "{name}-archived.{extension}"}}

	if err := Execute(rename, file); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatalf("original should not exist")
	}
	if _, err := os.Stat(filepath.Join(dir, "report-archived.txt")); err != nil {
		t.Fatalf("expected report-archived.txt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "report-archived.txt.txt")); !os.IsNotExist(err) {
		t.Fatalf("should not double-append extension")
	}
}
