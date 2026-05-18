package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetHiddenOnMFDOpts struct {
	Name       string
	ID         int
	Hidden     bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meGroupSetHiddenOnMFDFlags() (*flag.FlagSet, *meGroupSetHiddenOnMFDOpts) {
	opts := &meGroupSetHiddenOnMFDOpts{}
	fs := flag.NewFlagSet("me group set-hidden-on-mfd", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.BoolVar(&opts.Hidden, "hidden", false, "hide on MFDs (true) or show (false); pass explicitly")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-hidden-on-mfd", cmdInfo{
		Run:      meGroupSetHiddenOnMFDCmd,
		Flags:    flagsOnly(meGroupSetHiddenOnMFDFlags),
		Synopsis: "toggle a group's HIDDEN ON MFD flag",
	})
}

// meGroupSetHiddenOnMFDCmd implements `dcs-sms me group set-hidden-on-mfd --name|--id <X> --hidden=true|false`.
//
// Toggles g.hiddenOnMFD. The ME GUI's checkbox stores a plain boolean
// here (overwriting the {} default new-group templates use); we honour
// that and store a boolean too.
func meGroupSetHiddenOnMFDCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetHiddenOnMFDFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-hidden-on-mfd: exactly one of --name or --id is required")
		return 2
	}
	hiddenSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "hidden" {
			hiddenSet = true
		}
	})
	if !hiddenSet {
		fmt.Fprintln(stderr, "dcs-sms me group set-hidden-on-mfd: --hidden=true|false is required (pass explicitly)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %q", opts.Name)
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, hidden = %t }", idClause, opts.Hidden)

	resp, exitCode := runMeVerb("group_set_hidden_on_mfd", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
