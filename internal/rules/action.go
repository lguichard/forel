package rules

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/pkg/xattr"
	"howett.net/plist"
)

// Execute runs the action on the file at path.
func Execute(action Action, path string) error {
	switch action.Kind {
	case ActMoveToFolder:
		dest := paramString(action.Params, "destination")
		if dest == "" {
			return fmt.Errorf("MoveToFolder requires 'destination' param")
		}
		target := filepath.Join(dest, filepath.Base(path))
		if err := os.Rename(path, target); err != nil {
			return fmt.Errorf("move %s → %s: %w", path, target, err)
		}

	case ActCopyToFolder:
		dest := paramString(action.Params, "destination")
		if dest == "" {
			return fmt.Errorf("CopyToFolder requires 'destination' param")
		}
		target := filepath.Join(dest, filepath.Base(path))
		if err := copyFile(path, target); err != nil {
			return fmt.Errorf("copy %s → %s: %w", path, target, err)
		}

	case ActRename:
		pattern := paramString(action.Params, "pattern")
		if pattern == "" {
			return fmt.Errorf("Rename requires 'pattern' param")
		}
		newName, err := applyRenamePattern(pattern, path)
		if err != nil {
			return err
		}
		target := filepath.Join(filepath.Dir(path), newName)
		if err := os.Rename(path, target); err != nil {
			return fmt.Errorf("rename %s → %s: %w", path, target, err)
		}

	case ActMoveToTrash:
		trash, err := trashDir()
		if err != nil {
			return err
		}
		target := filepath.Join(trash, filepath.Base(path))
		if err := os.Rename(path, target); err != nil {
			return err
		}

	case ActDelete:
		info, err := os.Stat(path)
		if err != nil {
			return err
		}
		if info.IsDir() {
			return os.RemoveAll(path)
		}
		return os.Remove(path)

	case ActAddTag:
		for _, tag := range paramStrings(action.Params, "tags") {
			if err := applyFileTag(path, tag, true); err != nil {
				return err
			}
		}

	case ActRemoveTag:
		for _, tag := range paramStrings(action.Params, "tags") {
			if err := applyFileTag(path, tag, false); err != nil {
				return err
			}
		}

	case ActSetColorLabel:
		return setColorLabel(path, paramString(action.Params, "color"))

	case ActRunScript:
		script := paramString(action.Params, "script")
		if script == "" {
			return fmt.Errorf("RunScript requires 'script' param")
		}
		cmd := exec.Command("bash", "-c", script)
		cmd.Env = append(os.Environ(), "FOREL_FILE="+path)
		return cmd.Start()
	}

	return nil
}

// Preview returns a human-readable description of the action without running it.
func Preview(action Action, path string) string {
	fileName := filepath.Base(path)

	switch action.Kind {
	case ActMoveToFolder:
		dest := paramString(action.Params, "destination")
		return "Move to " + filepath.Join(dest, fileName)
	case ActCopyToFolder:
		dest := paramString(action.Params, "destination")
		return "Copy to " + filepath.Join(dest, fileName)
	case ActRename:
		pattern := paramString(action.Params, "pattern")
		newName, err := applyRenamePattern(pattern, path)
		if err != nil {
			return err.Error()
		}
		return "Rename to " + newName
	case ActMoveToTrash:
		return "Move to Trash"
	case ActDelete:
		return "Delete permanently"
	case ActAddTag:
		tags := paramStrings(action.Params, "tags")
		if len(tags) == 0 {
			return "Add tag"
		}
		return fmt.Sprintf("Add tag%s: %s", plural(len(tags)), strings.Join(tags, ", "))
	case ActRemoveTag:
		tags := paramStrings(action.Params, "tags")
		if len(tags) == 0 {
			return "Remove tag"
		}
		return fmt.Sprintf("Remove tag%s: %s", plural(len(tags)), strings.Join(tags, ", "))
	case ActSetColorLabel:
		color := paramString(action.Params, "color")
		if color == "" {
			return "Clear color label"
		}
		return "Set color label to " + color
	case ActRunScript:
		script := paramString(action.Params, "script")
		firstLine := ""
		if idx := strings.IndexByte(script, '\n'); idx >= 0 {
			firstLine = strings.TrimSpace(script[:idx])
		} else {
			firstLine = strings.TrimSpace(script)
		}
		if firstLine == "" {
			return "Run script"
		}
		return "Run script: " + firstLine
	}
	return ""
}

