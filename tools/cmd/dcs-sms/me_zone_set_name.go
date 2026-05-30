package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneSetNameOpts struct {
	Name		string
	ID		int
	NewName		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneSetNameFlags() (*flag.FlagSet, *meZoneSetNameOpts) {
	opts := &meZoneSetNameOpts{}
	fs := flag.NewFlagSet("me zone set-name", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "zone id (mutually exclusive with --name)")
	fs.StringVar(&opts.NewName, "new-name", "", "new zone name")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "set-name", cmdInfo{
		Run:		meZoneSetNameCmd,
		Flags:		flagsOnly(meZoneSetNameFlags),
		Synopsis:	"rename a zone",
	})
}

// meZoneSetNameCmd implements `dcs-sms me zone set-name --name|--id <X> --new-name <Y>`.
//
// `--name` selects the zone (paired with `--id` as mutually exclusive),
// `--new-name` supplies the value to write — same naming convention used for
// `me group set-name` etc. Wraps Mission.TriggerZoneData.setTriggerZoneName.
//
// The ME enforces uniqueness internally (makeTriggerZoneNameUnique) — if the
// requested name is already taken, the actual stored name will have a suffix
// (e.g. "X #001"). The verb returns the final stored name so callers can see
// what was applied.
func meZoneSetNameCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneSetNameFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone set-name: exactly one of --name or --id is required")
		return 2
	}
	if opts.NewName == "" {
		fmt.Fprintln(stderr, "dcs-sms me zone set-name: --new-name is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, new_name = %s }", idClause, luaQuote(opts.NewName))

	resp, exitCode := runMeVerb("zone_set_name", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
