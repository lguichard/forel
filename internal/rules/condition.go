package rules

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Evaluate returns true if the file at path satisfies the condition.
func Evaluate(cond Condition, path string) (bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		return false, err
	}

	switch cond.Kind {
	case CondName:
		base := filepath.Base(path)
		name := strings.TrimSuffix(base, filepath.Ext(base))
		return matchString(cond.Operator, name, cond.Value), nil

	case CondExtension:
		ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
		value := strings.ToLower(strings.TrimPrefix(cond.Value, "."))
		return matchString(cond.Operator, ext, value), nil

	case CondKind:
		detected := detectKind(path, info)
		switch cond.Operator {
		case OpIs:
			return detected == cond.Value, nil
		case OpIsNot:
			return detected != cond.Value, nil
		default:
			return false, nil
		}

	case CondSizeBytes:
		size := uint64(info.Size())
		threshold := parseSize(cond.Value)
		switch cond.Operator {
		case OpIs:
			return size == threshold, nil
		case OpIsNot:
			return size != threshold, nil
		case OpGreaterThan:
			return size > threshold, nil
		case OpLessThan:
			return size < threshold, nil
		default:
			return false, nil
		}

	case CondTags:
		target := strings.ToLower(strings.TrimSpace(cond.Value))
		names := tagNames(path)
		switch cond.Operator {
		case OpIs:
			return contains(names, target), nil
		case OpIsNot:
			return !contains(names, target), nil
		case OpContains:
			return anyMatch(names, func(n string) bool { return strings.Contains(n, target) }), nil
		case OpDoesNotContain:
			return !anyMatch(names, func(n string) bool { return strings.Contains(n, target) }), nil
		case OpStartsWith:
			return anyMatch(names, func(n string) bool { return strings.HasPrefix(n, target) }), nil
		case OpEndsWith:
			return anyMatch(names, func(n string) bool { return strings.HasSuffix(n, target) }), nil
		case OpMatchesRegex:
			re, err := regexp.Compile(cond.Value)
			if err != nil {
				return false, nil
			}
			return anyMatch(names, func(n string) bool { return re.MatchString(n) }), nil
		default:
			return false, nil
		}

	case CondColorLabel:
		target := strings.ToLower(cond.Value)
		has := anyMatch(tagNames(path), func(n string) bool { return n == target })
		switch cond.Operator {
		case OpIs:
			return has, nil
		case OpIsNot:
			return !has, nil
		default:
			return false, nil
		}

	case CondContents:
		data, _ := os.ReadFile(path)
		return matchString(cond.Operator, string(data), cond.Value), nil
	}

	return false, nil
}

// tagNames returns the lower-cased tag names on path, dropping any "\nN"
// colour-index suffix.
func tagNames(path string) []string {
	tags := ReadFileTags(path)
	names := make([]string, 0, len(tags))
	for _, t := range tags {
		name := t
		if idx := strings.IndexByte(t, '\n'); idx >= 0 {
			name = t[:idx]
		}
		names = append(names, strings.ToLower(strings.TrimSpace(name)))
	}
	return names
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}

func anyMatch(items []string, pred func(string) bool) bool {
	for _, item := range items {
		if pred(item) {
			return true
		}
	}
	return false
}

// detectKind classifies a file into a Hazel-style kind string based on its
// extension.
func detectKind(path string, info os.FileInfo) string {
	if info.IsDir() {
		if strings.EqualFold(filepath.Ext(path), ".app") {
			return "application"
		}
		return "folder"
	}

	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))

	switch ext {
	case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg", "heic",
		"heif", "raw", "cr2", "cr3", "nef", "arw", "dng":
		return "image"
	case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm", "mpg", "mpeg":
		return "movie"
	case "mp3", "aac", "flac", "wav", "aiff", "aif", "m4a", "ogg", "wma", "opus":
		return "music"
	case "pdf":
		return "pdf"
	case "txt", "md", "markdown", "rtf", "rst", "log":
		return "text"
	case "ppt", "pptx", "key", "odp":
		return "presentation"
	case "zip", "tar", "gz", "bz2", "7z", "rar", "xz", "zst", "tgz", "tbz", "cab":
		return "archive"
	case "dmg", "iso", "img", "sparseimage", "sparsebundle":
		return "disk_image"
	default:
		return "document"
	}
}

func matchString(operator Operator, haystack, needle string) bool {
	switch operator {
	case OpIs:
		return haystack == needle
	case OpIsNot:
		return haystack != needle
	case OpContains:
		return strings.Contains(haystack, needle)
	case OpDoesNotContain:
		return !strings.Contains(haystack, needle)
	case OpStartsWith:
		return strings.HasPrefix(haystack, needle)
	case OpEndsWith:
		return strings.HasSuffix(haystack, needle)
	case OpMatchesRegex:
		re, err := regexp.Compile(needle)
		if err != nil {
			return false
		}
		return re.MatchString(haystack)
	default:
		return false
	}
}

// parseSize parses a size threshold into bytes. Accepts a plain number
// ("5242880") or a number with a unit suffix ("5 MB", "100kb"). Unitless
// values are bytes.
func parseSize(value string) uint64 {
	s := strings.TrimSpace(value)
	split := len(s)
	for i, c := range s {
		if !(c >= '0' && c <= '9') && c != '.' {
			split = i
			break
		}
	}
	numPart := strings.TrimSpace(s[:split])
	unit := strings.ToLower(strings.TrimSpace(s[split:]))

	n, err := strconv.ParseFloat(numPart, 64)
	if err != nil {
		n = 0
	}

	mult := 1.0
	switch unit {
	case "kb":
		mult = 1024.0
	case "mb":
		mult = 1024.0 * 1024.0
	case "gb":
		mult = 1024.0 * 1024.0 * 1024.0
	}

	return uint64(n * mult)
}
