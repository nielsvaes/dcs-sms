//go:build windows

package fileutil

import (
	"errors"
	"syscall"
)

// errSharingViolation is Windows error code 32 (ERROR_SHARING_VIOLATION):
// "The process cannot access the file because it is being used by another
// process." Raised when an open conflicts with another process's open or
// an in-progress rename.
const errSharingViolation = syscall.Errno(32)

func isSharingViolation(err error) bool {
	return errors.Is(err, errSharingViolation)
}
