package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetOnboardNumOpts struct {
	Name		string
	ID		int
	OnboardNum	string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetOnboardNumFlags() (*flag.FlagSet, *meUnitSetOnboardNumOpts) {
	opts := &meUnitSetOnboardNumOpts{}
	fs := flag.NewFlagSet("me unit set-onboard-num", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.StringVar(&opts.OnboardNum, "onboard-num", "", "onboard number string (e.g. \"010\")")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-onboard-num", cmdInfo{
		Run:		meUnitSetOnboardNumCmd,
		Flags:		flagsOnly(meUnitSetOnboardNumFlags),
		Synopsis:	"set a unit's display onboard number",
	})
}

// meUnitSetOnboardNumCmd implements
// `dcs-sms me unit set-onboard-num --name|--id <X> --onboard-num <NNN>`.
//
// Onboard number is a 3-character string painted on the airframe (e.g.
// "010", "210", "TC1"). Stored as `u.onboard_num`.
func meUnitSetOnboardNumCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetOnboardNumFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-onboard-num: exactly one of --name or --id is required")
		return 2
	}
	if opts.OnboardNum == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-onboard-num: --onboard-num is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, onboard_num = %s }", idClause, luaQuote(opts.OnboardNum))

	resp, exitCode := runMeVerb("unit_set_onboard_num", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