func plural(n int) string {
	if n > 1 {
		return "s"
	}
	return ""
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := out.ReadFrom(in); err != nil {
		return err
	}
	return out.Close()
}

// applyRenamePattern substitutes tokens in rename patterns.
// Supported tokens: {name}, {extension}, {date_created}, {date_modified}.
func applyRenamePattern(pattern, path string) (string, error) {
	base := filepath.Base(path)
	ext := strings.TrimPrefix(filepath.Ext(base), ".")
	stem := strings.TrimSuffix(base, filepath.Ext(base))

	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	modified := info.ModTime().Local().Format("2006-01-02")
	created := fileCreated(info).Local().Format("2006-01-02")

	result := pattern
	result = strings.ReplaceAll(result, "{name}", stem)
	result = strings.ReplaceAll(result, "{extension}", ext)
	result = strings.ReplaceAll(result, "{date_modified}", modified)
	result = strings.ReplaceAll(result, "{date_created}", created)

	if result == "" {
		return "", fmt.Errorf("rename pattern produced empty filename")
	}

	if ext == "" || strings.Contains(pattern, "{extension}") {
		return result, nil
	}
	return result + "." + ext, nil
}

// ---------- macOS Finder tags via xattr ----------

const tagsXattr = "com.apple.metadata:_kMDItemUserTags"

// ReadFileTags reads the Finder tags on path, or an empty list if there are
// none. Tags are stored as a binary-plist-encoded []string in the extended
// attribute com.apple.metadata:_kMDItemUserTags. A color label is a tag whose
// name matches a system colour (suffixed with "\nN").
func ReadFileTags(path string) []string {
	data, err := xattr.Get(path, tagsXattr)
	if err != nil || len(data) == 0 {
		return nil
	}
	var tags []string
	if _, err := plist.Unmarshal(data, &tags); err != nil {
		return nil
	}
	return tags
}

// writeFileTags serialises tags to a binary plist and writes them to the xattr.
func writeFileTags(path string, tags []string) error {
	buf, err := plist.Marshal(tags, plist.BinaryFormat)
	if err != nil {
		return fmt.Errorf("failed to serialise tags plist: %w", err)
	}
	if err := xattr.Set(path, tagsXattr, buf); err != nil {
		return fmt.Errorf("failed to write tags xattr: %w", err)
	}
	return nil
}

// applyFileTag adds or removes a named Finder tag on path. Finder reads tags
// live so the change is visible immediately without any Finder restart.
func applyFileTag(path, tag string, add bool) error {
	tags := ReadFileTags(path)

	if add {
		for _, t := range tags {
			if t == tag {
				return nil
			}
		}
		tags = append(tags, tag)
	} else {
		filtered := tags[:0:0]
		for _, t := range tags {
			if t != tag {
				filtered = append(filtered, t)
			}
		}
		tags = filtered
	}

	return writeFileTags(path, tags)
}

// colorIndex returns the Finder colour-label index for each system colour.
func colorIndex(name string) (uint8, bool) {
	switch strings.ToLower(name) {
	case "gray", "grey":
		return 1, true
	case "green":
		return 2, true
	case "purple":
		return 3, true
	case "blue":
		return 4, true
	case "yellow":
		return 5, true
	case "red":
		return 6, true
	case "orange":
		return 7, true
	default:
		return 0, false
	}
}

// setColorLabel sets the macOS colour label on path, replacing any existing
// colour label. Finder stores a colour label as a tag of the form "Name\nIndex".
// Any existing system-colour tag is dropped first so a file has at most one
// colour. An empty/unknown colour just clears the label.
func setColorLabel(path, color string) error {
	tags := ReadFileTags(path)

	kept := tags[:0:0]
	for _, t := range tags {
		name := strings.TrimSpace(t)
		if idx := strings.IndexByte(t, '\n'); idx >= 0 {
			name = strings.TrimSpace(t[:idx])
		}
		if _, isColor := colorIndex(name); !isColor {
			kept = append(kept, t)
		}
	}

	if idx, ok := colorIndex(color); ok {
		kept = append(kept, fmt.Sprintf("%s\n%d", capitalize(color), idx))
	}

	return writeFileTags(path, kept)
}

func capitalize(s string) string {
	if s == "" {
		return ""
	}
	return strings.ToUpper(s[:1]) + strings.ToLower(s[1:])
}

func trashDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".Trash"), nil
}
