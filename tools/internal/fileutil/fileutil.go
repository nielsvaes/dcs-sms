// Package fileutil provides small file-IO helpers that handle
// platform-specific quirks. The current contents focus on Windows
// atomic-rename / concurrent-read race handling.
package fileutil

import (
	"os"
	"time"
)

// ReadFileRetry reads path, retrying briefly when the underlying
// os.ReadFile fails with a transient Windows sharing violation. Such
// errors can occur when a writer is performing an atomic
// WriteFile+Rename while a reader concurrently opens the file. On
// non-Windows platforms this behaves like os.ReadFile.
//
// The retry budget is intentionally small: 4 attempts with 2/4/8 ms
// backoff (14 ms total). The sharing violation is microseconds long
// in practice; the retry exists to ride over it, not to wait for a
// file to appear.
func ReadFileRetry(path string) ([]byte, error) {
	const maxAttempts = 4
	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		data, err := os.ReadFile(path)
		if err == nil {
			return data, nil
		}
		if !isSharingViolation(err) {
			return nil, err
		}
		lastErr = err
		time.Sleep(time.Duration(2<<attempt) * time.Millisecond)
	}
	return nil, lastErr
}
