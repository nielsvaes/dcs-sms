package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meFileSaveAsOpts struct {
	Path		string
	Reopen		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meFileSaveAsFlags() (*flag.FlagSet, *meFileSaveAsOpts) {
	opts := &meFileSaveAsOpts{}
	fs := flag.NewFlagSet("me file save-as", flag.ContinueOnError)
	fs.StringVar(&opts.Path, "path", "", "absolute path to write (.miz)")
	fs.BoolVar(&opts.Reopen, "reopen", true, "re-open the file after save (matches DCS-native; refreshes title bar)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("file", "save-as", cmdInfo{
		Run:		meFileSaveAsCmd,
		Flags:		flagsOnly(meFileSaveAsFlags),
		Synopsis:	"save the open mission to a new .miz path",
	})
}

// meFileSaveAsCmd implements `dcs-sms me file save-as --path <X.miz>`.
//
// Saves the current mission to a new path and updates the ME's tracked
// mission path so subsequent bare `me file save` calls target the new file.
//
// --reopen (default true) controls whether DCS re-loads the file post-save
// (DCS-native behavior — refreshes the title bar and editor state). Pass
// --reopen=false to skip the reload (see `me file save --help` for when).
func meFileSaveAsCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meFileSaveAsFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Path == "" {
		fmt.Fprintln(stderr, "dcs-sms me file save-as: --path is required")
		return 2
	}

	pathLua := strings.ReplaceAll(opts.Path, "\\", "/")
	luaArgs := fmt.Sprintf("{ path = %s, reopen = %t }", luaQuote(pathLua), opts.Reopen)

	resp, exitCode := runMeVerb("file_save_as", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
