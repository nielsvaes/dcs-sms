//go:build windows

package main

import "strings"

// pathsEqual compares two cleaned absolute paths. Windows filesystems are
// case-insensitive, so "C:\Users\X\Saved Games\DCS" and the lowercase form a
// user pasted name the same folder.
func pathsEqual(a, b string) bool { return strings.EqualFold(a, b) }
