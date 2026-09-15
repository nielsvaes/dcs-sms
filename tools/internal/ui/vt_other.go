//go:build !windows

package ui

import "os"

// enableVirtualTerminal is a no-op off Windows: any terminal that reports
// itself as one already understands ANSI escape codes.
func enableVirtualTerminal(_ *os.File) bool { return true }
