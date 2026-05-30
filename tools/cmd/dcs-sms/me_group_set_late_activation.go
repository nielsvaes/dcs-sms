package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetLateActivationOpts struct {
	Name		string
	ID		int
	Enabled		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupSetLateActivationFlags() (*flag.FlagSet, *meGroupSetLateActivationOpts) {
	opts := &meGroupSetLateActivationOpts{}
	fs := flag.NewFlagSet("me group set-late-activation", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.BoolVar(&opts.Enabled, "enabled", false,
		"true: group is dormant at mission start, spawns later via trigger / "+
			"script; false: spawns immediately at start_time. Pass explicitly.")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-late-activation", cmdInfo{
		Run:		meGroupSetLateActivationCmd,
		Flags:		flagsOnly(meGroupSetLateActivationFlags),
		Synopsis:	"toggle a group's lateActivation flag (deferred spawn)",
	})
}

func meGroupSetLateActivationCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetLateActivationFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-late-activation: exactly one of --name or --id is required")
		return 2
	}
	enabledSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "enabled" {
			enabledSet = true
		}
	})
	if !enabledSet {
		fmt.Fprintln(stderr, "dcs-sms me group set-late-activation: --enabled=true|false is required (pass explicitly)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, enabled = %t }", idClause, opts.Enabled)

	resp, exitCode := runMeVerb("group_set_late_activation", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
