//go:build !windows

package main

// pathsEqual compares two cleaned absolute paths case-sensitively, matching
// the behaviour of the filesystems dcs-sms is built and tested on off
// Windows.
func pathsEqual(a, b string) bool { return a == b }
