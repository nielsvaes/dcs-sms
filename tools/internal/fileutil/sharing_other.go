//go:build !windows

package fileutil

// isSharingViolation always returns false off Windows. Other platforms'
// atomic-rename semantics don't produce ERROR_SHARING_VIOLATION-style
// transient read errors against an in-progress writer.
func isSharingViolation(err error) bool {
	return false
}
