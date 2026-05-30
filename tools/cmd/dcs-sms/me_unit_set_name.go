package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetNameOpts struct {
	Name		string
	ID		int
	NewName		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetNameFlags() (*flag.FlagSet, *meUnitSetNameOpts) {
	opts := &meUnitSetNameOpts{}
	fs := flag.NewFlagSet("me unit set-name", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.StringVar(&opts.NewName, "new-name", "", "new unit name")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-name", cmdInfo{
		Run:		meUnitSetNameCmd,
		Flags:		flagsOnly(meUnitSetNameFlags),
		Synopsis:	"rename a unit",
	})
}

// meUnitSetNameCmd implements `dcs-sms me unit set-name --name|--id <X> --new-name <Y>`.
//
// Uses Mission.renameUnit which refuses on collision (returns false). The
// verb propagates that as an error. Not silently uniquified — same policy
// as `me group set-name`.
func meUnitSetNameCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetNameFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-name: exactly one of --name or --id is required")
		return 2
	}
	if opts.NewName == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-name: --new-name is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, new_name = %s }", idClause, luaQuote(opts.NewName))

	resp, exitCode := runMeVerb("unit_set_name", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
