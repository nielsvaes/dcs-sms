package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meFileOpenOpts struct {
	Path		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meFileOpenFlags() (*flag.FlagSet, *meFileOpenOpts) {
	opts := &meFileOpenOpts{}
	fs := flag.NewFlagSet("me file open", flag.ContinueOnError)
	fs.StringVar(&opts.Path, "path", "", "absolute path to a .miz file")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("file", "open", cmdInfo{
		Run:		meFileOpenCmd,
		Flags:		flagsOnly(meFileOpenFlags),
		Synopsis:	"open a .miz file in the Mission Editor",
	})
}

// meFileOpenCmd implements `dcs-sms me file open --path <X.miz>`.
//
// Calls dcs_sms_me.verbs.file_open(args) on the ME-mod side, which wraps
// me_toolbar.loadMission. The load is async (ED's progressBar schedules the
// actual file read on a later tick), so the response confirms the call was
// dispatched, not that the load has completed.
func meFileOpenCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meFileOpenFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Path == "" {
		fmt.Fprintln(stderr, "dcs-sms me file open: --path is required")
		return 2
	}

	// Forward-slash the path. Lua tolerates / on Windows and it dodges the
	// well-documented backslash-escape pain documented in the discovery log.
	pathLua := strings.ReplaceAll(opts.Path, "\\", "/")

	// Build the Lua args table inline. luaQuote produces a Lua 5.1
	// string literal — Go's %q is unsafe here because it escapes
	// non-printable codepoints with Go-syntax \uXXXX that Lua doesn't
	// understand (see gh#70).
	luaArgs := fmt.Sprintf("{ path = %s }", luaQuote(pathLua))

	resp, exitCode := runMeVerb("file_open", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
