package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetHiddenOpts struct {
	Name       string
	ID         int
	Hidden     bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meGroupSetHiddenFlags() (*flag.FlagSet, *meGroupSetHiddenOpts) {
	opts := &meGroupSetHiddenOpts{}
	fs := flag.NewFlagSet("me group set-hidden", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.BoolVar(&opts.Hidden, "hidden", false, "hide (true) or show (false); pass explicitly")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-hidden", cmdInfo{
		Run:      meGroupSetHiddenCmd,
		Flags:    flagsOnly(meGroupSetHiddenFlags),
		Synopsis: "toggle whether a group is hidden in the ME view",
	})
}

// meGroupSetHiddenCmd implements `dcs-sms me group set-hidden --name|--id <X> --hidden=true|false`.
//
// Toggles g.hidden. Same explicit-bool convention as `me zone set-hidden`:
// --hidden MUST be passed (--hidden=true or --hidden=false) so we can
// distinguish "user wants false" from "user forgot".
//
// Note: this sets only the master `hidden` field (the ME's "HIDDEN ON MAP"
// checkbox). The ME has two sibling per-group flags exposed by separate
// verbs:
//   * `me group set-hidden-on-planner` — g.hiddenOnPlanner
//   * `me group set-hidden-on-mfd`     — g.hiddenOnMFD
func meGroupSetHiddenCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetHiddenFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-hidden: exactly one of --name or --id is required")
		return 2
	}
	hiddenSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "hidden" {
			hiddenSet = true
		}
	})
	if !hiddenSet {
		fmt.Fprintln(stderr, "dcs-sms me group set-hidden: --hidden=true|false is required (pass explicitly)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %q", opts.Name)
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, hidden = %t }", idClause, opts.Hidden)

	resp, exitCode := runMeVerb("group_set_hidden", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
