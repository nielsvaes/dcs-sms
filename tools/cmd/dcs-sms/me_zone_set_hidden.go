package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneSetHiddenOpts struct {
	Name		string
	ID		int
	Hidden		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneSetHiddenFlags() (*flag.FlagSet, *meZoneSetHiddenOpts) {
	opts := &meZoneSetHiddenOpts{}
	fs := flag.NewFlagSet("me zone set-hidden", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "zone id (mutually exclusive with --name)")
	fs.BoolVar(&opts.Hidden, "hidden", false, "hide (true) or show (false); pass explicitly")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "set-hidden", cmdInfo{
		Run:		meZoneSetHiddenCmd,
		Flags:		flagsOnly(meZoneSetHiddenFlags),
		Synopsis:	"toggle whether a zone is hidden in the ME view",
	})
}

// meZoneSetHiddenCmd implements `dcs-sms me zone set-hidden --name|--id <X> --hidden=true|false`.
//
// `--hidden` MUST be passed explicitly (`--hidden=true` or `--hidden=false`)
// — otherwise the verb has no way to distinguish "user wants false" from
// "user forgot the flag". Wraps Mission.TriggerZoneData.setTriggerZoneHidden.
func meZoneSetHiddenCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneSetHiddenFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone set-hidden: exactly one of --name or --id is required")
		return 2
	}
	hiddenSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "hidden" {
			hiddenSet = true
		}
	})
	if !hiddenSet {
		fmt.Fprintln(stderr, "dcs-sms me zone set-hidden: --hidden=true|false is required (pass explicitly)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, hidden = %t }", idClause, opts.Hidden)

	resp, exitCode := runMeVerb("zone_set_hidden", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
