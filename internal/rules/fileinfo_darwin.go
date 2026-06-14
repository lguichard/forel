package rules

import (
	"os"
	"syscall"
	"time"
)

// fileCreated returns the file's creation (birth) time on macOS, falling back
// to the modification time when the birthtime is unavailable.
func fileCreated(info os.FileInfo) time.Time {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return time.Unix(st.Birthtimespec.Sec, st.Birthtimespec.Nsec)
	}
	return info.ModTime()
}
