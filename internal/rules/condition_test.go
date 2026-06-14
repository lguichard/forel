package rules

import (
	"os"
	"path/filepath"
	"testing"
)

func cond(kind ConditionKind, op Operator, value string) Condition {
	return Condition{Kind: kind, Operator: op, Value: value}
}

func mustEval(t *testing.T, c Condition, path string) bool {
	t.Helper()
	ok, err := Evaluate(c, path)
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	return ok
}

func TestParseSizeUnits(t *testing.T) {
	cases := []struct {
		in   string
		want uint64
	}{
		{"1024", 1024},
		{"1 KB", 1024},
		{"1.5 MB", 1_572_864},
		{"2GB", 2_147_483_648},
		{"bad value", 0},
	}
	for _, c := range cases {
		if got := parseSize(c.in); got != c.want {
			t.Errorf("parseSize(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestSizeConditionComparison(t *testing.T) {
	file := tempFile(t, "data.bin", "1234567890")
	if !mustEval(t, cond(CondSizeBytes, OpIs, "10 bytes"), file) {
		t.Error("size is 10 bytes should match")
	}
	if !mustEval(t, cond(CondSizeBytes, OpLessThan, "1 KB"), file) {
		t.Error("size less than 1 KB should match")
	}
}

func TestTagConditionTrimCaseInsensitive(t *testing.T) {
	file := tempFile(t, "document.txt", "hello")
	if err := Execute(addTagAction("Project"), file); err != nil {
		t.Fatalf("add tag: %v", err)
	}
	if !mustEval(t, cond(CondTags, OpIs, " project "), file) {
		t.Error("tag equality should match trimmed/case-insensitive")
	}
	if !mustEval(t, cond(CondTags, OpContains, "roj"), file) {
		t.Error("tag contains should match")
	}
	if !mustEval(t, cond(CondTags, OpMatchesRegex, "^proj"), file) {
		t.Error("tag regex should match")
	}
}

func TestColorLabelCondition(t *testing.T) {
	file := tempFile(t, "image.png", "png")
	setRed := Action{Kind: ActSetColorLabel, Params: map[string]any{"color": "Red"}}
	if err := Execute(setRed, file); err != nil {
		t.Fatalf("set color label: %v", err)
	}
	if !mustEval(t, cond(CondColorLabel, OpIs, "red"), file) {
		t.Error("red label should match")
	}
	if !mustEval(t, cond(CondColorLabel, OpIsNot, "blue"), file) {
		t.Error("missing blue label should match is_not")
	}
}

func TestKindConditionClassification(t *testing.T) {
	dir := t.TempDir()
	mk := func(name, contents string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(contents), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
		return p
	}
	pdf := mk("paper.pdf", "%PDF")
	image := mk("photo.heic", "image")
	archive := mk("backup.tar", "archive")
	folder := filepath.Join(dir, "Folder")
	if err := os.Mkdir(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	app := filepath.Join(dir, "Example.app")
	if err := os.Mkdir(app, 0o755); err != nil {
		t.Fatal(err)
	}

	checks := []struct {
		path string
		kind string
	}{
		{pdf, "pdf"},
		{image, "image"},
		{archive, "archive"},
		{folder, "folder"},
		{app, "application"},
	}
	for _, c := range checks {
		if !mustEval(t, cond(CondKind, OpIs, c.kind), c.path) {
			t.Errorf("%s should be kind %s", c.path, c.kind)
		}
	}
}
