//go:build windows

package ui

import (
	"os"
	"sync"

	"golang.org/x/sys/windows"
)

var vtOnce sync.Once
var vtOK bool

// enableVirtualTerminal turns on ENABLE_VIRTUAL_TERMINAL_PROCESSING for the
// console. Windows Terminal has it on by default, but the plain conhost
// window you get from double-clicking dcs-sms.exe does not — without this,
// users would see literal "<-[32m" noise instead of green text.
//
// Done once per process: the mode is a property of the console, not of the
// handle we happen to be probing.
func enableVirtualTerminal(f *os.File) bool {
	vtOnce.Do(func() {
		h := windows.Handle(f.Fd())
		var mode uint32
		if err := windows.GetConsoleMode(h, &mode); err != nil {
			return
		}
		if mode&windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0 {
			vtOK = true
			return
		}
		if err := windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING); err != nil {
			return
		}
		vtOK = true
	})
	return vtOK
}
